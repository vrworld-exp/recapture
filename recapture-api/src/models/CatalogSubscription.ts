// src/models/CatalogSubscription.ts
//
// ONE subscription per catalog — what the restaurant is entitled to publish
// (RECAPTURE_SUBSCRIPTION_PLAN.md §6, §10).
//
// Its own document rather than fields on Catalog, one-to-one: the catalog is
// the authoring root and is read on every catalog request; the subscription is
// read by the publish gate and the Stage 5 sweeps, and carries a frozen plan
// snapshot that would bloat every catalog read for nothing.
//
// Nothing here is written by the publish worker. The status transitions are a
// service concern (Stages 2–5); this file is the shape and the indexes.
import { Schema, model, Document, Types } from 'mongoose';
import { USER_ROLES } from './User';
import {
  BILLING_INTERVALS,
  PLAN_FEATURES,
  PLAN_IDS,
  SUBSCRIPTION_SOURCES,
  SUBSCRIPTION_STATUSES,
  UNCAPPED_THREE_D,
  isUncapped,
  type Actor,
  type BillingInterval,
  type PlanDefinition,
  type PlanId,
  type SubscriptionSource,
  type SubscriptionStatus,
} from './types/subscription.types';

export interface ICatalogSubscription extends Document {
  /** The catalog. UNIQUE — one subscription per catalog is the product rule. */
  catalogId: Types.ObjectId;
  /**
   * The catalog's OWNER at the time the row was written. `DELETE /catalog` is
   * a HARD delete (see catalogService.deleteCatalog), so this row outlives the
   * catalog it names; what it must not outlive is the "one trial ever" rule
   * (D2). A re-created catalog gets a new id and no row, and this is the
   * field that lets startTrial see the trial the owner already had.
   */
  userId: Types.ObjectId;
  status: SubscriptionStatus;
  /** Which plan tier. Absent on TRIAL and COMPED, which are not plans. */
  planId?: PlanId;
  /**
   * The plan AS BOUGHT — a frozen copy of the catalog entry at the moment this
   * period started, so a later price or cap change reaches nobody mid-period
   * (§3c). Required whenever `status` is ACTIVE (or GRACE following ACTIVE);
   * that rule is enforced by the service that writes it, not by the schema, so
   * a trial or a comp can carry none.
   */
  planSnapshot?: PlanDefinition;
  billingInterval?: BillingInterval;
  /** The current period, paid or otherwise. UTC. */
  periodStart: Date;
  periodEnd: Date;
  /**
   * Set ONLY when status becomes GRACE, and always `periodEnd + graceDays`
   * calendar days in UTC — plain millisecond arithmetic, no timezone math.
   */
  graceEndsAt?: Date;
  /**
   * Which status the sweep moved into GRACE from — TRIAL, ACTIVE or COMPED —
   * so the client can say "your trial ended" rather than "payment overdue"
   * to a restaurant that never paid (E16). Written by the sweep only; a
   * dispute-grace leaves it unset (it came from ACTIVE, and the copy is
   * "overdue"). Cleared with `graceEndsAt` whenever a new period is applied.
   */
  graceFrom?: SubscriptionStatus;
  /**
   * Set when a CHARGEBACK moved the row ACTIVE → GRACE (B9), so a dispute
   * that is later WON can be told apart from a grace the sweep started: only
   * a dispute-grace is restored to ACTIVE on `won`. Cleared whenever a new
   * period is applied (paid or comp), like `graceEndsAt`.
   */
  disputeGraceAt?: Date;
  /** Set once, never cleared — the "one trial ever" flag (§8 A/D). */
  trialUsedAt?: Date;
  /** Which rep or admin activated the trial. Trials are never automatic. */
  trialActivatedBy?: Actor;
  /**
   * Set once, never cleared — the "one rep-publish window ever" flag, exactly
   * as `trialUsedAt` is. Without it, `DELETE /catalog` + re-create + publish
   * would mint a fresh free week every time, and the rows that make the trial
   * rule stick (this collection outlives the catalogs it names, see `userId`)
   * are the same rows that make this one stick.
   */
  pendingPaymentUsedAt?: Date;
  /** Which rep or staff member's publish opened the window. */
  pendingPaymentActivatedBy?: Actor;
  /**
   * Set when a PENDING_PAYMENT window expired and the CUSTOMER PAGE was
   * switched off — `isPublished: false` on the Mirage restaurant, not just
   * `arEnabled: false`.
   *
   * THE ONLY PLACE THIS HAPPENS. A restaurant that has paid keeps its photo
   * menu forever (AC-4); this field marks the one case that was never paid for,
   * and it is what tells an activation that it has a page to turn back ON as
   * well as a 3D entitlement. Cleared when the page is restored.
   */
  pageDeactivatedAt?: Date;
  /** How the CURRENT period came to be. */
  source: SubscriptionSource;
  /**
   * The 3D-dish cap IN FORCE: the trial cap, the plan's cap, or
   * {@link UNCAPPED_THREE_D} for a comp. Denormalised from `planSnapshot` /
   * the trial constant so the gate reads one number and never has to know
   * which kind of period it is looking at.
   */
  threeDDishCap: number;
  /** Complimentary standees: what the plan includes and how many went out. */
  standeeAllocation: { included: number; issued: number };
  pausedAt?: Date;
  cancelledAt?: Date;
  /** When Mirage was last told about this row's 3D entitlement (Stage 5). */
  arEntitlementSyncedAt?: Date;
  createdAt: Date;
  updatedAt: Date;
}

