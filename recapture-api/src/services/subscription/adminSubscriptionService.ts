// src/services/subscription/adminSubscriptionService.ts
//
// The admin's money-adjacent actions that are NOT an activation: extending a
// grace period, refunding a duplicate, and the collections list. Comp lives
// with the activation primitive (subscriptionService.applyComp) and manual
// verification in manualPaymentService — this file never calls the
// activation primitive, and the refund never touches the subscription row (AC-5.4).
import { Types } from 'mongoose';

import { env } from '@/config/env';
import { Catalog } from '@/models/Catalog';
import { CatalogProduct } from '@/models/CatalogProduct';
import {
  CatalogSubscription,
  isEntitledTo3D,
  type ICatalogSubscription,
} from '@/models/CatalogSubscription';
import { PaymentRecord, type IPaymentRecord } from '@/models/PaymentRecord';
import type { ProductModelStatus } from '@/models/types/catalog.types';
import type { Actor, PlanId, SubscriptionStatus } from '@/models/types/subscription.types';
import { getRazorpayClient, isRazorpayConfigured } from '@/providers/razorpay';
import { publishableProducts } from '@/services/catalog/publishableProducts';
import { enqueueArEntitlementJob } from '@/services/subscription/arEntitlementJobs';
import {
  desiredPageStateFor,
  enqueuePageStateJob,
} from '@/services/subscription/pageStateJobs';
import { daysLeftFor } from '@/services/subscription/subscriptionService';
import type { AdminSubscriptionState } from '@/validation/subscriptionSchemas';
import { track, AnalyticsEvent } from '@/utils/analytics';
import { toDisplayName } from '@/utils/catalogNames';
import { decodeCursor, encodeCursor } from '@/utils/cursor';
import { hashIdentifier } from '@/utils/otp';
import { consumeRateWindow } from '@/utils/rateLimit';

const DAY_MS = 86_400_000;

/** A refund outside the duplicate flag must be explained at length. */
export const REFUND_OVERRIDE_NOTE_MIN_CHARS = 30;

// ── Extend grace ────────────────────────────────────────────────────────────

export type ExtendGraceResult =
  | { outcome: 'EXTENDED'; graceEndsAt: Date }
  | { outcome: 'NOT_IN_GRACE' };

/**
 * `graceEndsAt += days`, only while the row is GRACE. Guarded on the value
 * read, so two admins extending at once add once each, never once total and
 * never a lost update.
 */
export async function extendGrace(
  catalogId: Types.ObjectId,
  admin: Actor,
  input: { days: number; note: string }
): Promise<ExtendGraceResult> {
  const row = await CatalogSubscription.findOne({ catalogId, status: 'GRACE' })
    .select({ graceEndsAt: 1, periodEnd: 1 })
    .lean<Pick<ICatalogSubscription, 'graceEndsAt' | 'periodEnd'>>()
    .exec();
  if (!row) return { outcome: 'NOT_IN_GRACE' };

  const from = row.graceEndsAt ?? row.periodEnd;
  const graceEndsAt = new Date(from.getTime() + input.days * DAY_MS);
  const updated = await CatalogSubscription.findOneAndUpdate(
    { catalogId, status: 'GRACE', graceEndsAt: row.graceEndsAt ?? null },
    { $set: { graceEndsAt } },
    { new: true }
  ).exec();
  if (!updated) return { outcome: 'NOT_IN_GRACE' };

  track(AnalyticsEvent.SUBSCRIPTION_GRACE_EXTENDED, {
    catalog_id: catalogId.toHexString(),
    admin_id_hash: hashIdentifier(admin.userId.toHexString()),
    days: input.days,
  });
  return { outcome: 'EXTENDED', graceEndsAt };
}

// ── Standees issued ─────────────────────────────────────────────────────────

export type SetStandeesIssuedResult =
  | { outcome: 'SET'; included: number; issued: number }
  /** No row, or `issued` above what the plan includes (a row with no plan includes 0). */
  | { outcome: 'EXCEEDS_INCLUDED'; included: number };

