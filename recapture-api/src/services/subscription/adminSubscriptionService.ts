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
import {
  CatalogSubscription,
  isEntitledTo3D,
  type ICatalogSubscription,
} from '@/models/CatalogSubscription';
import { PaymentRecord, type IPaymentRecord } from '@/models/PaymentRecord';
import type { Actor, PlanId, SubscriptionStatus } from '@/models/types/subscription.types';
import { getRazorpayClient, isRazorpayConfigured } from '@/providers/razorpay';
import { enqueueArEntitlementJob } from '@/services/subscription/arEntitlementJobs';
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
  | { outcome: 'PROVIDER_UNAVAILABLE' };

/**
 * The B3 exception, and only that: a full refund of ONE PAID row, at
 * Razorpay, recorded as its own REFUNDED row. The subscription period is
 * never touched — a duplicate did not extend it, so there is nothing to take
 * back. Razorpay itself refuses to refund a payment twice in full, which is
 * the backstop under the ALREADY_REFUNDED check for two admins racing.
 */
export async function refundPayment(
  catalogId: Types.ObjectId,
  admin: Actor,
  input: { refundsPaymentId: string; note: string; override?: boolean },
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
>;

function stateFilter(state: AdminSubscriptionState, now: Date): Record<string, unknown> {
  switch (state) {
    case 'EXPIRING_7D':
      // Anything about to lapse into grace, whatever kind of period it is.
      return {
        status: { $in: ['ACTIVE', 'TRIAL', 'COMPED'] },
        periodEnd: { $gt: now, $lte: new Date(now.getTime() + 7 * DAY_MS) },
      };
    case 'GRACE':
    case 'PAUSED':
    case 'TRIAL':
      return { status: state };
  }
}

/**
 * Who needs chasing. Sorted by `periodEnd` ascending — soonest first — and
 * keyset-paginated on `(periodEnd, _id)` with the shared cursor codec (its
 * `updatedAt` slot carries `periodEnd` here; the client only echoes it).
 */
export async function listSubscriptionsByState(
  state: AdminSubscriptionState,
  cursor: string | undefined,
  limit: number,
  now: Date = new Date()
): Promise<ListSubscriptionsResult> {
  const filter: Record<string, unknown> = { ...stateFilter(state, now) };
  if (cursor) {
    const decoded = decodeCursor(cursor);
    if (!decoded) return { outcome: 'INVALID_CURSOR' };
    filter.$or = [
      { periodEnd: { $gt: decoded.updatedAt } },
      { periodEnd: decoded.updatedAt, _id: { $gt: new Types.ObjectId(decoded.id) } },
    ];
  }

  const rows = await CatalogSubscription.find(filter)
    .sort({ periodEnd: 1, _id: 1 })
    .limit(limit + 1)
    .lean<ListRow[]>()
    .exec();
  const page = rows.slice(0, limit);
  const last = page[page.length - 1];
  const nextCursor =
    rows.length > limit && last ? encodeCursor(last.periodEnd, String(last._id)) : null;

  const catalogs =
    page.length > 0
      ? await Catalog.find({ _id: { $in: page.map((r) => r.catalogId) } })
          .select({ name: 1 })
          .lean<{ _id: Types.ObjectId; name: string }[]>()
          .exec()
      : [];
  const names = new Map(catalogs.map((c) => [String(c._id), toDisplayName(c.name)]));

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
    })),
    nextCursor,
  };
}
