// src/services/subscription/subscriptionService.ts
//
// The subscription as the screens read it, and the writes on the row: a trial
// start (Door 1, RECAPTURE_SUBSCRIPTION_PLAN.md §4), the cancel that rides on
// a catalog delete (§8 C9), and — Stage 3 — the ONE activation primitive
// (`applyPaidPeriod`) every paid door funnels through, plus its comp variant.
//
// No Express types. Every DTO is built field by field — the analytics-proxy
// rule: nothing spreads a Mongoose document onto the wire.
//
// TWO THINGS THE DTO DOES THAT A CLIENT MUST NOT REDO:
//   • `daysLeft` is computed HERE (D6). Two phones with two clocks looking at
//     one restaurant must read the same number, and a client-side "days until"
//     is the classic off-by-a-timezone.
//   • `threeDDishCount` is counted over `publishableProducts()` — the SAME list
//     the publish gate counts (README C1) — so the usage line and the gate can
//     never disagree about how many slots a menu takes.
import { Types } from 'mongoose';

import { CatalogProduct } from '@/models/CatalogProduct';
import { CatalogSubscription, isEntitledTo3D } from '@/models/CatalogSubscription';
import { Notification } from '@/models/Notification';
import { PaymentRecord } from '@/models/PaymentRecord';
import type { ICatalogSubscription } from '@/models/CatalogSubscription';
import {
  isUncapped,
  UNCAPPED_THREE_D,
  type Actor,
  type BillingInterval,
  type PaymentVia,
  type PlanCatalog,
  type PlanDefinition,
  type PlanId,
  type SubscriptionStatus,
} from '@/models/types/subscription.types';
import { publishableProducts } from '@/services/catalog/publishableProducts';
import { enqueueArEntitlementJob } from '@/services/subscription/arEntitlementJobs';
import { enqueuePageStateJob } from '@/services/subscription/pageStateJobs';
import {
  notifyCompGranted,
  notifyPlanActivated,
  notifyTrialStarted,
} from '@/services/subscription/ownerNotifications';
import { getPlanCatalog } from '@/services/subscription/planCatalogService';
import { countThreeDDishes, countsAsThreeD } from '@/services/subscription/threeDDishCount';
import { track, AnalyticsEvent } from '@/utils/analytics';
import { hashIdentifier } from '@/utils/otp';

const DAY_MS = 86_400_000;

/** What a list row or the catalog header needs — nothing that costs a second query. */
export interface SubscriptionSummaryDto {
  status: SubscriptionStatus;
  daysLeft: number | null;
  planId: PlanId | null;
  /**
   * In GRACE: which state it lapsed from (TRIAL / ACTIVE / COMPED), so the
   * banner can say "trial ended" to a restaurant that never paid (E16).
   * Null outside GRACE, on a dispute-grace, and on rows written before the
   * sweep existed — all of which read as "payment overdue".
   */
  graceFrom: SubscriptionStatus | null;
  isEntitledTo3D: boolean;
  /** Whether Start trial would succeed right now — see {@link startTrial}. */
  trialAvailable: boolean;
  /**
   * ISO — when this restaurant's LIVE CUSTOMER PAGE is due to be switched off
   * for non-payment, or null when nothing is due (requirement 2). Set while
   * PENDING_PAYMENT, and kept after the window expired so the copy can still
   * name the date the link died.
   *
   * SERVER-COMPUTED, like `daysLeft` and for the same reason (D6): it is the
   * instant the sweep will act on, not a day count a client multiplies out.
   */
  paymentDueAt: string | null;
  /**
   * True when the page is ALREADY dark — the window expired unpaid. Distinct
   * from `paymentDueAt` being in the past: a sweep that has not run yet leaves
   * a deadline behind with the page still up, and the copy must not claim a
   * link is dead while it is still answering.
   */
  isPageDeactivated: boolean;
}

/** The subscription screen, in one read. */
export interface SubscriptionStatusDto {
  status: SubscriptionStatus | 'NONE';
  planId: PlanId | null;
  planName: string | null;
  /**
   * The plan AS BOUGHT — the frozen copy the period runs under. The screen
   * compares its `priceMonthlyPaise` to `plans[planId]` to say "your price
   * was locked; renewals are X" (B6). Null on TRIAL, COMPED and no row.
   */
  planSnapshot: PlanDefinition | null;
  billingInterval: BillingInterval | null;
  /** ISO. */
  periodEnd: string | null;
  graceEndsAt: string | null;
  /** See SubscriptionSummaryDto.graceFrom. */
  graceFrom: SubscriptionStatus | null;
  /**
   * SERVER-computed (D6): whole days until the period ends, never below 0; in
   * GRACE, until grace ends. Null when nothing is counting down (no row,
   * PAUSED, CANCELLED).
   */
  daysLeft: number | null;
  /** READY-model dishes a publish would send — the number the cap is against. */
  threeDDishCount: number;
  /** Null = uncapped (a comp). */
  threeDDishCap: number | null;
  /** Live dishes that do NOT count as 3D. Never capped. */
  imageDishCount: number;
  trialAvailable: boolean;
  isEntitledTo3D: boolean;
  /** See {@link SubscriptionSummaryDto.paymentDueAt}. */
  paymentDueAt: string | null;
  /** See {@link SubscriptionSummaryDto.isPageDeactivated}. */
  isPageDeactivated: boolean;
  standeeAllocation: { included: number; issued: number } | null;
  /** So the screen never needs a second call for the plan cards. */
  plans: PlanCatalog;
}

