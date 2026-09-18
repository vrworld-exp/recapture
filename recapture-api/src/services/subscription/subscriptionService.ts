// src/services/subscription/subscriptionService.ts
//
// The subscription as the screens read it, and the two writes this stage
// allows: a trial start (Door 1, RECAPTURE_SUBSCRIPTION_PLAN.md §4) and the
// cancel that rides on a catalog delete (§8 C9).
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
import { PaymentRecord } from '@/models/PaymentRecord';
import type { ICatalogSubscription } from '@/models/CatalogSubscription';
import {
  isUncapped,
  type Actor,
  type BillingInterval,
  type PlanCatalog,
  type PlanId,
  type SubscriptionStatus,
} from '@/models/types/subscription.types';
import { publishableProducts } from '@/services/catalog/publishableProducts';
import { getPlanCatalog } from '@/services/subscription/planCatalogService';
import { countsAsThreeD } from '@/services/subscription/threeDDishCount';
import { track, AnalyticsEvent } from '@/utils/analytics';
import { hashIdentifier } from '@/utils/otp';

const DAY_MS = 86_400_000;

/** What a list row or the catalog header needs — nothing that costs a second query. */
export interface SubscriptionSummaryDto {
  status: SubscriptionStatus;
  daysLeft: number | null;
  planId: PlanId | null;
  isEntitledTo3D: boolean;
  /** Whether Start trial would succeed right now — see {@link startTrial}. */
  trialAvailable: boolean;
}

/** The subscription screen, in one read. */
export interface SubscriptionStatusDto {
  status: SubscriptionStatus | 'NONE';
  planId: PlanId | null;
  planName: string | null;
  billingInterval: BillingInterval | null;
  /** ISO. */
  periodEnd: string | null;
  graceEndsAt: string | null;
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

type SubscriptionRow = Pick<
  ICatalogSubscription,
  | 'status'
  | 'planId'
  | 'planSnapshot'
  | 'billingInterval'
  | 'periodEnd'
  | 'graceEndsAt'
  | 'trialUsedAt'
  | 'threeDDishCap'
  | 'standeeAllocation'
>;

/** The catalog's row, or null when it has none. */
export async function getOrNull(catalogId: Types.ObjectId): Promise<SubscriptionRow | null> {
  return CatalogSubscription.findOne({ catalogId }).lean<SubscriptionRow>().exec();
}

/** `Math.max(0, ceil(ms / day))` — the one formula, in one place. */
function daysUntil(when: Date, now: Date): number {
  return Math.max(0, Math.ceil((when.getTime() - now.getTime()) / DAY_MS));
}

/**
 * Which date the status is counting down to, if any. GRACE counts to the end
 * of grace, not of the period that already ended; PAUSED and CANCELLED count
 * to nothing.
 */
function daysLeftFor(row: SubscriptionRow, now: Date): number | null {
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
    isEntitledTo3D: isEntitledTo3D(row.status),
    trialAvailable,
  };
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
      billingInterval: null,
      periodEnd: null,
      graceEndsAt: null,
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
    billingInterval: row.billingInterval ?? null,
    periodEnd: row.periodEnd.toISOString(),
    graceEndsAt: row.graceEndsAt?.toISOString() ?? null,
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
        $unset: { planId: 1, planSnapshot: 1, billingInterval: 1, graceEndsAt: 1 },
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