/**
 * `standeeAllocation.issued = n`, guarded on `included >= n` in the same
 * write so a plan change between the read and the write cannot let the
 * count run past the allowance. A HUMAN COUNTER (README C8): what was
 * physically handed over, never derived from QR assignments or activations.
 */
export async function setStandeesIssued(
  catalogId: Types.ObjectId,
  admin: Actor,
  input: { issued: number; note?: string }
): Promise<SetStandeesIssuedResult> {
  const updated = await CatalogSubscription.findOneAndUpdate(
    { catalogId, 'standeeAllocation.included': { $gte: input.issued } },
    { $set: { 'standeeAllocation.issued': input.issued } },
    { new: true }
  )
    .select({ standeeAllocation: 1 })
    .lean<Pick<ICatalogSubscription, 'standeeAllocation'>>()
    .exec();
  if (!updated) {
    const row = await CatalogSubscription.findOne({ catalogId })
      .select({ standeeAllocation: 1 })
      .lean<Pick<ICatalogSubscription, 'standeeAllocation'>>()
      .exec();
    return { outcome: 'EXCEEDS_INCLUDED', included: row?.standeeAllocation?.included ?? 0 };
  }

  track(AnalyticsEvent.SUBSCRIPTION_STANDEES_ISSUED, {
    catalog_id: catalogId.toHexString(),
    admin_id_hash: hashIdentifier(admin.userId.toHexString()),
    issued: updated.standeeAllocation.issued,
    included: updated.standeeAllocation.included,
  });
  return {
    outcome: 'SET',
    included: updated.standeeAllocation.included,
    issued: updated.standeeAllocation.issued,
  };
}

// ── Refund ──────────────────────────────────────────────────────────────────

export type RefundResult =
  | { outcome: 'REFUNDED'; record: IPaymentRecord }
  | { outcome: 'NOT_FOUND' }
  /** Not a PAID row with a provider payment id (a MANUAL or COMP row). */
  | { outcome: 'NOT_REFUNDABLE' }
  /** Not flagged DUPLICATE_SUSPECTED and no adequate override. */
  | { outcome: 'OVERRIDE_REQUIRED' }
  | { outcome: 'ALREADY_REFUNDED' }
  | { outcome: 'RATE_LIMITED'; retryAfter: number }
  | { outcome: 'PROVIDER_UNAVAILABLE' }
  /** `manual: true` against an online payment — that one Razorpay refunds. */
  | { outcome: 'USE_PROVIDER_REFUND' };

export interface RefundRequest {
  refundsPaymentId: string;
  note: string;
  override?: boolean;
  /** E13: record a cash refund already handed back; no provider call. */
  manual?: boolean;
  /** The receipt / UPI txn id of the cash returned. Required with `manual`. */
  reference?: string;
}

/**
 * The B3 exception, and only that: a full refund of ONE PAID row, at
 * Razorpay, recorded as its own REFUNDED row. The subscription period is
 * never touched — a duplicate did not extend it, so there is nothing to take
 * back. Razorpay itself refuses to refund a payment twice in full, which is
 * the backstop under the ALREADY_REFUNDED check for two admins racing.
 *
 * `manual: true` is the E13 twin for a VERIFIED cash row: the admin handed
 * the cash back by hand and this records it — a REFUNDED row with no
 * provider ids, the `reference` of the money returned, and the same
 * override discipline (a note of at least 30 characters), since cash is
 * never flagged DUPLICATE_SUSPECTED by a machine. The backstop for two
 * admins racing is the ledger's unique `idempotencyKey`, keyed on the row
 * being refunded.
 */
