// src/models/PaymentRecord.ts
//
// The money ledger — many rows per catalog, APPENDED and never edited
// (RECAPTURE_SUBSCRIPTION_PLAN.md §7, §10). The post-insert writes are exactly
// these, and the services enforce that list (no generic update helper):
//   • a MANUAL entry's verification fields, which transition exactly once
//     (PENDING_VERIFICATION → VERIFIED | REJECTED);
//   • a PAID row's `appliedAt`, set once when its period has been applied;
//   • a CHECKOUT_CREATED row's `expiresAt`, pulled forward to close the order;
//   • a REFUNDED row's `note`, when Razorpay reports the refund's outcome.
//
// Immutability is a SERVICE rule (Stage 3), not a schema hook: a `pre('save')`
// that refuses updates would also refuse the verification transition, and a
// hook is invisible to `updateOne` anyway. What the schema does enforce is the
// arithmetic — integer paise, never negative — and the two uniqueness rules an
// idempotent checkout depends on.
import { Schema, model, Document, Types } from 'mongoose';
import { ActorSchema, PlanSnapshotSchema } from './CatalogSubscription';
import {
  BILLING_INTERVALS,
  MANUAL_METHODS,
  PAYMENT_KINDS,
  PLAN_IDS,
  VERIFICATION_STATUSES,
  type Actor,
  type BillingInterval,
  type ManualMethod,
  type PaymentKind,
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
  createdAt: Date;
  updatedAt: Date;
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

export const PaymentRecord = model<IPaymentRecord>('PaymentRecord', PaymentRecordSchema);
