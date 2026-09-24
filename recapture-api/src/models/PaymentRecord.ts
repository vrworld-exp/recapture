// src/models/PaymentRecord.ts
//
// The money ledger — many rows per catalog, APPENDED and never edited
// (RECAPTURE_SUBSCRIPTION_PLAN.md §7, §10). The post-insert writes are exactly
// these, and the services enforce that list (no generic update helper):
//   • a MANUAL entry's verification fields, which transition exactly once
//     (PENDING_VERIFICATION → VERIFIED | REJECTED);
//   • a PAID row's `appliedAt`, set once when its period has been applied;
//   • a CHECKOUT_CREATED row's `expiresAt`, pulled forward to close the order;
//   • a REFUNDED row's `note`, when Razorpay reports the refund's outcome;
//   • a PAID row's `adminResolution`, set when an admin applies a flagged or
//     unreflected payment to its catalog by hand
//     (paymentJournalService.forceApplyPayment) — once, guarded on its
//     absence; replaced only when that apply never reached the subscription
//     row (guarded on the previous value's `at`). The original `note` stays —
//     the ledger keeps what the machine decided beside what the human did.
//
// Immutability is a SERVICE rule (Stage 3), not a schema hook: a `pre('save')`
// that refuses updates would also refuse the verification transition, and a
// hook is invisible to `updateOne` anyway. What the schema does enforce is the
// arithmetic — integer paise, never negative — and the two uniqueness rules an
// idempotent checkout depends on.
import { Schema, model, Document, Types, type FilterQuery } from 'mongoose';
import { ActorSchema, PlanSnapshotSchema } from './CatalogSubscription';
import {
  BILLING_INTERVALS,
  MANUAL_METHODS,
  PAYMENT_KINDS,
  PAYMENT_VIAS,
  PLAN_IDS,
  REFUSAL_NOTES,
  VERIFICATION_STATUSES,
  type Actor,
  type BillingInterval,
  type ManualMethod,
  type PaymentKind,
  type PaymentVia,
  type PlanDefinition,
  type PlanId,
  type VerificationStatus,
} from './types/subscription.types';

/** What was quoted at checkout, frozen — the plan, its definition, the total. */
export interface PaymentQuote {
  planId: PlanId;
  planSnapshot: PlanDefinition;
  interval: BillingInterval;
  /** Integer paise. The yearly total is `yearlyPricePaise(planSnapshot)`. */
  totalPaise: number;
}

export interface IPaymentRecord extends Document {
  catalogId: Types.ObjectId;
  /** The catalog's owner at the time — survives the catalog's hard delete, as on CatalogSubscription. */
  userId: Types.ObjectId;
  /**
   * The subscription row at the time of writing, when there was one. An owner
   * may open a checkout (or a rep may submit a cash request) before the
   * catalog has any subscription row at all — the first payment is what
   * creates it — so this is optional rather than a fabricated id.
   */
  subscriptionId?: Types.ObjectId;
  kind: PaymentKind;
  /** Integer paise, never negative — a refund is its own row, not a minus. */
  amountPaise: number;
  currency: string;
  quote?: PaymentQuote;
  /** Razorpay ids — ONLINE only. */
  providerOrderId?: string;
  providerPaymentId?: string;
  providerRefundId?: string;
  /**
   * Stops double-processing: a replayed webhook or a double-tapped checkout
   * finds its row instead of creating a second. Unique WHEN PRESENT — rows
   * that have no key (a comp, a cash entry) never collide.
   */
  idempotencyKey?: string;
  /** Who asked for the order or submitted the manual entry. */
  initiatedBy: Actor;
  /** MANUAL only: who physically took the cash/cheque, if not `initiatedBy`. */
  collectedBy?: Actor;
  /** MANUAL only. */
  method?: ManualMethod;
  /** MANUAL only — the one field on this ledger that transitions. */
  verificationStatus?: VerificationStatus;
  verifiedBy?: Actor;
  verifiedAt?: Date;
  /** REFUNDED only: the PAID row this refund reverses (§7 rule 9). */
  refundsPaymentId?: Types.ObjectId;
  /** A UPI txn id, a receipt number. Never a phone or a name. */
  reference?: string;
  note?: string;
  /** CHECKOUT_CREATED only: when the in-app order stops being payable (§7 rule 4). */
  expiresAt?: Date;
  /**
   * PAID only: when the row's outcome was decided and (if it earned one) its
   * period applied. Null between the ledger insert and the apply, which is the
   * window reconciliation re-runs (E2). The conditional write on
   * `appliedAt: null` is what makes a replayed webhook and a racing
   * reconciler converge on ONE activation (B2).
   */
  appliedAt?: Date | null;
  /**
   * PAID only, written at insert: which path recorded the payment (webhook,
   * reconciler, the app's signed response, or an admin's provider check).
   * Absent on rows recorded before the field existed.
   */
  recordedVia?: PaymentVia;
  /**
   * PAID only: an admin applied this payment's plan to the catalog by hand,
   * because the machine flagged it (AMOUNT_MISMATCH / DUPLICATE_SUSPECTED /
   * ORPHAN_PAYMENT on a restored catalog) or its period never reached the
   * subscription row. Written once, guarded on its absence — or re-written,
   * guarded on its previous `at`, when that apply never landed.
   */
  adminResolution?: PaymentAdminResolution;
  createdAt: Date;
  updatedAt: Date;
}

export interface PaymentAdminResolution {
  action: 'APPLIED';
  by: Actor;
  /** The `paidAt` the period was applied with — equal to its `periodStart`. */
  at: Date;
  note: string;
}