export type SubscriptionRow = Pick<
  ICatalogSubscription,
  | 'status'
  | 'planId'
  | 'planSnapshot'
  | 'billingInterval'
  | 'periodEnd'
  | 'graceEndsAt'
  | 'graceFrom'
  | 'trialUsedAt'
  | 'threeDDishCap'
  | 'standeeAllocation'
  | 'pageDeactivatedAt'
>;

/** The catalog's row, or null when it has none. */
export async function getOrNull(catalogId: Types.ObjectId): Promise<SubscriptionRow | null> {
  return CatalogSubscription.findOne({ catalogId }).lean<SubscriptionRow>().exec();
}

/** The frozen snapshot, field by field — never the lean subdocument spread onto the wire. */
function toPlanDefinition(plan: PlanDefinition): PlanDefinition {
  return {
    planId: plan.planId,
    displayName: plan.displayName,
    priceMonthlyPaise: plan.priceMonthlyPaise,
    yearlyDiscountPct: plan.yearlyDiscountPct,
    threeDDishCap: plan.threeDDishCap,
    includedStandeeCount: plan.includedStandeeCount,
    features: [...plan.features],
  };
}

/** `Math.max(0, ceil(ms / day))` — the one formula, in one place. */
function daysUntil(when: Date, now: Date): number {
  return Math.max(0, Math.ceil((when.getTime() - now.getTime()) / DAY_MS));
}

/**
 * Days a payment made NOW would throw away (E9): a fresh period always starts
 * at `paidAt` (AC-3.5), so paying while ACTIVE / TRIAL / COMPED forfeits what
 * was left. GRACE, PAUSED, CANCELLED and "no row" forfeit nothing.
 */
export function daysForfeitedFor(
  row: Pick<ICatalogSubscription, 'status' | 'periodEnd'> | null,
  now: Date
): number {
  if (!row) return 0;
  switch (row.status) {
    case 'ACTIVE':
    case 'TRIAL':
    case 'COMPED':
      return daysUntil(row.periodEnd, now);
    // PENDING_PAYMENT forfeits NOTHING, deliberately: the days left on it are
    // days of unpaid grace, not days that were bought. Telling an owner that
    // paying today throws away six free days is both true and exactly the
    // wrong thing to put in front of a restaurant we are chasing for money.
    default:
      return 0;
  }
}

/**
 * Which date the status is counting down to, if any. GRACE counts to the end
 * of grace, not of the period that already ended; PAUSED and CANCELLED count
 * to nothing.
 */
export function daysLeftFor(row: SubscriptionRow, now: Date): number | null {
  switch (row.status) {
    case 'GRACE':
      return daysUntil(row.graceEndsAt ?? row.periodEnd, now);
    // PENDING_PAYMENT counts to `periodEnd` like any other running period.
    // There is no grace behind it: `periodEnd` IS the moment the page goes
    // dark, which is why the window is the whole countdown. (The comment sits
    // ABOVE the group rather than between two labels: `no-fallthrough` reads a
    // comment inside an empty case body as a non-empty one and rejects it.)
    case 'TRIAL':
    case 'PENDING_PAYMENT':
    case 'ACTIVE':
    case 'COMPED':
      return daysUntil(row.periodEnd, now);
    case 'PAUSED':
    case 'CANCELLED':
      return null;
  }
}

// ── Trial eligibility ───────────────────────────────────────────────────────

/**
 * Whether a trial could start on THIS row, ignoring the owner's history: no
 * row, or a lapsed one that never had a trial. A live row (TRIAL / ACTIVE /
 * GRACE / COMPED) cannot be replaced by a trial, whatever its history.
 */
function rowAllowsTrial(row: SubscriptionRow | null): boolean {
  if (row === null) return true;
  return (
    !row.trialUsedAt &&
    (row.status === 'CANCELLED' ||
      row.status === 'PAUSED' ||
      // A trial SUPERSEDES a pending-payment window — the "(or free trial
      // limit)" half of the requirement. A rep who published a restaurant
      // before anybody paid can still grant the free month afterwards, and
      // doing so has to clear the deadline rather than run beside it. This is
      // the one LIVE status a trial may replace, and startTrial is what puts
      // the customer page back and cancels the debt.
      row.status === 'PENDING_PAYMENT')
  );
}

/**
 * The OWNER's history, across every catalog they have had — including the
 * ones `DELETE /catalog` hard-deleted (the rows outlive the catalog; see
 * `CatalogSubscription.userId`). Two rules:
 *   • one trial ever (D2): a trial on a deleted catalog still counts;
 *   • a trial is for restaurants that have never been customers (E41): an
 *     owner with a PAID or VERIFIED manual payment behind them gets no free
 *     month by deleting and re-creating.
 */
async function ownerTrialHistory(
  ownerUserId: Types.ObjectId
): Promise<{ usedTrial: boolean; hasPaid: boolean }> {
  const [usedTrial, hasPaid] = await Promise.all([
    CatalogSubscription.exists({ userId: ownerUserId, trialUsedAt: { $ne: null } }).exec(),
    PaymentRecord.exists({
      userId: ownerUserId,
      $or: [{ kind: 'PAID' }, { kind: 'MANUAL', verificationStatus: 'VERIFIED' }],
    }).exec(),
  ]);
  return { usedTrial: usedTrial !== null, hasPaid: hasPaid !== null };
}

