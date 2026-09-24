// src/models/types/subscription.types.ts
//
// Shared vocabularies and nested-field types for the catalog subscription
// layer (models/CatalogSubscription.ts, PaymentRecord.ts, and the plan catalog
// in config/subscriptionPlans.ts) — RECAPTURE_SUBSCRIPTION_PLAN.md §3, §10.
//
// Same placement rule as catalog.types.ts: routes, services, the publish gate
// and the worker all need these, and services must not import from the worker.
import type { Types } from 'mongoose';
import type { UserRole } from '../User';

// ── Subscription ────────────────────────────────────────────────────────────

/**
 * Where a catalog's subscription is in its life (§6).
 *   TRIAL           — the one-per-catalog free period a rep or admin activated.
 *   PENDING_PAYMENT — a rep or staff member published this restaurant before
 *                     anybody paid for it. Full access, a cap, and a DEADLINE:
 *                     at `periodEnd` the customer page itself is switched off,
 *                     not just 3D. See the note below.
 *   ACTIVE          — a paid period is running.
 *   GRACE           — the paid period ended; full access continues for
 *                     `graceDays` while a payment is chased. Grace keeps
 *                     ACCESS, never adds CAPACITY — the 3D cap still applies.
 *   PAUSED          — grace ran out. The photo menu stays live; 3D is switched
 *                     off. (The one exception is a PENDING_PAYMENT window that
 *                     expired — see `pageDeactivatedAt`.)
 *   CANCELLED       — the owner asked to stop. Same entitlement as PAUSED.
 *   COMPED          — granted by an admin (or the launch grandfather window),
 *                     no money involved. Uncapped.
 *
 * WHY PENDING_PAYMENT IS NOT A TRIAL. A rep leaves a working standee on the
 * table, so the publish has to go through before any money does; but the one
 * free trial a restaurant gets is a thing a rep GRANTS on purpose, and
 * consuming it as a side effect of pressing Publish would silently spend it.
 * So this is its own short window with its own consequence, and the trial is
 * still there to be started — a trial started later SUPERSEDES the window and
 * clears the debt (see startTrial).
 *
 * WHY ITS EXPIRY IS HARSHER THAN A LAPSE. AC-4 promises a restaurant that has
 * PAID that its photo menu never goes dark. A restaurant that has never paid a
 * rupee was never given that promise, and "pay or the link dies" is the only
 * lever a rep has once they have left the table. The two rules live side by
 * side: `pageDeactivatedAt` is set for this case and for no other.
 */
export const SUBSCRIPTION_STATUSES = [
  'TRIAL',
  'PENDING_PAYMENT',
  'ACTIVE',
  'GRACE',
  'PAUSED',
  'CANCELLED',
  'COMPED',
] as const;
export type SubscriptionStatus = (typeof SUBSCRIPTION_STATUSES)[number];

/** The only three plans there are (§3). No formula tier, no add-on tier. */
export const PLAN_IDS = ['TASTE', 'SIGNATURE', 'MASTERCHEF'] as const;
export type PlanId = (typeof PLAN_IDS)[number];

export const BILLING_INTERVALS = ['MONTHLY', 'YEARLY'] as const;
export type BillingInterval = (typeof BILLING_INTERVALS)[number];

/**
 * How the CURRENT period came to be.
 *
 * `TRIAL` is not in the plan document's three-value list; it is here because a
 * trial period needs a source too, and overloading `COMP` would make "how many
 * catalogs did we comp" count every trial (see the stage-1 assumptions).
 */
export const SUBSCRIPTION_SOURCES = [
  'ONLINE',
  'MANUAL',
  'COMP',
  'TRIAL',
  /** A rep/staff publish opened the window; nobody has paid (PENDING_PAYMENT). */
  'REP_PUBLISH',
] as const;
export type SubscriptionSource = (typeof SUBSCRIPTION_SOURCES)[number];

/**
 * Stored in `CatalogSubscription.threeDDishCap` for "no cap" (a comp). Read
 * the field through {@link isUncapped}, never by comparing to this directly.
 */
export const UNCAPPED_THREE_D = -1;

/** True when a `threeDDishCap` means "no cap" rather than a number of dishes. */
export function isUncapped(threeDDishCap: number): boolean {
  return threeDDishCap < 0;
}

// ── Payments ────────────────────────────────────────────────────────────────

export const PAYMENT_KINDS = [
  'CHECKOUT_CREATED',
  'PAID',
  'MANUAL',
  'COMP',
  'REFUNDED',
  'DISPUTED',
] as const;
export type PaymentKind = (typeof PAYMENT_KINDS)[number];