const PaymentQuoteSchema = new Schema<PaymentQuote>(
  {
    planId: { type: String, enum: PLAN_IDS, required: true },
    planSnapshot: { type: PlanSnapshotSchema, required: true },
    interval: { type: String, enum: BILLING_INTERVALS, required: true },
    totalPaise: { type: Number, required: true, min: 0, validate: Number.isInteger },
  },
  { _id: false }
);

const PaymentAdminResolutionSchema = new Schema<PaymentAdminResolution>(
  {
    action: { type: String, enum: ['APPLIED'], required: true },
    by: { type: ActorSchema, required: true },
    at: { type: Date, required: true },
    note: { type: String, trim: true, required: true, maxlength: 1000 },
  },
  { _id: false }
);

const PaymentRecordSchema = new Schema<IPaymentRecord>(
  {
    catalogId: { type: Schema.Types.ObjectId, ref: 'Catalog', required: true },
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    subscriptionId: { type: Schema.Types.ObjectId, ref: 'CatalogSubscription' },
    kind: { type: String, enum: PAYMENT_KINDS, required: true },
    amountPaise: { type: Number, required: true, min: 0, validate: Number.isInteger },
    currency: { type: String, required: true, default: 'INR', trim: true, maxlength: 8 },
    quote: { type: PaymentQuoteSchema },
    providerOrderId: { type: String, trim: true, maxlength: 128 },
    providerPaymentId: { type: String, trim: true, maxlength: 128 },
    providerRefundId: { type: String, trim: true, maxlength: 128 },
    idempotencyKey: { type: String, trim: true, maxlength: 128 },
    initiatedBy: { type: ActorSchema, required: true },
    collectedBy: { type: ActorSchema },
    method: { type: String, enum: MANUAL_METHODS },
    verificationStatus: { type: String, enum: VERIFICATION_STATUSES },
    verifiedBy: { type: ActorSchema },
    verifiedAt: { type: Date },
    refundsPaymentId: { type: Schema.Types.ObjectId, ref: 'PaymentRecord' },
    reference: { type: String, trim: true, maxlength: 200 },
    note: { type: String, trim: true, maxlength: 1000 },
    expiresAt: { type: Date },
    appliedAt: { type: Date, default: null },
    recordedVia: { type: String, enum: PAYMENT_VIAS },
    adminResolution: { type: PaymentAdminResolutionSchema, default: undefined },
  },
  { timestamps: true }
);

// ── Indexes ────────────────────────────────────────────────────────────────
// Primary read: "this catalog's ledger, newest first".
PaymentRecordSchema.index({ catalogId: 1, createdAt: -1 });

// Idempotent processing. Partial on `$type: 'string'` (not `$exists`) so a
// row written with `idempotencyKey: null` holds no slot either — the same
// shape as Catalog's `mirageRestaurantId` index, and the one that makes "many
// rows with no key" and "no two rows with the same key" both true.
PaymentRecordSchema.index(
  { idempotencyKey: 1 },
  { unique: true, partialFilterExpression: { idempotencyKey: { $type: 'string' } } }
);

// One ledger row per Razorpay order PER KIND: one CHECKOUT_CREATED (a replayed
// order-create cannot record the same order twice) and one PAID (the payment
// that settled it carries the same order id, so the two rows of one checkout
// can be joined). Kind-scoped rather than global for exactly that reason —
// the PAID row for an order must be allowed to exist beside its checkout row.
PaymentRecordSchema.index(
  { kind: 1, providerOrderId: 1 },
  { unique: true, partialFilterExpression: { providerOrderId: { $type: 'string' } } }
);

// The admin's verification queue ("MANUAL rows still PENDING"), across every
// catalog and within one.
PaymentRecordSchema.index({ kind: 1, verificationStatus: 1 });
PaymentRecordSchema.index({ catalogId: 1, kind: 1, verificationStatus: 1 });

// "Has this owner ever paid" — the trial-eligibility read (E41).
PaymentRecordSchema.index({ userId: 1, kind: 1, verificationStatus: 1 });

// Reconciliation's two scans: open orders by expiry ("CHECKOUT_CREATED still
// payable / expired in the last 48 h") and PAID rows whose period was never
// applied. Both are status-plus-one-date shapes, like the sweep indexes on
// CatalogSubscription.
PaymentRecordSchema.index({ kind: 1, expiresAt: 1 });
PaymentRecordSchema.index({ kind: 1, appliedAt: 1, createdAt: 1 });

// The owner's open order, the checkout's create-or-return read.
PaymentRecordSchema.index({ catalogId: 1, kind: 1, expiresAt: 1 });

// The admin payment journal: one kind (orders or payments), newest first,
// keyset-paginated on `(createdAt, _id)`.
PaymentRecordSchema.index({ kind: 1, createdAt: -1, _id: -1 });

export const PaymentRecord = model<IPaymentRecord>('PaymentRecord', PaymentRecordSchema);

/**
 * The ledger filter for "this owner has paid FOR something" — trial and
 * pending-window eligibility: a verified cash payment, or an online payment
 * that was not refused (or that an admin applied by hand). A refused,
 * unresolved PAID row is money to refund or decide, not a purchase.
 * `note: {$nin}` also matches rows with no note at all.
 */
export function purchasedPaymentFilter(ownerUserId: Types.ObjectId): FilterQuery<IPaymentRecord> {
  return {
    userId: ownerUserId,
    $or: [
      { kind: 'MANUAL', verificationStatus: 'VERIFIED' },
      {
        kind: 'PAID',
        $or: [{ note: { $nin: [...REFUSAL_NOTES] } }, { adminResolution: { $ne: null } }],
      },
    ],
  };
}
