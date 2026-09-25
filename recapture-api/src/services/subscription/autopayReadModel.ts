// src/services/subscription/autopayReadModel.ts
//
// The READ side of autopay: what the Subscription screen shows about a
// catalog's mandate, and which catalogs the lifecycle sweep must not lapse
// while a renewal charge is in flight.
//
// Separate from autopayService.ts on purpose. That file talks to Razorpay and
// records money (it imports the webhook service); this one only reads
// `AutopayMandate`, so subscriptionService and the sweep can use it without
// pulling the payment machinery — and its import cycles — into every read.
import type { Types } from 'mongoose';

import { AutopayMandate } from '@/models/AutopayMandate';
import {
  LIVE_AUTOPAY_STATUSES,
  type AutopayStatus,
  type BillingInterval,
  type PlanId,
} from '@/models/types/subscription.types';

/**
 * The owner-facing picture of autopay, on `GET /catalog/subscription`.
 * Null when autopay is simply off (never set up, turned off, or expired
 * unauthorised) — there is nothing to say.
 */
export interface AutopaySummaryDto {
  /**
   * AUTHENTICATED / ACTIVE — on and healthy. PENDING — the last renewal failed
   * and Razorpay is retrying. HALTED — Razorpay gave up; the owner must turn
   * it on again. (CANCELLED / COMPLETED / EXPIRED are reported as null.)
   */
  status: AutopayStatus;
  planId: PlanId;
  planName: string;
  interval: BillingInterval;
  /** What each charge takes. Integer paise. */
  amountPaise: number;
  /** ISO — Razorpay's next charge time. Null when none is scheduled (HALTED). */
  nextChargeAt: string | null;
}

interface MandateRow {
  status: AutopayStatus;
  quote: { planId: PlanId; interval: BillingInterval; totalPaise: number; planSnapshot: { displayName: string } };
  chargeAt: Date | null;
  startAt: Date | null;
}

function toSummary(row: MandateRow): AutopaySummaryDto {
  const next = row.status === 'HALTED' ? null : (row.chargeAt ?? row.startAt);
  return {
    status: row.status,
    planId: row.quote.planId,
    planName: row.quote.planSnapshot.displayName,
    interval: row.quote.interval,
    amountPaise: row.quote.totalPaise,
    nextChargeAt: next ? next.toISOString() : null,
  };
}

/**
 * The live mandate if there is one; else a HALTED one that is the catalog's
 * most recent (the owner needs to hear that autopay stopped); else null.
 */
export async function getAutopaySummary(
  catalogId: Types.ObjectId
): Promise<AutopaySummaryDto | null> {
  const [live, latest] = await Promise.all([
    AutopayMandate.findOne({ catalogId, status: { $in: [...LIVE_AUTOPAY_STATUSES] } })
      .sort({ createdAt: -1 })
      .select({ status: 1, quote: 1, chargeAt: 1, startAt: 1 })
      .lean<MandateRow>()
      .exec(),
    AutopayMandate.findOne({ catalogId, status: { $ne: 'CREATED' } })
      .sort({ createdAt: -1 })
      .select({ status: 1, quote: 1, chargeAt: 1, startAt: 1 })
      .lean<MandateRow>()
      .exec(),
  ]);
  if (live) return toSummary(live);
  if (latest?.status === 'HALTED') return toSummary(latest);
  return null;
}

/**
 * Of `catalogIds`, the ones whose autopay is ON AND HEALTHY — authorised, or
 * charging on schedule. A catalog in this set is about to be charged by
 * Razorpay at its period end, so the sweep holds it out of GRACE for
 * `AUTOPAY_RENEWAL_WAIT_HOURS` and its reminders say "renews automatically"
 * instead of "renew". A PENDING mandate (a renewal already failed) is NOT
 * healthy: that owner has something to fix, and gets the ordinary warnings.
 */
export async function catalogsWithHealthyAutopay(
  catalogIds: readonly Types.ObjectId[]
): Promise<Set<string>> {
  if (catalogIds.length === 0) return new Set();
  const ids = await AutopayMandate.distinct('catalogId', {
    catalogId: { $in: [...catalogIds] },
    status: { $in: ['AUTHENTICATED', 'ACTIVE'] },
  }).exec();
  return new Set(ids.map((id) => String(id)));
}