async function trialAvailableFor(
  ownerUserId: Types.ObjectId,
  row: SubscriptionRow | null
): Promise<boolean> {
  if (!rowAllowsTrial(row)) return false;
  const history = await ownerTrialHistory(ownerUserId);
  return !history.usedTrial && !history.hasPaid;
}

// ── Reads ───────────────────────────────────────────────────────────────────

function toSummary(
  row: SubscriptionRow,
  now: Date,
  trialAvailable: boolean
): SubscriptionSummaryDto {
  return {
    status: row.status,
    daysLeft: daysLeftFor(row, now),
    planId: row.planId ?? null,
    graceFrom: graceFromOf(row),
    isEntitledTo3D: isEntitledTo3D(row.status),
    trialAvailable,
    paymentDueAt: paymentDueAtOf(row),
    isPageDeactivated: row.pageDeactivatedAt != null,
  };
}

/**
 * The deadline a client renders, or null when there is none.
 *
 * Two rows carry one: a running PENDING_PAYMENT window (its `periodEnd` IS the
 * deadline — there is no grace behind it) and a row whose page has already been
 * switched off (kept, so the copy can name the date). Every other status — a
 * trial, a plan, a lapse, a comp — has nothing due, because nothing about them
 * can take a customer page down.
 */
function paymentDueAtOf(
  row: Pick<SubscriptionRow, 'status' | 'periodEnd' | 'pageDeactivatedAt'>
): string | null {
  if (row.status === 'PENDING_PAYMENT' || row.pageDeactivatedAt != null) {
    return row.periodEnd.toISOString();
  }
  return null;
}

/** Only meaningful while the row IS in grace; anything else reads as null. */
function graceFromOf(row: Pick<SubscriptionRow, 'status' | 'graceFrom'>): SubscriptionStatus | null {
  return row.status === 'GRACE' ? (row.graceFrom ?? null) : null;
}

/**
 * The compact summary for `GET /catalog` and the rep list. Null when the
 * catalog has no row — which is what a client renders as "No plan".
 */
export async function getSubscriptionSummary(
  catalogId: Types.ObjectId,
  ownerUserId: Types.ObjectId,
  now: Date = new Date()
): Promise<SubscriptionSummaryDto | null> {
  const row = await getOrNull(catalogId);
  if (!row) return null;
  return toSummary(row, now, await trialAvailableFor(ownerUserId, row));
}

/**
 * Summaries for a LIST — one subscription query for all the ids, never one
 * per row. Owner history is resolved once per distinct owner, and only for
 * the rows that could take a trial.
 */
export async function getSubscriptionSummaries(
  catalogs: readonly { catalogId: Types.ObjectId; ownerUserId: Types.ObjectId }[],
  now: Date = new Date()
): Promise<Map<string, SubscriptionSummaryDto>> {
  const out = new Map<string, SubscriptionSummaryDto>();
  if (catalogs.length === 0) return out;

  const rows = await CatalogSubscription.find({
    catalogId: { $in: catalogs.map((c) => c.catalogId) },
  })
    .lean<(SubscriptionRow & { catalogId: Types.ObjectId })[]>()
    .exec();
  const byCatalog = new Map(rows.map((row) => [String(row.catalogId), row]));

  const historyByOwner = new Map<string, Promise<{ usedTrial: boolean; hasPaid: boolean }>>();
  for (const { catalogId, ownerUserId } of catalogs) {
    const row = byCatalog.get(String(catalogId));
    if (!row) continue;
    let trialAvailable = false;
    if (rowAllowsTrial(row)) {
      const key = String(ownerUserId);
      let history = historyByOwner.get(key);
      if (!history) {
        history = ownerTrialHistory(ownerUserId);
        historyByOwner.set(key, history);
      }
      const { usedTrial, hasPaid } = await history;
      trialAvailable = !usedTrial && !hasPaid;
    }
    out.set(String(catalogId), toSummary(row, now, trialAvailable));
  }
  return out;
}

