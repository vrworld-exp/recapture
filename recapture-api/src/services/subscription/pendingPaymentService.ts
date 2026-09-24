// src/services/subscription/pendingPaymentService.ts
//
// Requirement 2, Door 4: a rep or staff member publishes a restaurant nobody
// has paid for yet. The publish GOES THROUGH — the whole promise of the rep
// flow is that they leave a working standee on the table — and in exchange the
// restaurant gets a deadline: `pendingPaymentDays` from now, after which the
// customer page is switched off.
//
// WHY THIS IS NOT A TRIAL. The one free trial a restaurant gets is something a
// rep GRANTS on purpose, from a button, and spending it as a side effect of
// pressing Publish would silently consume it. So this is its own short window
// with its own status (PENDING_PAYMENT) and its own consequence, and the trial
// is still sitting there to be started — a trial started later supersedes the
// window and clears the debt (subscriptionService.startTrial).
//
// WHY THE EXPIRY IS HARSHER THAN A LAPSE. AC-4 promises a restaurant that HAS
// PAID that its photo menu never goes dark. This restaurant has never paid a
// rupee; "pay or the link dies" is the only lever a rep has once they have left
// the table. The two rules coexist because only this file (and the sweep scan
// it owns) ever sets `pageDeactivatedAt`.
//
// NOTHING HERE TOUCHES MIRAGE SYNCHRONOUSLY. Opening a window enqueues a
// SUBSCRIPTION_PAGE_STATE job; a Mirage that is asleep must not be able to fail
// a rep's publish (the same rule requestPublish already follows for
// provisioning).
import { Types } from 'mongoose';

import { CatalogSubscription, isEntitledTo3D } from '@/models/CatalogSubscription';
import { hasRoleAtLeast, type UserRole } from '@/models/User';
import { PaymentRecord, purchasedPaymentFilter } from '@/models/PaymentRecord';
import {
  type Actor,
  type SubscriptionStatus,
} from '@/models/types/subscription.types';
import { notifyPaymentWindowOpened } from '@/services/subscription/ownerNotifications';
import { enqueuePageStateJob } from '@/services/subscription/pageStateJobs';
import { getPlanCatalog } from '@/services/subscription/planCatalogService';
import { track, AnalyticsEvent } from '@/utils/analytics';

const DAY_MS = 86_400_000;

/**
 * Whether an actor's role may open a window on somebody else's behalf — "sales
 * rep or staff" in the requirement's words, which in this codebase is everyone
 * at or above SALES_REP (SALES_REP, MODEL_ARTIST, ADMIN).
 *
 * A plain USER is deliberately out: an owner publishing their own catalog is
 * the case the paywall exists for, and letting them mint their own free week by
 * pressing Publish would make the gate decorative.
 */
export function roleMayOpenPendingPayment(role: UserRole): boolean {
  return hasRoleAtLeast(role, 'SALES_REP');
}

export type StartPendingPaymentOutcome =
  /** A window was opened and the publish may proceed. */
  | 'STARTED'
  /** A live row is already in the way (TRIAL, ACTIVE, GRACE, COMPED, PENDING_PAYMENT). */
  | 'SUBSCRIPTION_ACTIVE'
  /** This owner has already had their one window, on this catalog or an earlier one. */
  | 'ALREADY_USED'
  /** The owner has paid before; a free week is for restaurants that never were customers. */
  | 'NOT_ELIGIBLE';

export interface StartPendingPaymentResult {
  outcome: StartPendingPaymentOutcome;
  /** When the page is due to go dark — set on STARTED only. */
  paymentDueAt?: Date;
}

/**
 * The OWNER's history, across every catalog they have had — including the ones
 * `DELETE /catalog` hard-deleted, because these rows outlive the catalogs they
 * name (see `CatalogSubscription.userId`). Two rules, mirroring the trial's:
 *   • one window ever: delete-and-re-publish must not mint a fresh free week;
 *   • an owner with a PAID or VERIFIED manual payment behind them is not a
 *     "never paid" restaurant and gets no window (the E41 rule, again).
 */