export async function refundPayment(
  catalogId: Types.ObjectId,
  admin: Actor,
  input: RefundRequest,
  now: Date = new Date()
): Promise<RefundResult> {
  const rate = await consumeRateWindow(
    `admin-refund:${admin.userId.toHexString()}`,
    env.ADMIN_REFUND_MAX_PER_WINDOW,
    env.ADMIN_REFUND_WINDOW_SECONDS,
    now.getTime()
  );
  if (rate.limited) return { outcome: 'RATE_LIMITED', retryAfter: rate.retryAfter };

  const paid = await PaymentRecord.findOne({
    _id: new Types.ObjectId(input.refundsPaymentId),
    catalogId,
  }).exec();
  if (!paid) return { outcome: 'NOT_FOUND' };

  if (input.manual === true) return refundManualRow(catalogId, admin, paid, input);

  if (paid.kind !== 'PAID' || !paid.providerPaymentId) return { outcome: 'NOT_REFUNDABLE' };

  const override = paid.note !== 'DUPLICATE_SUSPECTED';
  if (override) {
    const explained =
      input.override === true && input.note.length >= REFUND_OVERRIDE_NOTE_MIN_CHARS;
    if (!explained) return { outcome: 'OVERRIDE_REQUIRED' };
  }

  const already = await PaymentRecord.exists({
    kind: 'REFUNDED',
    refundsPaymentId: paid._id,
  }).exec();
  if (already) return { outcome: 'ALREADY_REFUNDED' };

  if (!isRazorpayConfigured()) return { outcome: 'PROVIDER_UNAVAILABLE' };
  let providerRefundId: string;
  try {
    const refund = await getRazorpayClient().createRefund(paid.providerPaymentId, {
      amountPaise: paid.amountPaise,
      notes: { catalogId: catalogId.toHexString(), refundsPaymentId: String(paid._id) },
    });
    providerRefundId = refund.id;
  } catch (err) {
    const message = err instanceof Error ? err.message : 'unknown error';
    console.warn(`[refund] Razorpay refund failed (${message})`);
    return { outcome: 'PROVIDER_UNAVAILABLE' };
  }

  const record = await PaymentRecord.create({
    catalogId,
    userId: paid.userId,
    ...(paid.subscriptionId ? { subscriptionId: paid.subscriptionId } : {}),
    kind: 'REFUNDED',
    amountPaise: paid.amountPaise,
    currency: paid.currency,
    providerPaymentId: paid.providerPaymentId,
    providerRefundId,
    idempotencyKey: `refund:${providerRefundId}`,
    refundsPaymentId: paid._id,
    initiatedBy: admin,
    note: input.note,
  });

  track(AnalyticsEvent.SUBSCRIPTION_REFUND_ISSUED, {
    catalog_id: catalogId.toHexString(),
    admin_id_hash: hashIdentifier(admin.userId.toHexString()),
    amount_paise: paid.amountPaise,
    override,
    manual: false,
  });
  return { outcome: 'REFUNDED', record };
}

/** Mongo's duplicate-key error — the unique `idempotencyKey` index firing. */
function isDuplicateKey(err: unknown): boolean {
  return typeof err === 'object' && err !== null && (err as { code?: unknown }).code === 11000;
}

/**
 * The manual half of `refundPayment` (E13). The row must be a VERIFIED cash
 * entry — a PENDING one never took a period and a REJECTED one never took
 * money, so there is nothing to give back; an online row is refused outright
 * (USE_PROVIDER_REFUND) so cash bookkeeping can never shadow a Razorpay
 * refund. Always an override: nothing flags a cash row automatically.
 */