/** The whole subscription screen: the row, the usage, the plans. */
export async function getSubscriptionStatus(
  catalogId: Types.ObjectId,
  ownerUserId: Types.ObjectId,
  now: Date = new Date()
): Promise<SubscriptionStatusDto> {
  const [row, plans, products] = await Promise.all([
    getOrNull(catalogId),
    getPlanCatalog(),
    CatalogProduct.find({ catalogId, deletedAt: null })
      .select({ deletedAt: 1, archivedAt: 1, modelStatus: 1, 'assets.glbUrl': 1 })
      .lean()
      .exec(),
  ]);

  const live = publishableProducts(products);
  let threeDDishCount = 0;
  for (const product of live) if (countsAsThreeD(product)) threeDDishCount += 1;
  const imageDishCount = live.length - threeDDishCount;

  const trialAvailable = await trialAvailableFor(ownerUserId, row);

  if (!row) {
    return {
      status: 'NONE',
      planId: null,
      planName: null,
      planSnapshot: null,
      billingInterval: null,
      periodEnd: null,
      graceEndsAt: null,
      graceFrom: null,
      daysLeft: null,
      threeDDishCount,
      threeDDishCap: null,
      imageDishCount,
      trialAvailable,
      isEntitledTo3D: false,
      // No row means nothing was ever published on anybody's behalf, so there
      // is no deadline and no page that was taken down.
      paymentDueAt: null,
      isPageDeactivated: false,
      standeeAllocation: null,
      plans,
    };
  }

  return {
    status: row.status,
    planId: row.planId ?? null,
    planName: row.planSnapshot?.displayName ?? null,
    planSnapshot: row.planSnapshot ? toPlanDefinition(row.planSnapshot) : null,
    billingInterval: row.billingInterval ?? null,
    periodEnd: row.periodEnd.toISOString(),
    graceEndsAt: row.graceEndsAt?.toISOString() ?? null,
    graceFrom: graceFromOf(row),
    daysLeft: daysLeftFor(row, now),
    threeDDishCount,
    threeDDishCap: isUncapped(row.threeDDishCap) ? null : row.threeDDishCap,
    imageDishCount,
    trialAvailable,
    isEntitledTo3D: isEntitledTo3D(row.status),
    paymentDueAt: paymentDueAtOf(row),
    isPageDeactivated: row.pageDeactivatedAt != null,
    standeeAllocation: {
      included: row.standeeAllocation?.included ?? 0,
      issued: row.standeeAllocation?.issued ?? 0,
    },
    plans,
  };
}

// ── Writes ──────────────────────────────────────────────────────────────────

export type StartTrialResult =
  | { outcome: 'STARTED'; dto: SubscriptionStatusDto }
  /** This restaurant (or its owner, on an earlier catalog) already had its trial. */
  | { outcome: 'TRIAL_ALREADY_USED' }
  /** A live row — TRIAL, ACTIVE, GRACE or COMPED — is in the way. */
  | { outcome: 'SUBSCRIPTION_ACTIVE' }
  /** The owner has paid before; a trial is for restaurants that never were customers (E41). */
  | { outcome: 'TRIAL_NOT_ELIGIBLE' };

/** Which door the actor came through — an analytics dimension, not an authority. */
export type TrialDoor = 'REP' | 'ADMIN';

function isDuplicateKey(err: unknown): boolean {
  return (
    typeof err === 'object' &&
    err !== null &&
    'code' in err &&
    (err as { code?: unknown }).code === 11000
  );
}

/**
 * Starts the one free trial a restaurant gets. Plan and length come from
 * config, never from the caller.
 *
 * ATOMIC THE HOUSE WAY (no transactions), so two reps tapping at once end with
 * one trial and one 409 (A5):
 *   • no row → `create`; a loser's E11000 means the other tap won, and it falls
 *     through to the row-exists path, where a fresh TRIAL reads as ACTIVE.
 *   • a row → a conditional `findOneAndUpdate` guarded on `trialUsedAt: null`
 *     and a lapsed status. Null means the guard failed; a re-read says why.
 * The owner-history checks run first and are advisory against a race — the
 * row-level guard is the authority, and the worst a race can do there is let a
 * paid-then-deleted owner past E41, which is a policy edge, not a double trial.
 */