/**
 * Whether a status carries the right to publish 3D dishes at all. GRACE is
 * in: grace keeps full access while a payment is chased (§6). PENDING_PAYMENT
 * is in too — the whole point of the window is that the rep leaves a WORKING
 * standee on the table, 3D included. PAUSED and CANCELLED are out: the photo
 * menu stays live, 3D does not.
 */
export function isEntitledTo3D(status: SubscriptionStatus): boolean {
  return (
    status === 'TRIAL' ||
    status === 'PENDING_PAYMENT' ||
    status === 'ACTIVE' ||
    status === 'GRACE' ||
    status === 'COMPED'
  );
}

/**
 * The frozen plan. Shared with PaymentRecord's `quote.planSnapshot` so the two
 * copies of a plan can never drift in shape.
 */
export const PlanSnapshotSchema = new Schema<PlanDefinition>(
  {
    planId: { type: String, enum: PLAN_IDS, required: true },
    displayName: { type: String, required: true, trim: true, maxlength: 60 },
    // Integer paise — a float here is a bug, not a rounding choice.
    priceMonthlyPaise: { type: Number, required: true, min: 0, validate: Number.isInteger },
    yearlyDiscountPct: {
      type: Number,
      required: true,
      min: 0,
      max: 100,
      validate: Number.isInteger,
    },
    threeDDishCap: { type: Number, required: true, min: 0, validate: Number.isInteger },
    includedStandeeCount: { type: Number, required: true, min: 0, validate: Number.isInteger },
    features: { type: [{ type: String, enum: PLAN_FEATURES }], required: true, default: [] },
  },
  { _id: false }
);

/** `{ userId, role }` — shared with PaymentRecord's actor fields. */
export const ActorSchema = new Schema<Actor>(
  {
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    role: { type: String, enum: USER_ROLES, required: true },
  },
  { _id: false }
);

const StandeeAllocationSchema = new Schema<{ included: number; issued: number }>(
  {
    included: { type: Number, required: true, default: 0, min: 0, validate: Number.isInteger },
    issued: { type: Number, required: true, default: 0, min: 0, validate: Number.isInteger },
  },
  { _id: false }
);

const CatalogSubscriptionSchema = new Schema<ICatalogSubscription>(
  {
    catalogId: { type: Schema.Types.ObjectId, ref: 'Catalog', required: true },
    userId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    status: { type: String, enum: SUBSCRIPTION_STATUSES, required: true },
    planId: { type: String, enum: PLAN_IDS },
    planSnapshot: { type: PlanSnapshotSchema },
    billingInterval: { type: String, enum: BILLING_INTERVALS },
    periodStart: { type: Date, required: true },
    periodEnd: { type: Date, required: true },
    graceEndsAt: { type: Date },
    graceFrom: { type: String, enum: SUBSCRIPTION_STATUSES },
    disputeGraceAt: { type: Date },
    trialUsedAt: { type: Date },
    trialActivatedBy: { type: ActorSchema },
    pendingPaymentUsedAt: { type: Date },
    pendingPaymentActivatedBy: { type: ActorSchema },
    pageDeactivatedAt: { type: Date },
    source: { type: String, enum: SUBSCRIPTION_SOURCES, required: true },
    // -1 is the one negative value with a meaning (UNCAPPED_THREE_D); anything
    // else negative is a bug.
    threeDDishCap: {
      type: Number,
      required: true,
      min: UNCAPPED_THREE_D,
      validate: Number.isInteger,
    },
    standeeAllocation: {
      type: StandeeAllocationSchema,
      required: true,
      default: () => ({ included: 0, issued: 0 }),
    },
    pausedAt: { type: Date },
    cancelledAt: { type: Date },
    arEntitlementSyncedAt: { type: Date },
  },
  { timestamps: true }
);

// ── Indexes ────────────────────────────────────────────────────────────────
// One subscription per catalog. This index IS the rule — a concurrent second
// insert gets E11000, and the grandfather script treats that as "already
// done", not as an error.
CatalogSubscriptionSchema.index({ catalogId: 1 }, { unique: true });

// The Stage 5 sweeps: "ACTIVE rows whose period has ended" → GRACE, and
// "GRACE rows whose grace has ended" → PAUSED. Each is a status filter plus a
// range on one date, so each gets its own compound index.
CatalogSubscriptionSchema.index({ status: 1, periodEnd: 1 });
CatalogSubscriptionSchema.index({ status: 1, graceEndsAt: 1 });

// Trial eligibility is judged per OWNER, across every catalog they have had
// (the deleted ones included) — "did this person already use a trial".
CatalogSubscriptionSchema.index({ userId: 1, trialUsedAt: 1 });

// The same question for the rep-publish window: "has this person already had
// their free week". Its own index rather than a suffix on the trial one,
// because the two are asked independently and each is a two-field equality.
CatalogSubscriptionSchema.index({ userId: 1, pendingPaymentUsedAt: 1 });

export const CatalogSubscription = model<ICatalogSubscription>(
  'CatalogSubscription',
  CatalogSubscriptionSchema
);

export { UNCAPPED_THREE_D, isUncapped };