async function refundManualRow(
  catalogId: Types.ObjectId,
  admin: Actor,
  paid: IPaymentRecord,
  input: RefundRequest
): Promise<RefundResult> {
  if (paid.kind === 'PAID') return { outcome: 'USE_PROVIDER_REFUND' };
  if (paid.kind !== 'MANUAL' || paid.verificationStatus !== 'VERIFIED') {
    return { outcome: 'NOT_REFUNDABLE' };
  }
  const explained =
    input.override === true &&
    input.note.length >= REFUND_OVERRIDE_NOTE_MIN_CHARS &&
    typeof input.reference === 'string' &&
    input.reference.length > 0;
  if (!explained) return { outcome: 'OVERRIDE_REQUIRED' };

  const already = await PaymentRecord.exists({
    kind: 'REFUNDED',
    refundsPaymentId: paid._id,
  }).exec();
  if (already) return { outcome: 'ALREADY_REFUNDED' };

  let record: IPaymentRecord;
  try {
    record = await PaymentRecord.create({
      catalogId,
      userId: paid.userId,
      ...(paid.subscriptionId ? { subscriptionId: paid.subscriptionId } : {}),
      kind: 'REFUNDED',
      amountPaise: paid.amountPaise,
      currency: paid.currency,
      // No provider ids: the money went back by hand. The key is the row
      // being reversed, so a second admin's insert lands on the index.
      idempotencyKey: `refund:manual:${String(paid._id)}`,
      refundsPaymentId: paid._id,
      initiatedBy: admin,
      reference: input.reference,
      note: input.note,
    });
  } catch (err) {
    if (isDuplicateKey(err)) return { outcome: 'ALREADY_REFUNDED' };
    throw err;
  }

  track(AnalyticsEvent.SUBSCRIPTION_REFUND_ISSUED, {
    catalog_id: catalogId.toHexString(),
    admin_id_hash: hashIdentifier(admin.userId.toHexString()),
    amount_paise: paid.amountPaise,
    override: true,
    manual: true,
  });
  return { outcome: 'REFUNDED', record };
}

// ── Resync the Mirage entitlement ───────────────────────────────────────────

export type ResyncArResult =
  | { outcome: 'ENQUEUED'; jobId: Types.ObjectId; enabled: boolean }
  /** No subscription row — there is no desired state to sync. */
  | { outcome: 'NO_SUBSCRIPTION' };

/**
 * E18. Enqueues a SUBSCRIPTION_AR_ENTITLEMENT job carrying the row's CURRENT
 * desired state — the button an admin presses when `arEntitlementSyncedAt`
 * is stale or an ENTITLEMENT_FAILED alert arrived. Keyed on "now" rather
 * than the row's `updatedAt`, so pressing it again after a failed attempt
 * queues a fresh job instead of landing on the failed one.
 */
export async function resyncArEntitlement(
  catalogId: Types.ObjectId,
  admin: Actor,
  now: Date = new Date()
): Promise<ResyncArResult> {
  const row = await CatalogSubscription.findOne({ catalogId })
    .select({ status: 1, userId: 1 })
    .lean<{ status: SubscriptionStatus; userId: Types.ObjectId }>()
    .exec();
  if (!row) return { outcome: 'NO_SUBSCRIPTION' };

  const enabled = isEntitledTo3D(row.status);
  const { jobId } = await enqueueArEntitlementJob({
    catalogId,
    ownerUserId: row.userId,
    enabled,
    reason: 'ADMIN',
    dedupeAt: now,
  });
  console.log(
    `[subscription] admin ${hashIdentifier(admin.userId.toHexString())} resync-ar ` +
      `catalog=${catalogId.toHexString()} enabled=${enabled} job=${jobId.toHexString()}`
  );
  return { outcome: 'ENQUEUED', jobId, enabled };
}

// ── Resync the Mirage page state ────────────────────────────────────────────

export type ResyncPageStateResult =
  | { outcome: 'ENQUEUED'; jobId: Types.ObjectId; isPublished: boolean }
  /** No subscription row — there is no desired state to sync. */
  | { outcome: 'NO_SUBSCRIPTION' };

/**
 * The sibling of {@link resyncArEntitlement}, for the field that decides whether
 * the CUSTOMER PAGE is live at all — the button the "A paid restaurant's page is
 * still switched off" alert names.
 *
 * It sends the row's CURRENT desired state, computed by the same function the
 * processor uses (`desiredPageStateFor`), so an admin pressing this can never
 * invent a state: it can only re-assert what the row already says. In
 * particular, a restaurant that merely lapsed resolves to `isPublished: true`,
 * so this button cannot be used to take a paid page down.
 *
 * Keyed on "now" rather than the row's `updatedAt`, so pressing it again after a
 * failed attempt queues a fresh job instead of landing on the failed one.
 */