export async function startTrial(
  catalogId: Types.ObjectId,
  ownerUserId: Types.ObjectId,
  actor: Actor,
  door: TrialDoor,
  now: Date = new Date()
): Promise<StartTrialResult> {
  const refused = (
    outcome: 'TRIAL_ALREADY_USED' | 'SUBSCRIPTION_ACTIVE' | 'TRIAL_NOT_ELIGIBLE'
  ): StartTrialResult => {
    track(AnalyticsEvent.SUBSCRIPTION_TRIAL_REFUSED, {
      catalog_id: catalogId.toHexString(),
      actor_role: actor.role,
      reason:
        outcome === 'TRIAL_ALREADY_USED'
          ? 'ALREADY_USED'
          : outcome === 'SUBSCRIPTION_ACTIVE'
            ? 'ACTIVE'
            : 'NOT_ELIGIBLE',
    });
    return { outcome };
  };

  const history = await ownerTrialHistory(ownerUserId);
  if (history.hasPaid) return refused('TRIAL_NOT_ELIGIBLE');
  if (history.usedTrial) {
    // Either this catalog's own row (answered precisely below) or a trial on
    // a catalog the owner has since deleted (D2) — same answer.
    const own = await getOrNull(catalogId);
    if (!own || !isEntitledTo3D(own.status)) return refused('TRIAL_ALREADY_USED');
    return refused('SUBSCRIPTION_ACTIVE');
  }

  const { trialDays, trialThreeDCap } = await getPlanCatalog();
  const trialFields = {
    status: 'TRIAL' as const,
    source: 'TRIAL' as const,
    periodStart: now,
    periodEnd: new Date(now.getTime() + trialDays * DAY_MS),
    threeDDishCap: trialThreeDCap,
    trialUsedAt: now,
    trialActivatedBy: actor,
  };

  // Was this restaurant's page dark, or carrying a payment deadline, before the
  // trial? Read BEFORE the write, because the write clears both. A trial
  // superseding a pending-payment window is the "(or free trial limit)" half of
  // requirement 2, and the deadline it replaces has to come off Mirage too.
  const beforeTrial = await previousRowOf(catalogId);

  let started = false;
  let startedRow: ICatalogSubscription | { updatedAt: Date; userId: Types.ObjectId } | null = null;
  try {
    startedRow = await CatalogSubscription.create({
      catalogId,
      userId: ownerUserId,
      ...trialFields,
    });
    started = true;
  } catch (err) {
    if (!isDuplicateKey(err)) throw err;
    // A row exists — written a moment ago by the other tap, or long ago.
  }

  if (!started) {
    const updated = await CatalogSubscription.findOneAndUpdate(
      // PENDING_PAYMENT joins the two lapsed statuses here: a trial is strictly
      // better for the restaurant than a week-long ultimatum, and a rep who
      // published first and granted the trial afterwards must not be told the
      // restaurant "already has an active subscription". `rowAllowsTrial` — what
      // `trialAvailable` on every screen is computed from — lists the same three.
      { catalogId, trialUsedAt: null, status: { $in: ['CANCELLED', 'PAUSED', 'PENDING_PAYMENT'] } },
      {
        $set: trialFields,
        $unset: {
          planId: 1,
          planSnapshot: 1,
          billingInterval: 1,
          graceEndsAt: 1,
          graceFrom: 1,
          disputeGraceAt: 1,
          pausedAt: 1,
          cancelledAt: 1,
          // The trial replaces the deadline; the page is live and nothing is
          // due. `pendingPaymentUsedAt` is NOT unset — like `trialUsedAt` it is
          // a one-ever flag and outlives the period it opened.
          pageDeactivatedAt: 1,
        },
      },
      { new: true }
    ).exec();

    startedRow = updated;
    if (!updated) {
      const row = await getOrNull(catalogId);
      // The guard failed for one of two reasons; the re-read tells them apart.
      // A row that is live (which includes the trial the OTHER rep just
      // started) is "active"; a lapsed row can only have failed on trialUsedAt.
      if (row && isEntitledTo3D(row.status)) return refused('SUBSCRIPTION_ACTIVE');
      return refused('TRIAL_ALREADY_USED');
    }
  }

  // 3D, if the trial displaced a row Mirage is currently hiding it on. A trial
  // over a PAUSED / CANCELLED row was always allowed (see `rowAllowsTrial`) and
  // never enqueued this; the expired-window path — PAUSED with a dark page, then
  // a rep grants the trial — is what makes it routine rather than theoretical.
  // Same best-effort contract as `enqueueArResume`, which is what this calls.
  if (startedRow && needsArResumeFrom(beforeTrial.status)) {
    await enqueueArResume(
      { catalogId, userId: ownerUserId, updatedAt: startedRow.updatedAt },
      'PAYMENT',
      beforeTrial.status
    );
  }

  // The page and the deadline, if the trial displaced either. Best-effort and
  // never fatal: the trial IS started, and an admin resync is the backstop.
  if (startedRow && needsPageRestoreFrom(beforeTrial)) {
    try {
      await enqueuePageStateJob({
        catalogId,
        ownerUserId,
        isPublished: true,
        paymentDueAt: null,
        reason: 'TRIAL',
        dedupeAt: startedRow.updatedAt,
      });
    } catch (err) {
      console.error(
        `[subscription] ${catalogId.toHexString()} trial superseded a pending-payment window but ` +
          'the page-state job could not be enqueued — admin resync needed',
        err
      );
    }
  }

  track(AnalyticsEvent.SUBSCRIPTION_TRIAL_STARTED, {
    catalog_id: catalogId.toHexString(),
    actor_role: actor.role,
    actor_id_hash: hashIdentifier(actor.userId.toHexString()),
    door,
  });

  // The rep who started this walks out of the restaurant; the end date has to
  // stay behind in writing. Keyed on the trial's own end, so the two taps that
  // race for one trial send one message. Never throws (ownerNotifications.ts).
  await notifyTrialStarted({
    catalogId,
    ownerUserId,
    endsAt: trialFields.periodEnd,
    trialDays,
    threeDDishCap: trialThreeDCap,
  });

  return { outcome: 'STARTED', dto: await getSubscriptionStatus(catalogId, ownerUserId, now) };
}

// ── The activation primitive (Stage 3) ──────────────────────────────────────

/** Which path is applying the period — an analytics dimension, not an authority. */
/** CLIENT: the app's signed checkout response, verified server-side (clientVerifyService). */
export type ApplyVia = PaymentVia;

export interface ApplyPaidPeriodInput {
  catalogId: Types.ObjectId;
  /** The catalog's owner — written on the row when the payment CREATES it. */
  ownerUserId: Types.ObjectId;
  planId: PlanId;
  interval: BillingInterval;
  source: 'ONLINE' | 'MANUAL';
  paidAt: Date;
  /** The plan AS QUOTED — the frozen copy from the ledger row, never re-read. */
  planSnapshot: PlanDefinition;
  standeeIncluded: number;
  /** For the `subscription_payment_recorded` event. */
  amountPaise: number;
  /**
   * The ledger row this period was bought with. REQUIRED, and only the owner's
   * "payment received" notification reads it: keying that message on the
   * PAYMENT rather than on `paidAt` is what makes it exactly-once. A webhook
   * that applied a period but crashed before stamping `appliedAt` is re-run by
   * the reconciler with a fresh clock — a different `paidAt`, the same payment
   * — and an owner must not be told twice that one payment arrived.
   */
  paymentRecordId: Types.ObjectId;
  via: ApplyVia;
}

