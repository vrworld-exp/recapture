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
  type PlanCatalog,
  type PlanDefinition,
  type PlanId,
  type SubscriptionStatus,
} from '@/models/types/subscription.types';
import { publishableProducts } from '@/services/catalog/publishableProducts';
import { enqueueArEntitlementJob } from '@/services/subscription/arEntitlementJobs';
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
    case 'TRIAL':
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
  return !row.trialUsedAt && (row.status === 'CANCELLED' || row.status === 'PAUSED');
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
  };
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

  let started = false;
  try {
    await CatalogSubscription.create({ catalogId, userId: ownerUserId, ...trialFields });
    started = true;
  } catch (err) {
    if (!isDuplicateKey(err)) throw err;
    // A row exists — written a moment ago by the other tap, or long ago.
  }

  if (!started) {
    const updated = await CatalogSubscription.findOneAndUpdate(
      { catalogId, trialUsedAt: null, status: { $in: ['CANCELLED', 'PAUSED'] } },
      {
        $set: trialFields,
        $unset: {
          planId: 1,
          planSnapshot: 1,
          billingInterval: 1,
          graceEndsAt: 1,
          graceFrom: 1,
          disputeGraceAt: 1,
        },
      },
      { new: true }
    ).exec();

    if (!updated) {
      const row = await getOrNull(catalogId);
      // The guard failed for one of two reasons; the re-read tells them apart.
      // A row that is live (which includes the trial the OTHER rep just
      // started) is "active"; a lapsed row can only have failed on trialUsedAt.
      if (row && isEntitledTo3D(row.status)) return refused('SUBSCRIPTION_ACTIVE');
      return refused('TRIAL_ALREADY_USED');
    }
  }

  track(AnalyticsEvent.SUBSCRIPTION_TRIAL_STARTED, {
    catalog_id: catalogId.toHexString(),
    actor_role: actor.role,
    actor_id_hash: hashIdentifier(actor.userId.toHexString()),
    door,
  });

  return { outcome: 'STARTED', dto: await getSubscriptionStatus(catalogId, ownerUserId, now) };
}

// ── The activation primitive (Stage 3) ──────────────────────────────────────

/** Which path is applying the period — an analytics dimension, not an authority. */
export type ApplyVia = 'WEBHOOK' | 'RECONCILE' | 'ADMIN';

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
}

/** Every field the previous period may have set that a fresh one must clear. */
const CLEARED_ON_NEW_PERIOD = {
  graceEndsAt: null,
  graceFrom: null,
  disputeGraceAt: null,
  pausedAt: null,
  cancelledAt: null,
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

async function previousStatusOf(catalogId: Types.ObjectId): Promise<SubscriptionStatus | 'NONE'> {
  const row = await CatalogSubscription.findOne({ catalogId })
    .select({ status: 1 })
    .lean<{ status: SubscriptionStatus }>()
    .exec();
  return row?.status ?? 'NONE';
}

function needsArResumeFrom(previousStatus: SubscriptionStatus | 'NONE'): boolean {
  return previousStatus === 'PAUSED' || previousStatus === 'CANCELLED';
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
  const previousStatus = await previousStatusOf(catalogId);
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

  track(AnalyticsEvent.SUBSCRIPTION_PAYMENT_RECORDED, {
    catalog_id: catalogId.toHexString(),
    source: input.source,
    plan_id: input.planId,
    amount_paise: input.amountPaise,
    previous_status: previousStatus,
    via: input.via,
  });

  await nudgeIfOverCap(catalogId, ownerUserId, planSnapshot);

  return { previousStatus, subscription, needsArResume };
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
  const previousStatus = await previousStatusOf(catalogId);

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

  return { previousStatus, subscription, needsArResume };
}

/**
 * The resume half of Stage 5: a paid period (or a comp) applied over a
 * PAUSED / CANCELLED row means Mirage is currently hiding this restaurant's
 * 3D and must be told to show it again. Never throws — the period IS applied
 * and the ledger IS written; a job that could not be queued is an admin
 * resync away, and is logged loudly here.
 */
async function enqueueArResume(
  subscription: ICatalogSubscription,
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
