// src/models/AutopayMandate.ts
//
// One row per Razorpay SUBSCRIPTION we create — the owner's autopay. The
// money itself never lives here: every charge Razorpay takes is a PAID
// `PaymentRecord` (keyed `payment:<id>`, like any other online payment) and
// is applied through the same activation primitive. This row is the MANDATE:
// which plan, at what frozen price, in what state Razorpay says it is, and
// when it next charges.
//
// Mirrors Razorpay; decides nothing. `status`, `currentStart`, `currentEnd`,
// `chargeAt` and `paidCount` are overwritten from Razorpay's own answer on
// every sync (autopayService.syncMandate) — never computed here.
//
// The one invariant: at most ONE live mandate (AUTHENTICATED / ACTIVE /
// PENDING) per catalog. Enforced by the service (a new mandate that goes
// live cancels the rest at Razorpay), not by an index — two can be briefly
// live between the second one's authorisation and the first one's cancel.
import { Schema, model, Document, Types } from 'mongoose';
import { ActorSchema } from './CatalogSubscription';
import { PaymentQuoteSchema, type PaymentQuote } from './PaymentRecord';
import { AUTOPAY_STATUSES, type Actor, type AutopayStatus } from './types/subscription.types';

export interface IAutopayMandate extends Document {
  catalogId: Types.ObjectId;
  /** The catalog's owner when the mandate was created — survives a hard delete. */
  userId: Types.ObjectId;
  /** `sub_…`. Unique. */
  providerSubscriptionId: string;
  /** `plan_…` — the Razorpay plan (one per plan/interval/price, see RazorpayPlan). */
  providerPlanId: string;
  /** What every charge on this mandate buys, frozen at creation. */
  quote: PaymentQuote;
  status: AutopayStatus;
  /**
   * When the first charge is due, when it is NOT at authorisation — the owner
   * turned autopay on over a period they had already paid for, so the first
   * charge waits for that period to end instead of forfeiting it. Null = the
   * first charge is taken at checkout.
   */
  startAt: Date | null;
  /** Razorpay's current billing cycle. Null until the first charge. */
  currentStart: Date | null;
  currentEnd: Date | null;
  /** Razorpay's next charge time. */
  chargeAt: Date | null;
  paidCount: number;
  /**
   * Why it stopped, when WE stopped it. Turning autopay off cancels the
   * mandate at Razorpay IMMEDIATELY — the catalog's paid period is ours, not
   * Razorpay's, so it runs to its end regardless — which is why there is no
   * "cancel at cycle end" state to track here.
   */
  endReason?: 'OWNER_CANCELLED' | 'SUPERSEDED' | 'CATALOG_DELETED';
  endedAt?: Date;
  /** A CREATED mandate stops being payable here (Razorpay's `expire_by`). */
  expiresAt: Date;
  initiatedBy: Actor;
  lastSyncedAt?: Date;
  createdAt: Date;
  updatedAt: Date;
}

const AutopayMandateSchema = new Schema<IAutopayMandate>(
  {
    catalogId: { type: Schema.Types.ObjectId, ref: 'Catalog', required: true },
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    providerSubscriptionId: { type: String, required: true, trim: true, maxlength: 128 },
    providerPlanId: { type: String, required: true, trim: true, maxlength: 128 },
    quote: { type: PaymentQuoteSchema, required: true },
    status: { type: String, enum: AUTOPAY_STATUSES, required: true, default: 'CREATED' },
    startAt: { type: Date, default: null },
    currentStart: { type: Date, default: null },
    currentEnd: { type: Date, default: null },
    chargeAt: { type: Date, default: null },
    paidCount: { type: Number, required: true, default: 0, min: 0, validate: Number.isInteger },
    endReason: { type: String, enum: ['OWNER_CANCELLED', 'SUPERSEDED', 'CATALOG_DELETED'] },
    endedAt: { type: Date },
    expiresAt: { type: Date, required: true },
    initiatedBy: { type: ActorSchema, required: true },
    lastSyncedAt: { type: Date },
  },
  { timestamps: true }
);

AutopayMandateSchema.index({ providerSubscriptionId: 1 }, { unique: true });
// "This catalog's mandates, newest first" — the screen, the create path, the sweep's hold.
AutopayMandateSchema.index({ catalogId: 1, status: 1, createdAt: -1 });
// The reconciler: live mandates whose charge is due.
AutopayMandateSchema.index({ status: 1, chargeAt: 1 });

export const AutopayMandate = model<IAutopayMandate>('AutopayMandate', AutopayMandateSchema);