export interface ApplyPeriodResult {
  previousStatus: SubscriptionStatus | 'NONE';
  subscription: ICatalogSubscription;
  /**
   * True when the row came out of PAUSED or CANCELLED — Mirage was told to
   * hide the 3D dishes and must be told to show them again. Stage 5 enqueues
   * the resume job on this; until then it is returned and logged.
   */
  needsArResume: boolean;
  /**
   * True when Mirage is holding a payment deadline, a dark customer page, or
   * both, and this activation has just made them wrong (requirement 2). Two
   * separate cases, one flag:
   *   • the row was PENDING_PAYMENT — the page is live but carrying a "switches
   *     off on the Nth" banner that has to come down;
   *   • the row had `pageDeactivatedAt` — the window expired and the page is
   *     DARK. This is the case an owner is refreshing the link waiting for.
   */
  needsPageRestore: boolean;
}

/** Every field the previous period may have set that a fresh one must clear. */
const CLEARED_ON_NEW_PERIOD = {
  graceEndsAt: null,
  graceFrom: null,
  disputeGraceAt: null,
  pausedAt: null,
  cancelledAt: null,
  // Whatever the page state was, a paid (or comped) period means it is live and
  // nothing is due. Cleared here rather than only where the job is enqueued, so
  // the ROW is the truth even if the job never lands — and the processor, which
  // re-derives the desired state from the row, then does the right thing on an
  // admin resync.
  //
  // NOT cleared: `pendingPaymentUsedAt`, which is the "one window ever" flag and
  // outlives everything, exactly as `trialUsedAt` does.
  pageDeactivatedAt: null,
} as const;

/**
 * The row-level write both primitives share: an upsert keyed on the unique
 * `catalogId`, so a payment on a catalog with no row creates one (an owner may
 * pay before any trial) and two racing appliers converge on one row. The
 * loser of a concurrent first-insert gets E11000 from the unique index and
 * simply runs the same update again — the values are identical by
 * construction, which is what makes the whole thing idempotent.
 */
async function upsertSubscriptionRow(
  catalogId: Types.ObjectId,
  ownerUserId: Types.ObjectId,
  update: Record<string, unknown>
): Promise<ICatalogSubscription> {
  for (let attempt = 0; ; attempt++) {
    try {
      const { $setOnInsert: onInsert, ...rest } = update as { $setOnInsert?: object };
      const doc = await CatalogSubscription.findOneAndUpdate(
        { catalogId },
        { ...rest, $setOnInsert: { userId: ownerUserId, ...(onInsert ?? {}) } },
        { upsert: true, new: true, setDefaultsOnInsert: true }
      ).exec();
      if (doc) return doc;
      throw new Error('subscription upsert returned no document');
    } catch (err) {
      if (attempt > 0 || !isDuplicateKey(err)) throw err;
    }
  }
}

/**
 * The row as it stood BEFORE this activation — its status and whether its
 * customer page had been switched off. Both are needed to decide what Mirage
 * has to be told, and reading them together is one query instead of two.
 */
interface PreviousRow {
  status: SubscriptionStatus | 'NONE';
  pageDeactivatedAt: Date | null;
}

/**
 * The three fields the two enqueue helpers need — the catalog, its owner, and
 * the `updatedAt` the idempotency key is derived from.
 *
 * Narrower than `ICatalogSubscription` on purpose: `startTrial` reaches these
 * helpers without a Mongoose document in hand (its write may have been a lean
 * `findOneAndUpdate`), and a signature that demanded one would only be satisfied
 * with a cast — which is how a field nobody passed becomes an undefined at
 * runtime.
 */
type ResumableRow = Pick<ICatalogSubscription, 'catalogId' | 'userId' | 'updatedAt'>;

async function previousRowOf(catalogId: Types.ObjectId): Promise<PreviousRow> {
  const row = await CatalogSubscription.findOne({ catalogId })
    .select({ status: 1, pageDeactivatedAt: 1 })
    .lean<{ status: SubscriptionStatus; pageDeactivatedAt?: Date }>()
    .exec();
  return {
    status: row?.status ?? 'NONE',
    pageDeactivatedAt: row?.pageDeactivatedAt ?? null,
  };
}

function needsArResumeFrom(previousStatus: SubscriptionStatus | 'NONE'): boolean {
  return previousStatus === 'PAUSED' || previousStatus === 'CANCELLED';
}

/**
 * Whether Mirage's page fields are now wrong — see
 * {@link ApplyPeriodResult.needsPageRestore}.
 *
 * PENDING_PAYMENT is in even though its page is already live, because the
 * DEADLINE is also on Mirage and a paid restaurant must not keep showing
 * "switches off in 2 days" to its diners.
 */
function needsPageRestoreFrom(previous: PreviousRow): boolean {
  return previous.status === 'PENDING_PAYMENT' || previous.pageDeactivatedAt !== null;
}

/**
 * The E11 nudge. The cap is enforced at PUBLISH only (§3a), so a paused
 * restaurant with thirty published 3D dishes that buys the ten-dish plan
 * keeps all thirty live until it next publishes. Nothing is hidden and the
 * activation is never blocked; the owner is told, once, and the admin side
 * sees the event. Counted over the PUBLISHED set (rows Mirage holds), not the
 * draft — that is what the customer is looking at.
 */