async function ownerWindowHistory(
  ownerUserId: Types.ObjectId
): Promise<{ usedWindow: boolean; hasPaid: boolean }> {
  const [usedWindow, hasPaid] = await Promise.all([
    CatalogSubscription.exists({
      userId: ownerUserId,
      pendingPaymentUsedAt: { $ne: null },
    }).exec(),
    // A refused, unresolved online payment bought nothing — it does not make
    // the owner a customer (same rule as the trial, `purchasedPaymentFilter`).
    PaymentRecord.exists(purchasedPaymentFilter(ownerUserId)).exec(),
  ]);
  return { usedWindow: usedWindow !== null, hasPaid: hasPaid !== null };
}

function isDuplicateKey(err: unknown): boolean {
  return (
    typeof err === 'object' &&
    err !== null &&
    'code' in err &&
    (err as { code?: unknown }).code === 11000
  );
}

/**
 * Opens the window, or explains why it did not.
 *
 * ATOMIC THE HOUSE WAY (no transactions), exactly as `startTrial` is, so two
 * reps pressing Publish at once end with ONE window:
 *   • no row → `create`; a loser's E11000 means the other press won, and the
 *     row-exists path below then reads that fresh window as "already live".
 *   • a row → a conditional `findOneAndUpdate` guarded on
 *     `pendingPaymentUsedAt: null` AND a lapsed status. Null means the guard
 *     failed, and a re-read says why.
 *
 * The history checks run first and are advisory against a race; the row-level
 * guard is the authority.
 *
 * ONLY CANCELLED / PAUSED ROWS MAY BE REOPENED, and only if they never had a
 * window. A PAUSED row is a restaurant that lapsed — but a restaurant that
 * lapsed has almost always paid, and `hasPaid` refuses it before this matters.
 * What it does cover is a row paused from an expired TRIAL: a rep republishing
 * that restaurant gets the week, once.
 */