/**
 * Which path recorded or applied an online payment: Razorpay's webhook, the
 * reconciler's provider check, the app's signed checkout response, or an
 * admin pressing "Check with Razorpay" / "Apply to catalog". Stored on the PAID
 * row as `recordedVia` so the admin journal can say HOW the money got in.
 */
export const PAYMENT_VIAS = ['WEBHOOK', 'RECONCILE', 'CLIENT', 'ADMIN'] as const;
export type PaymentVia = (typeof PAYMENT_VIAS)[number];

/**
 * The notes `applyRecordedPayment` writes on a PAID row it refused to
 * activate — "recorded, not activated". A PAID row carrying one of these (and
 * no `adminResolution`) bought NOTHING, so it must not count as "has paid"
 * for trial or pending-window eligibility.
 */
export const REFUSAL_NOTES = ['AMOUNT_MISMATCH', 'ORPHAN_PAYMENT', 'DUPLICATE_SUSPECTED'] as const;
export type RefusalNote = (typeof REFUSAL_NOTES)[number];

/** MANUAL entries only — the one field on the ledger that transitions (§10). */
export const VERIFICATION_STATUSES = ['PENDING_VERIFICATION', 'VERIFIED', 'REJECTED'] as const;
export type VerificationStatus = (typeof VERIFICATION_STATUSES)[number];

export const MANUAL_METHODS = ['CASH', 'BANK_TRANSFER', 'CHEQUE', 'UPI'] as const;
export type ManualMethod = (typeof MANUAL_METHODS)[number];

// ── Plans ───────────────────────────────────────────────────────────────────

/** The feature flags a plan tier switches on (§3, "Other features"). */
export const PLAN_FEATURES = [
  'whatsapp_instagram_buttons',
  'website_embed',
  'per_dish_analytics',
  'priority_support',
] as const;
export type PlanFeature = (typeof PLAN_FEATURES)[number];

/**
 * One plan tier, as sold. Every subscription stores a FROZEN copy of the one
 * it was bought under (`CatalogSubscription.planSnapshot`), so a later price
 * or cap change reaches nobody before their next renewal (§3c).
 */
export interface PlanDefinition {
  planId: PlanId;
  displayName: string;
  /** Integer paise — ₹1,199 is 119900. Never a float, never rupees. */
  priceMonthlyPaise: number;
  /** Percent off the twelve-month total when billed yearly; 30 in the plan. */
  yearlyDiscountPct: number;
  /** How many READY-model dishes a publish may carry (§3b). */
  threeDDishCap: number;
  /** Complimentary standees bundled into the price (§3a). */
  includedStandeeCount: number;
  features: readonly PlanFeature[];
}

/** The three plans plus the shared constants, as served by the plan catalog. */
export interface PlanCatalog {
  plans: Record<PlanId, PlanDefinition>;
  trialDays: number;
  trialThreeDCap: number;
  graceDays: number;
  grandfatherDays: number;
  /** How long an in-app checkout order stays payable (§7 rule 4). */
  orderTtlHours: number;
  /**
   * How long a never-paid rep/staff publish stays live before the customer page
   * is switched off, and how many 3D dishes it may carry meanwhile. Resolved
   * from `SUBSCRIPTION_PENDING_PAYMENT_DAYS` and `trialThreeDCap` by
   * planCatalogService — NOT settable by an ops override, which is why neither
   * appears in `planCatalogSchema`.
   */
  pendingPaymentDays: number;
  pendingPaymentThreeDCap: number;
  /**
   * TRUE when every price above is a testing price rather than the real tier
   * (`SUBSCRIPTION_TESTING_PRICES`). On the wire so a screen can put a visible
   * badge over its own plan cards: a ₹3 plan with nothing saying why is how a
   * tester talks a real restaurant into a price we cannot honour.
   *
   * Server-resolved and read-only. An ops override cannot set it (it is not in
   * `planCatalogSchema`) and a client must never infer it from a low price.
   */
  testingPrices: boolean;
}

/**
 * The yearly price for a plan, in integer paise — AC-8.1.
 *
 * The formula is the source of truth; what a screen ROUNDS it to for display
 * is the client's business and must not happen here.
 */
export function yearlyPricePaise(plan: PlanDefinition): number {
  return Math.round((plan.priceMonthlyPaise * 12 * (100 - plan.yearlyDiscountPct)) / 100);
}

// ── Actors ──────────────────────────────────────────────────────────────────

/**
 * Who did something — the rep who started a trial, the admin who verified a
 * cash payment. The role is captured AT THE TIME so an audit row still says
 * "a SALES_REP did this" after the person's role changes.
 */
export interface Actor {
  userId: Types.ObjectId;
  role: UserRole;
}