async function nudgeIfOverCap(
  catalogId: Types.ObjectId,
  ownerUserId: Types.ObjectId,
  plan: PlanDefinition
): Promise<void> {
  if (isUncapped(plan.threeDDishCap)) return;
  const published = await CatalogProduct.find({
    catalogId,
    deletedAt: null,
    archivedAt: null,
    mirageItemId: { $type: 'string' },
  })
    .select({ modelStatus: 1, 'assets.glbUrl': 1 })
    .lean()
    .exec();
  const count = countThreeDDishes(published);
  if (count <= plan.threeDDishCap) return;

  try {
    await Notification.create({
      kind: 'PAYMENT_ACTIVATE',
      title: 'Your menu has more 3D dishes than your plan covers',
      message:
        `Your menu has ${count} 3D dishes; ${plan.displayName} covers ${plan.threeDDishCap}. ` +
        'The next publish will ask you to upgrade.',
      audienceType: 'USERS',
      audienceUserIds: [ownerUserId],
      deletedAt: null,
    });
  } catch (err) {
    // A failed nudge must not fail an activation that has already happened.
    console.warn('[subscription] over-cap notification failed', err);
  }
  track(AnalyticsEvent.SUBSCRIPTION_OVER_CAP_ON_ACTIVATE, {
    catalog_id: catalogId.toHexString(),
    plan_id: plan.planId,
    three_d_dish_count: count,
    three_d_dish_cap: plan.threeDDishCap,
  });
}

/**
 * THE activation. Called by exactly three paths — the webhook, the reconciler
 * and the admin's manual VERIFY — and nothing else (a comp has its own variant
 * below), so the rules live once:
 *   • `periodStart = paidAt`, ALWAYS (AC-3.5). Never anchored on the old
 *     `periodEnd`, not even when paying early: an early renewal forfeits the
 *     unused days (Assumption A2), a payment in GRACE starts fresh from the
 *     payment date, and paying out of TRIAL or COMPED simply ends that period
 *     early (`trialUsedAt` stays — E10).
 *   • `periodEnd = paidAt + 30 | 365` calendar days in UTC — millisecond
 *     arithmetic, no timezone.
 *   • Upsert: a catalog with no row gets one.
 *   • Idempotent: the same input applied twice writes the same row.
 */
export async function applyPaidPeriod(input: ApplyPaidPeriodInput): Promise<ApplyPeriodResult> {
  const { catalogId, ownerUserId, paidAt, planSnapshot } = input;
  const previous = await previousRowOf(catalogId);
  const previousStatus = previous.status;
  const periodEnd = new Date(paidAt.getTime() + (input.interval === 'YEARLY' ? 365 : 30) * DAY_MS);

  const subscription = await upsertSubscriptionRow(catalogId, ownerUserId, {
    $set: {
      status: 'ACTIVE',
      planId: input.planId,
      planSnapshot,
      billingInterval: input.interval,
      source: input.source,
      periodStart: paidAt,
      periodEnd,
      threeDDishCap: planSnapshot.threeDDishCap,
      'standeeAllocation.included': input.standeeIncluded,
      ...CLEARED_ON_NEW_PERIOD,
    },
    // A dotted $set on a subdocument skips the parent's default on insert, so
    // a row CREATED by this payment would have no `issued` at all.
    $setOnInsert: { 'standeeAllocation.issued': 0 },
  });

  const needsArResume = needsArResumeFrom(previousStatus);
  if (needsArResume) {
    // Mirage was told to hide this restaurant's 3D when it paused; the job
    // tells it to show it again. Keyed on the row's `updatedAt` — the write
    // above — so a replayed webhook lands on the same job.
    await enqueueArResume(subscription, 'PAYMENT', previousStatus);
  }

  // Requirement 2's other half: the page and the deadline. Independent of the
  // 3D resume above and enqueued separately, because a window that merely
  // expired needs BOTH (its 3D went off with its page) while a window paid
  // inside its deadline needs only this one.
  const needsPageRestore = needsPageRestoreFrom(previous);
  if (needsPageRestore) await enqueuePageRestore(subscription, 'PAYMENT', previous);

  track(AnalyticsEvent.SUBSCRIPTION_PAYMENT_RECORDED, {
    catalog_id: catalogId.toHexString(),
    source: input.source,
    plan_id: input.planId,
    amount_paise: input.amountPaise,
    previous_status: previousStatus,
    via: input.via,
  });

  await nudgeIfOverCap(catalogId, ownerUserId, planSnapshot);

  // "Subs done, next date for payment" — the message the whole notification
  // layer exists for. Keyed on `paidAt` (= `periodStart`), so the webhook, the
  // reconciler and an admin's VERIFY all converge on ONE row for one payment,
  // exactly as this function itself converges on one period.
  await notifyPlanActivated({
    catalogId,
    ownerUserId,
    paymentRecordId: input.paymentRecordId,
    plan: planSnapshot,
    interval: input.interval,
    amountPaise: input.amountPaise,
    periodEnd,
    resumedThreeD: needsArResume,
    restoredPage: needsPageRestore,
  });

  return { previousStatus, subscription, needsArResume, needsPageRestore };
}

export interface ApplyCompInput {
  catalogId: Types.ObjectId;
  ownerUserId: Types.ObjectId;
  /** When the comp ends. The route has already checked it is in the future. */
  until: Date;
  actor: Actor;
  note: string;
  now?: Date;
}