export async function resyncPageState(
  catalogId: Types.ObjectId,
  admin: Actor,
  now: Date = new Date()
): Promise<ResyncPageStateResult> {
  const row = await CatalogSubscription.findOne({ catalogId })
    .select({ status: 1, userId: 1, periodEnd: 1, pageDeactivatedAt: 1 })
    .lean<{
      status: SubscriptionStatus;
      userId: Types.ObjectId;
      periodEnd: Date;
      pageDeactivatedAt?: Date;
    }>()
    .exec();
  if (!row) return { outcome: 'NO_SUBSCRIPTION' };

  const desired = desiredPageStateFor(row);
  const { jobId } = await enqueuePageStateJob({
    catalogId,
    ownerUserId: row.userId,
    isPublished: desired.isPublished,
    paymentDueAt: desired.paymentDueAt,
    reason: 'ADMIN',
    dedupeAt: now,
  });
  console.log(
    `[subscription] admin ${hashIdentifier(admin.userId.toHexString())} resync-page ` +
      `catalog=${catalogId.toHexString()} isPublished=${desired.isPublished} ` +
      `job=${jobId.toHexString()}`
  );
  return { outcome: 'ENQUEUED', jobId, isPublished: desired.isPublished };
}

// ── The collections list ────────────────────────────────────────────────────

export interface AdminSubscriptionListItem {
  catalogId: string;
  catalogName: string;
  status: SubscriptionStatus;
  /** ISO. */
  periodEnd: string;
  graceEndsAt: string | null;
  daysLeft: number | null;
  planId: PlanId | null;
  /**
   * E46: the share (0–100, whole percent) of the catalog's live dishes that
   * have a card image — a photo, or a 3D dish's generated thumbnail — and so
   * still render something while 3D is off. Null when the menu has no live
   * dish. Below 100 on a PAUSED row means some cards are placeholders now.
   */
  photoCoverage: number | null;
}

export type ListSubscriptionsResult =
  | { outcome: 'OK'; items: AdminSubscriptionListItem[]; nextCursor: string | null }
  | { outcome: 'INVALID_CURSOR' };

type ListRow = Pick<
  ICatalogSubscription,
  | '_id'
  | 'catalogId'
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
  | 'pausedAt'
>;

/** How long a PAUSED row has to sit before it is a `PAUSED_90D` follow-up. */
export const PAUSED_FOLLOW_UP_DAYS = 90;

function stateFilter(state: AdminSubscriptionState, now: Date): Record<string, unknown> {
  switch (state) {
    case 'EXPIRING_7D':
      // Anything about to lapse into grace, whatever kind of period it is.
      return {
        status: { $in: ['ACTIVE', 'TRIAL', 'COMPED'] },
        periodEnd: { $gt: now, $lte: new Date(now.getTime() + 7 * DAY_MS) },
      };
    case 'PAUSED_90D':
      // E23: the long-quiet, oldest pause first. `$lte` on the day boundary,
      // so a row paused exactly 90 days ago is in and 89 days is out.
      return {
        status: 'PAUSED',
        pausedAt: { $lte: new Date(now.getTime() - PAUSED_FOLLOW_UP_DAYS * DAY_MS) },
      };
    case 'GRACE':
    case 'PAUSED':
    case 'TRIAL':
      return { status: state };
  }
}

/** The date each segment is ordered on: when the pause began, or the period's end. */
function sortKeyFor(state: AdminSubscriptionState): 'pausedAt' | 'periodEnd' {
  return state === 'PAUSED_90D' ? 'pausedAt' : 'periodEnd';
}

/**
 * Who needs chasing. Sorted by `periodEnd` ascending — soonest first — and
 * keyset-paginated on `(periodEnd, _id)` with the shared cursor codec (its
 * `updatedAt` slot carries `periodEnd` here; the client only echoes it).
 * `PAUSED_90D` sorts and paginates on `pausedAt` instead — the oldest pause
 * is the one most overdue for a call.
 */