export async function startPendingPayment(
  catalogId: Types.ObjectId,
  ownerUserId: Types.ObjectId,
  actor: Actor,
  now: Date = new Date()
): Promise<StartPendingPaymentResult> {
  const history = await ownerWindowHistory(ownerUserId);
  if (history.hasPaid) return { outcome: 'NOT_ELIGIBLE' };
  if (history.usedWindow) {
    const own = await CatalogSubscription.findOne({ catalogId })
      .select({ status: 1, pendingPaymentUsedAt: 1 })
      .lean<{ status: string; pendingPaymentUsedAt?: Date }>()
      .exec();
    // The window this catalog is ALREADY in is not a refusal to report as
    // "already used" — the publish that found it should simply go ahead.
    if (own?.status === 'PENDING_PAYMENT') return { outcome: 'SUBSCRIPTION_ACTIVE' };
    return { outcome: 'ALREADY_USED' };
  }

  const { pendingPaymentDays, pendingPaymentThreeDCap } = await getPlanCatalog();
  const paymentDueAt = new Date(now.getTime() + pendingPaymentDays * DAY_MS);
  const windowFields = {
    status: 'PENDING_PAYMENT' as const,
    source: 'REP_PUBLISH' as const,
    periodStart: now,
    // `periodEnd` IS the deadline. There is no grace behind a window that was
    // never paid for — the sweep switches the page off at this instant.
    periodEnd: paymentDueAt,
    threeDDishCap: pendingPaymentThreeDCap,
    pendingPaymentUsedAt: now,
    pendingPaymentActivatedBy: actor,
  };

  let started = false;
  let row: { _id: Types.ObjectId; updatedAt: Date } | null = null;
  try {
    const created = await CatalogSubscription.create({
      catalogId,
      userId: ownerUserId,
      ...windowFields,
    });
    row = { _id: created._id as Types.ObjectId, updatedAt: created.updatedAt };
    started = true;
  } catch (err) {
    if (!isDuplicateKey(err)) throw err;
    // A row exists — written a moment ago by the other press, or long ago.
  }

  if (!started) {
    const updated = await CatalogSubscription.findOneAndUpdate(
      { catalogId, pendingPaymentUsedAt: null, status: { $in: ['CANCELLED', 'PAUSED'] } },
      {
        $set: windowFields,
        $unset: {
          planId: 1,
          planSnapshot: 1,
          billingInterval: 1,
          graceEndsAt: 1,
          graceFrom: 1,
          disputeGraceAt: 1,
          pausedAt: 1,
          cancelledAt: 1,
          // A reopened window means the page is live again by definition.
          pageDeactivatedAt: 1,
        },
      },
      { new: true }
    )
      .select({ _id: 1, updatedAt: 1 })
      .lean<{ _id: Types.ObjectId; updatedAt: Date }>()
      .exec();

    if (!updated) {
      // The guard failed for one of two reasons; a re-read tells them apart.
      const existing = await CatalogSubscription.findOne({ catalogId })
        .select({ status: 1, pendingPaymentUsedAt: 1 })
        .lean<{ status: string; pendingPaymentUsedAt?: Date }>()
        .exec();
      if (existing?.pendingPaymentUsedAt) return { outcome: 'ALREADY_USED' };
      return { outcome: 'SUBSCRIPTION_ACTIVE' };
    }
    row = updated;
  }

  track(AnalyticsEvent.SUBSCRIPTION_PENDING_PAYMENT_STARTED, {
    catalog_id: catalogId.toHexString(),
    actor_role: actor.role,
    days: pendingPaymentDays,
  });
  // Tell Mirage the deadline so its public menu can show the banner. BEST
  // EFFORT: the window exists whether or not this job lands, and a failure here
  // must not fail the publish that is about to happen. The page is already live
  // (or about to be, via the publish run itself), so the only thing a lost job
  // costs is the banner — and the next state change re-enqueues one.
  if (row) {
    try {
      await enqueuePageStateJob({
        catalogId,
        ownerUserId,
        isPublished: true,
        paymentDueAt,
        reason: 'PENDING_PAYMENT_STARTED',
        dedupeAt: row.updatedAt,
      });
    } catch (err) {
      console.error(
        `[pending-payment] page-state enqueue failed for catalog ${catalogId.toHexString()}`,
        err
      );
    }
  }

  // The owner is told the moment the window opens, not ten minutes later in
  // the words of a countdown. The sweep's earliest reminder is -7 d, so a
  // window configured longer than a week would otherwise open in silence —
  // and "your menu is live" is news on the day it becomes true.
  await notifyPaymentWindowOpened({
    catalogId,
    ownerUserId,
    paymentDueAt,
    windowDays: pendingPaymentDays,
  });

  return { outcome: 'STARTED', paymentDueAt };
}

/**
 * The publish-time hook: called by `requestPublish` when a rep or staff member
 * is the one asking. Returns true when a window is now in force (either it just
 * opened one, or one was already running), i.e. when the subscription gate
 * should be re-evaluated against a row that did not exist a moment ago.
 *
 * NEVER THROWS FOR ITS OWN REASONS. A store hiccup here would otherwise turn a
 * publishable catalog into a 500 for a rep standing at a table; the publish then
 * proceeds to the gates, which refuse it with the ordinary "choose a plan"
 * sentence — a worse message, but an honest and recoverable one.
 */
export async function openPendingPaymentWindowForPublish(
  catalogId: Types.ObjectId,
  ownerUserId: Types.ObjectId,
  actor: Actor,
  now: Date = new Date()
): Promise<boolean> {
  if (!roleMayOpenPendingPayment(actor.role)) return false;
  try {
    // The common case by far, and the cheap one: this restaurant is already on
    // something. One indexed read, and neither the owner-history queries nor a
    // write happens on the publish path of a paying customer.
    const existing = await CatalogSubscription.findOne({ catalogId })
      .select({ status: 1 })
      .lean<{ status: SubscriptionStatus }>()
      .exec();
    if (existing && isEntitledTo3D(existing.status)) return false;

    const result = await startPendingPayment(catalogId, ownerUserId, actor, now);
    return result.outcome === 'STARTED' || result.outcome === 'SUBSCRIPTION_ACTIVE';
  } catch (err) {
    console.error(
      `[pending-payment] could not open a window for catalog ${catalogId.toHexString()}`,
      err
    );
    return false;
  }
}