/**
 * Door 4. A comp is not a plan: uncapped, no snapshot, no interval, and a
 * zero-amount COMP row on the ledger so "why is this restaurant live" has an
 * answer with a name on it. Same upsert and the same clears as a paid period.
 */
export async function applyComp(input: ApplyCompInput): Promise<ApplyPeriodResult> {
  const now = input.now ?? new Date();
  const { catalogId, ownerUserId } = input;
  const previous = await previousRowOf(catalogId);
  const previousStatus = previous.status;

  const subscription = await upsertSubscriptionRow(catalogId, ownerUserId, {
    $set: {
      status: 'COMPED',
      source: 'COMP',
      periodStart: now,
      periodEnd: input.until,
      threeDDishCap: UNCAPPED_THREE_D,
      ...CLEARED_ON_NEW_PERIOD,
    },
    $unset: { planId: 1, planSnapshot: 1, billingInterval: 1 },
  });

  await PaymentRecord.create({
    catalogId,
    userId: ownerUserId,
    subscriptionId: subscription._id,
    kind: 'COMP',
    amountPaise: 0,
    currency: 'INR',
    initiatedBy: input.actor,
    note: input.note,
  });

  track(AnalyticsEvent.SUBSCRIPTION_PAYMENT_RECORDED, {
    catalog_id: catalogId.toHexString(),
    source: 'COMP',
    plan_id: null,
    amount_paise: 0,
    previous_status: previousStatus,
    via: 'ADMIN',
  });

  const needsArResume = needsArResumeFrom(previousStatus);
  if (needsArResume) await enqueueArResume(subscription, 'COMP', previousStatus);

  const needsPageRestore = needsPageRestoreFrom(previous);
  if (needsPageRestore) await enqueuePageRestore(subscription, 'COMP', previous);

  // A comp is still a period with an end date, and an owner who was never
  // told about it cannot plan for the day it stops.
  await notifyCompGranted({ catalogId, ownerUserId, grantedAt: now, until: input.until });

  return { previousStatus, subscription, needsArResume, needsPageRestore };
}

/**
 * The resume half of Stage 5: a paid period (or a comp) applied over a
 * PAUSED / CANCELLED row means Mirage is currently hiding this restaurant's
 * 3D and must be told to show it again. Never throws — the period IS applied
 * and the ledger IS written; a job that could not be queued is an admin
 * resync away, and is logged loudly here.
 */
async function enqueueArResume(
  subscription: ResumableRow,
  reason: 'PAYMENT' | 'COMP',
  previousStatus: SubscriptionStatus | 'NONE'
): Promise<void> {
  const catalogId = subscription.catalogId;
  try {
    await enqueueArEntitlementJob({
      catalogId,
      ownerUserId: subscription.userId,
      enabled: true,
      reason,
      dedupeAt: subscription.updatedAt,
    });
    console.log(
      `[subscription] ${catalogId.toHexString()} resumed from ${previousStatus} — AR resume enqueued`
    );
  } catch (err) {
    console.error(
      `[subscription] ${catalogId.toHexString()} resumed from ${previousStatus} but the AR resume ` +
        'job could not be enqueued — admin resync needed',
      err
    );
  }
}

/**
 * The page half of the resume (requirement 2): this restaurant's customer page
 * is dark, or is showing a payment deadline, and the money that just arrived
 * makes both wrong. `{ isPublished: true, paymentDueAt: null }`.
 *
 * NEVER THROWS, for the same reason {@link enqueueArResume} does not: the period
 * IS applied and the ledger IS written, and a job that could not be queued is an
 * admin resync away. It is logged loudly because this is the expensive one — an
 * owner whose page stays dark after paying is the worst state this feature has,
 * and the log line is what an operator greps for.
 */
async function enqueuePageRestore(
  subscription: ResumableRow,
  reason: 'PAYMENT' | 'COMP',
  previous: PreviousRow
): Promise<void> {
  const catalogId = subscription.catalogId;
  const wasDark = previous.pageDeactivatedAt !== null;
  try {
    await enqueuePageStateJob({
      catalogId,
      ownerUserId: subscription.userId,
      isPublished: true,
      paymentDueAt: null,
      reason,
      dedupeAt: subscription.updatedAt,
    });
    console.log(
      `[subscription] ${catalogId.toHexString()} page restored from ${previous.status}` +
        `${wasDark ? ' (was dark)' : ' (deadline cleared)'} — page-state job enqueued`
    );
  } catch (err) {
    console.error(
      `[subscription] ${catalogId.toHexString()} paid but the page-state job could not be ` +
        `enqueued — admin resync needed${wasDark ? ' URGENTLY: the customer page is DARK' : ''}`,
      err
    );
  }
}

/**
 * The cancel that rides on `DELETE /catalog` (C9). No refund, and
 * `trialUsedAt` is left exactly as it was (D2): the row outlives the catalog
 * so the owner's history does. Idempotent when there is no row.
 */
export async function cancelOnCatalogDelete(
  catalogId: Types.ObjectId,
  now: Date = new Date()
): Promise<boolean> {
  const result = await CatalogSubscription.updateOne(
    { catalogId, status: { $ne: 'CANCELLED' } },
    { $set: { status: 'CANCELLED', cancelledAt: now } }
  ).exec();
  return result.modifiedCount > 0;
}