export async function listSubscriptionsByState(
  state: AdminSubscriptionState,
  cursor: string | undefined,
  limit: number,
  now: Date = new Date()
): Promise<ListSubscriptionsResult> {
  const sortKey = sortKeyFor(state);
  const filter: Record<string, unknown> = { ...stateFilter(state, now) };
  if (cursor) {
    const decoded = decodeCursor(cursor);
    if (!decoded) return { outcome: 'INVALID_CURSOR' };
    filter.$or = [
      { [sortKey]: { $gt: decoded.updatedAt } },
      { [sortKey]: decoded.updatedAt, _id: { $gt: new Types.ObjectId(decoded.id) } },
    ];
  }

  const rows = await CatalogSubscription.find(filter)
    .sort({ [sortKey]: 1, _id: 1 })
    .limit(limit + 1)
    .lean<ListRow[]>()
    .exec();
  const page = rows.slice(0, limit);
  const last = page[page.length - 1];
  const lastSortValue = last ? (last[sortKey] ?? last.periodEnd) : null;
  const nextCursor =
    rows.length > limit && last && lastSortValue
      ? encodeCursor(lastSortValue, String(last._id))
      : null;

  const catalogs =
    page.length > 0
      ? await Catalog.find({ _id: { $in: page.map((r) => r.catalogId) } })
          .select({ name: 1 })
          .lean<{ _id: Types.ObjectId; name: string }[]>()
          .exec()
      : [];
  const names = new Map(catalogs.map((c) => [String(c._id), toDisplayName(c.name)]));
  const coverage = await photoCoverageFor(page.map((r) => r.catalogId));

  return {
    outcome: 'OK',
    items: page.map((row) => ({
      catalogId: String(row.catalogId),
      catalogName: names.get(String(row.catalogId)) ?? '',
      status: row.status,
      periodEnd: row.periodEnd.toISOString(),
      graceEndsAt: row.graceEndsAt?.toISOString() ?? null,
      daysLeft: daysLeftFor(row, now),
      planId: row.planId ?? null,
      photoCoverage: coverage.get(String(row.catalogId)) ?? null,
    })),
    nextCursor,
  };
}

type CoverageRow = {
  catalogId: Types.ObjectId;
  deletedAt?: Date | null;
  archivedAt?: Date | null;
  modelStatus?: ProductModelStatus;
  assets?: { glbUrl?: string; thumbnailUrl?: string; imageKey?: string };
};

/**
 * Per catalog: what percentage of its LIVE dishes (the same list a publish
 * sends, via `publishableProducts`) carry a card image. A 3D dish's image is
 * its generated thumbnail (productSync: the image slot), which the publish
 * gate requires — so a menu that passed the gates reads 100 and the number
 * only drops for legacy rows that were never re-published. Null for a menu
 * with no live dish: 0 of 0 is not "no photos".
 */
async function photoCoverageFor(
  catalogIds: readonly Types.ObjectId[]
): Promise<Map<string, number | null>> {
  const out = new Map<string, number | null>();
  if (catalogIds.length === 0) return out;
  const rows = await CatalogProduct.find({
    catalogId: { $in: catalogIds },
    deletedAt: null,
    archivedAt: null,
  })
    .select({
      catalogId: 1,
      deletedAt: 1,
      archivedAt: 1,
      modelStatus: 1,
      'assets.glbUrl': 1,
      'assets.thumbnailUrl': 1,
      'assets.imageKey': 1,
    })
    .lean<CoverageRow[]>()
    .exec();

  const totals = new Map<string, { live: number; withImage: number }>();
  for (const product of publishableProducts(rows)) {
    const key = String(product.catalogId);
    const tally = totals.get(key) ?? { live: 0, withImage: 0 };
    tally.live += 1;
    if (product.assets?.imageKey || product.assets?.thumbnailUrl) tally.withImage += 1;
    totals.set(key, tally);
  }
  for (const id of catalogIds) {
    const tally = totals.get(String(id));
    out.set(
      String(id),
      tally && tally.live > 0 ? Math.floor((tally.withImage / tally.live) * 100) : null
    );
  }
  return out;
}
