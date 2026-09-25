// src/services/subscription/autopayService.ts
//
// AUTOPAY: the owner's plan renews by itself — monthly or yearly — through a
// Razorpay SUBSCRIPTION (a mandate on their UPI / card / bank), instead of a
// one-time order they must remember to pay again.
//
//   start   POST /catalog/subscription/autopay     → a CREATED mandate + the
//           ids the checkout sheet needs. Nothing is charged yet.
//   verify  POST …/autopay/verify                  → the sheet's signed
//           success response; checked, then a SYNC.
//   sync    webhook `subscription.*`, the verify, the reconciler, the owner's
//           own read, an admin — all the same `syncMandate`: ask Razorpay for
//           the subscription and its paid invoices, mirror the state, and
//           record every paid invoice as a PAID row through
//           `webhookService.recordAutopayCharge` (idempotent on the payment).
//   off     POST …/autopay/cancel                  → cancelled at Razorpay now.
//
// THE RULES THIS FILE KEEPS
//   • Money is recorded ONLY as paid invoices, never from a status. A mandate
//     going ACTIVE is not a payment; an invoice with a payment id is.
//   • The catalog's period belongs to the catalog. Turning autopay off (or a
//     mandate halting) never shortens a period already paid for — it only
//     stops the next charge. That is why "off" can cancel at Razorpay at once.
//   • One live mandate per catalog. The moment a new one is live, every other
//     live or halted one is cancelled at Razorpay (a plan change must never
//     leave two mandates charging the same restaurant).
//   • No double charge on switching to autopay. An owner already inside a paid
//     period of the SAME plan and interval gets a mandate whose first charge is
//     DEFERRED to that period's end (`start_at`). Any other case charges now,
//     exactly like a one-time payment would (the early-renewal forfeit, A2,
//     reported as `daysForfeited`).
//   • PII: notes carry ids and enums only (§7 rule 8), as on orders.
import { Types } from 'mongoose';

import { env } from '@/config/env';
import { AutopayMandate, type IAutopayMandate } from '@/models/AutopayMandate';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { PaymentRecord, type PaymentQuote } from '@/models/PaymentRecord';
import { RazorpayPlan, razorpayPlanKey } from '@/models/RazorpayPlan';
import {
  LIVE_AUTOPAY_STATUSES,
  type Actor,
  type AutopayStatus,
  type BillingInterval,
  type PlanId,
  type SubscriptionStatus,
} from '@/models/types/subscription.types';
import {
  getRazorpayClient,
  isRazorpayConfigured,
  verifySubscriptionSignature,
  type RazorpayInvoiceSnapshot,
  type RazorpaySubscriptionSnapshot,
} from '@/providers/razorpay';
import { quoteFor } from '@/services/subscription/checkoutService';
import {
  notifyAutopayChargeFailed,
  notifyAutopayOn,
  notifyAutopayStopped,
  notifyAutopayTurnedOff,
} from '@/services/subscription/ownerNotifications';
import { getPlanCatalog } from '@/services/subscription/planCatalogService';
import { daysForfeitedFor } from '@/services/subscription/subscriptionService';
import {
  recordAutopayCharge,
  type OnlinePaymentOutcome,
} from '@/services/subscription/webhookService';
import { track, AnalyticsEvent } from '@/utils/analytics';
import { consumeRateWindow } from '@/utils/rateLimit';

const MINUTE_MS = 60_000;
const HOUR_MS = 3_600_000;

/** New mandates per catalog per hour — reusing an open one does not count. */
const AUTOPAY_MAX_NEW_PER_HOUR = 10;

/**
 * A deferred first charge must be at least this far away, or it is simply
 * charged now: Razorpay needs `start_at` in the future, and a period ending in
 * a few minutes is not worth a mandate that charges a few minutes later.
 */
const MIN_DEFER_MS = 30 * MINUTE_MS;

type SyncVia = 'CLIENT' | 'WEBHOOK' | 'RECONCILE' | 'ADMIN';

// ── Status mapping ──────────────────────────────────────────────────────────

const RAZORPAY_TO_STATUS: Record<string, AutopayStatus> = {
  created: 'CREATED',
  authenticated: 'AUTHENTICATED',
  active: 'ACTIVE',
  pending: 'PENDING',
  halted: 'HALTED',
  cancelled: 'CANCELLED',
  completed: 'COMPLETED',
  expired: 'EXPIRED',
};

/** Razorpay's status, upper-cased. An unknown one keeps what we had — never guessed. */
function mapStatus(raw: string, fallback: AutopayStatus): AutopayStatus {
  return RAZORPAY_TO_STATUS[raw.toLowerCase()] ?? fallback;
}

const isLive = (s: AutopayStatus): boolean => LIVE_AUTOPAY_STATUSES.includes(s);
const fromUnix = (secs: number | null): Date | null => (secs ? new Date(secs * 1000) : null);

function trackChange(
  mandate: Pick<IAutopayMandate, 'catalogId' | 'quote'>,
  from: AutopayStatus | 'NONE',
  to: AutopayStatus,
  via: SyncVia | 'OWNER'
): void {
  track(AnalyticsEvent.SUBSCRIPTION_AUTOPAY_CHANGED, {
    catalog_id: mandate.catalogId.toHexString(),
    plan_id: mandate.quote.planId,
    interval: mandate.quote.interval,
    from,
    to,
    via,
  });
}

function isDuplicateKey(err: unknown): boolean {
  return typeof err === 'object' && err !== null && (err as { code?: unknown }).code === 11000;
}

// ── Razorpay plans ──────────────────────────────────────────────────────────

/** The Razorpay plan for this price, minted once and remembered (see RazorpayPlan). */
async function ensureRazorpayPlan(quote: PaymentQuote): Promise<string> {
  const key = razorpayPlanKey(quote.planId, quote.interval, quote.totalPaise);
  const known = await RazorpayPlan.findOne({ key }).lean().exec();
  if (known) return known.providerPlanId;

  const created = await getRazorpayClient().createPlan({
    period: quote.interval === 'YEARLY' ? 'yearly' : 'monthly',
    amountPaise: quote.totalPaise,
    name: `${quote.planSnapshot.displayName} · ${quote.interval === 'YEARLY' ? 'yearly' : 'monthly'}`,
    notes: { planId: quote.planId, interval: quote.interval },
  });
  try {
    await RazorpayPlan.create({
      key,
      planId: quote.planId,
      interval: quote.interval,
      amountPaise: quote.totalPaise,
      providerPlanId: created.id,
    });
    return created.id;
  } catch (err) {
    if (!isDuplicateKey(err)) throw err;
    // Two first-ever autopays at this price at once: one Razorpay plan is spare
    // (harmless, never used); everyone uses the one that won the insert.
    const winner = await RazorpayPlan.findOne({ key }).lean().exec();
    if (!winner) throw err;
    return winner.providerPlanId;
  }
}

// ── Start ───────────────────────────────────────────────────────────────────

/** What the client needs to open the checkout sheet on a mandate — and nothing it could misuse. */
export interface AutopayCheckoutDto {
  providerSubscriptionId: string;
  /** The public half of the key pair; the SDK needs it. Never the secret. */
  keyId: string;
  quote: PaymentQuote;
  /** Each charge. Integer paise. */
  amountPaise: number;
  /**
   * ISO — when the FIRST charge happens, when it is not at checkout (the owner
   * is inside a paid period of this plan). Null = charged when they approve.
   */
  firstChargeAt: string | null;
  /** ISO — when this mandate stops being approvable and a new one is minted. */
  expiresAt: string;
  /** ISO, or null when the catalog has no period running. */
  currentPeriodEnd: string | null;
  /** Days of the current period a charge NOW would forfeit (E9). 0 when deferred. */
  daysForfeited: number;
}

export type StartAutopayResult =
  | { outcome: 'OK'; reused: boolean; autopay: AutopayCheckoutDto }
  /** Autopay is already on, healthy, for exactly this plan and interval. */
  | { outcome: 'ALREADY_ON' }
  | { outcome: 'UNAVAILABLE' }
  | { outcome: 'RATE_LIMITED'; retryAfter: number };

type CurrentRow = {
  _id: Types.ObjectId;
  status: SubscriptionStatus;
  planId?: PlanId;
  billingInterval?: BillingInterval;
  periodEnd: Date;
};

function toCheckoutDto(
  mandate: Pick<IAutopayMandate, 'providerSubscriptionId' | 'quote' | 'startAt' | 'expiresAt'>,
  current: CurrentRow | null,
  now: Date
): AutopayCheckoutDto {
  return {
    providerSubscriptionId: mandate.providerSubscriptionId,
    keyId: env.RAZORPAY_KEY_ID!,
    quote: mandate.quote,
    amountPaise: mandate.quote.totalPaise,
    firstChargeAt: mandate.startAt ? mandate.startAt.toISOString() : null,
    expiresAt: mandate.expiresAt.toISOString(),
    currentPeriodEnd: current ? current.periodEnd.toISOString() : null,
    daysForfeited: mandate.startAt ? 0 : daysForfeitedFor(current, now),
  };
}

/**
 * When the first charge should be — null for "at checkout". Deferred only
 * when the owner is inside a paid ACTIVE period of this very plan and
 * interval: switching THAT to autopay must not charge them twice for the
 * same days. A different plan is a plan change and starts now (A2).
 */
function deferredStartFor(
  current: CurrentRow | null,
  quote: PaymentQuote,
  now: Date
): Date | null {
  if (!current || current.status !== 'ACTIVE') return null;
  if (current.planId !== quote.planId || current.billingInterval !== quote.interval) return null;
  if (current.periodEnd.getTime() - now.getTime() < MIN_DEFER_MS) return null;
  return current.periodEnd;
}

export async function startAutopay(
  catalogId: Types.ObjectId,
  ownerUserId: Types.ObjectId,
  actor: Actor,
  input: { planId: PlanId; interval: BillingInterval },
  now: Date = new Date()
): Promise<StartAutopayResult> {
  if (!isRazorpayConfigured()) return { outcome: 'UNAVAILABLE' };

  const [current, plans, live] = await Promise.all([
    CatalogSubscription.findOne({ catalogId })
      .select({ _id: 1, status: 1, planId: 1, billingInterval: 1, periodEnd: 1 })
      .lean<CurrentRow>()
      .exec(),
    getPlanCatalog(),
    AutopayMandate.findOne({ catalogId, status: { $in: ['AUTHENTICATED', 'ACTIVE'] } })
      .sort({ createdAt: -1 })
      .lean<IAutopayMandate>()
      .exec(),
  ]);
  const quote = quoteFor(plans, input.planId, input.interval);

  // Nothing to do: a healthy mandate already charges exactly this. (A PENDING
  // one — a renewal failing — is NOT this case: a fresh mandate on a working
  // payment method is how the owner fixes it.)
  if (
    live &&
    live.quote.planId === quote.planId &&
    live.quote.interval === quote.interval &&
    live.quote.totalPaise === quote.totalPaise
  ) {
    return { outcome: 'ALREADY_ON' };
  }

  const startAt = deferredStartFor(current, quote, now);

  // Reuse an open, unapproved mandate for the same thing — a double tap, a
  // closed sheet re-opened — so one intent is one Razorpay subscription.
  const open = await AutopayMandate.findOne({
    catalogId,
    status: 'CREATED',
    expiresAt: { $gt: now },
    'quote.planId': quote.planId,
    'quote.interval': quote.interval,
    'quote.totalPaise': quote.totalPaise,
    startAt: startAt ?? null,
  })
    .sort({ createdAt: -1 })
    .lean<IAutopayMandate>()
    .exec();
  if (open) return { outcome: 'OK', reused: true, autopay: toCheckoutDto(open, current, now) };

  const rate = await consumeRateWindow(
    `autopay:${catalogId.toHexString()}`,
    AUTOPAY_MAX_NEW_PER_HOUR,
    3600,
    now.getTime()
  );
  if (rate.limited) return { outcome: 'RATE_LIMITED', retryAfter: rate.retryAfter };

  const expiresAt = new Date(now.getTime() + plans.orderTtlHours * HOUR_MS);
  let snapshot: RazorpaySubscriptionSnapshot;
  let providerPlanId: string;
  try {
    providerPlanId = await ensureRazorpayPlan(quote);
    snapshot = await getRazorpayClient().createSubscription({
      planId: providerPlanId,
      totalCount:
        quote.interval === 'YEARLY'
          ? env.AUTOPAY_TOTAL_CYCLES_YEARLY
          : env.AUTOPAY_TOTAL_CYCLES_MONTHLY,
      ...(startAt ? { startAt: Math.floor(startAt.getTime() / 1000) } : {}),
      expireBy: Math.floor(expiresAt.getTime() / 1000),
      notes: {
        catalogId: catalogId.toHexString(),
        planId: quote.planId,
        interval: quote.interval,
        kind: 'AUTOPAY',
      },
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : 'unknown error';
    console.warn(`[autopay] Razorpay subscription create failed (${message})`);
    return { outcome: 'UNAVAILABLE' };
  }

  const mandate = await AutopayMandate.create({
    catalogId,
    userId: ownerUserId,
    providerSubscriptionId: snapshot.id,
    providerPlanId,
    quote,
    status: 'CREATED',
    startAt,
    expiresAt,
    initiatedBy: actor,
  });
  trackChange(mandate, 'NONE', 'CREATED', 'OWNER');
  return { outcome: 'OK', reused: false, autopay: toCheckoutDto(mandate, current, now) };
}

// ── Sync ────────────────────────────────────────────────────────────────────

export type SyncMandateResult =
  | {
      kind: 'SYNCED';
      status: AutopayStatus;
      /** Paid invoices THIS call recorded (0 when they were already on the ledger). */
      recordedCharges: number;
      /** The apply outcome of each charge this call looked at, oldest first. */
      outcomes: OnlinePaymentOutcome[];
    }
  | { kind: 'UNKNOWN' }
  | { kind: 'UNAVAILABLE' };

/**
 * Brings one mandate in line with Razorpay and records every paid invoice.
 * Safe to call any number of times from anywhere: the state write is a plain
 * mirror, each charge converges on its `payment:<id>` row, and every owner
 * message is keyed so a repeat is a no-op.
 */
export async function syncMandate(
  providerSubscriptionId: string,
  via: SyncVia,
  now: Date = new Date()
): Promise<SyncMandateResult> {
  const mandate = await AutopayMandate.findOne({ providerSubscriptionId }).exec();
  if (!mandate) return { kind: 'UNKNOWN' };
  if (!isRazorpayConfigured()) return { kind: 'UNAVAILABLE' };

  const client = getRazorpayClient();
  let snap: RazorpaySubscriptionSnapshot;
  try {
    snap = await client.fetchSubscription(providerSubscriptionId);
  } catch (err) {
    console.error(`[autopay] fetch failed for ${providerSubscriptionId}`, err);
    return { kind: 'UNAVAILABLE' };
  }

  const from = mandate.status;
  const to = mapStatus(snap.status, from);

  // ── Money first: every paid invoice, oldest first, so a catch-up after an
  // outage applies cycles in the order they were bought.
  const outcomes: OnlinePaymentOutcome[] = [];
  let recordedCharges = 0;
  if (snap.paidCount > 0 || !['CREATED', 'AUTHENTICATED', 'EXPIRED'].includes(to)) {
    let invoices: RazorpayInvoiceSnapshot[] = [];
    try {
      invoices = await client.fetchSubscriptionInvoices(providerSubscriptionId);
    } catch (err) {
      // The state below is still worth mirroring; the charges are picked up by
      // the next sync (the reconciler keeps asking while a charge is due).
      console.error(`[autopay] invoices fetch failed for ${providerSubscriptionId}`, err);
    }
    const paid = invoices
      .filter((i) => i.status === 'paid' && i.paymentId)
      .sort((a, b) => (a.billingStart ?? a.paidAt ?? 0) - (b.billingStart ?? b.paidAt ?? 0));
    if (paid.length > 0) {
      const onLedger = new Set(
        (
          await PaymentRecord.distinct('providerPaymentId', {
            kind: 'PAID',
            providerPaymentId: { $in: paid.map((i) => i.paymentId!) },
          }).exec()
        ).map(String)
      );
      for (const invoice of paid) {
        if (onLedger.has(invoice.paymentId!)) continue;
        const result = await recordAutopayCharge({
          catalogId: mandate.catalogId,
          ownerUserId: mandate.userId,
          quote: mandate.quote,
          providerSubscriptionId,
          providerInvoiceId: invoice.id,
          orderId: invoice.orderId,
          paymentId: invoice.paymentId!,
          amountPaise: invoice.amountPaid,
          billingPeriodEnd: fromUnix(invoice.billingEnd),
          via,
          now,
        });
        outcomes.push(result.outcome);
        if (result.recorded) recordedCharges += 1;
      }
    }
  }

  // ── Then the mirror. Conditional on the status we read, so two syncs racing
  // on one transition fire its side effects once.
  const mirror = {
    status: to,
    currentStart: fromUnix(snap.currentStart),
    currentEnd: fromUnix(snap.currentEnd),
    chargeAt: fromUnix(snap.chargeAt),
    paidCount: snap.paidCount,
    lastSyncedAt: now,
    ...(!isLive(to) && to !== 'CREATED' && !mandate.endedAt
      ? { endedAt: fromUnix(snap.endedAt) ?? now }
      : {}),
  };
  const moved = await AutopayMandate.findOneAndUpdate(
    { _id: mandate._id, status: from },
    { $set: mirror },
    { new: true }
  ).exec();

  if (moved && from !== to) {
    trackChange(mandate, from, to, via);
    await onTransition(moved, from, to, now);
  }
  return { kind: 'SYNCED', status: to, recordedCharges, outcomes };
}

/** What a state change means for the owner and for the catalog's other mandates. */
async function onTransition(
  mandate: IAutopayMandate,
  from: AutopayStatus,
  to: AutopayStatus,
  now: Date
): Promise<void> {
  const notice = {
    catalogId: mandate.catalogId,
    ownerUserId: mandate.userId,
    providerSubscriptionId: mandate.providerSubscriptionId,
    plan: mandate.quote.planSnapshot,
    interval: mandate.quote.interval,
    amountPaise: mandate.quote.totalPaise,
  };

  if (isLive(to) && !isLive(from)) {
    await supersedeOthers(mandate, now);
    // A mandate charged at checkout announces itself through "payment
    // received"; only a deferred one needs its own "autopay is on".
    if (to === 'AUTHENTICATED' && mandate.startAt) {
      await notifyAutopayOn({ ...notice, firstChargeAt: mandate.startAt });
    }
  }
  if (to === 'PENDING' && from !== 'PENDING') {
    await notifyAutopayChargeFailed({ ...notice, chargeAt: mandate.chargeAt });
  }
  if (to === 'HALTED') await notifyAutopayStopped({ ...notice, reason: 'HALTED' });
  if (to === 'COMPLETED') await notifyAutopayStopped({ ...notice, reason: 'COMPLETED' });
  // Cancelled and WE did not do it: the payer stopped it from their bank or
  // UPI app. Ours carry an `endReason` and have their own message (or none).
  if (to === 'CANCELLED' && !mandate.endReason && isLive(from)) {
    await notifyAutopayStopped({ ...notice, reason: 'CANCELLED_EXTERNALLY' });
  }
}

/**
 * The catalog's OTHER mandates that could still charge — live or halted —
 * cancelled at Razorpay now. A failure is logged and left: the reconciler's
 * next pass sees two live mandates and tries again (this runs on every
 * transition into live, and syncs re-run it).
 */
async function supersedeOthers(keep: IAutopayMandate, now: Date): Promise<void> {
  const others = await AutopayMandate.find({
    catalogId: keep.catalogId,
    _id: { $ne: keep._id },
    status: { $in: [...LIVE_AUTOPAY_STATUSES, 'HALTED'] },
  }).exec();
  for (const other of others) {
    try {
      await getRazorpayClient().cancelSubscription(other.providerSubscriptionId, false);
    } catch (err) {
      console.error(
        `[autopay] could not cancel superseded ${other.providerSubscriptionId}; will retry`,
        err
      );
      continue;
    }
    const ended = await AutopayMandate.findOneAndUpdate(
      { _id: other._id, status: other.status },
      { $set: { status: 'CANCELLED', endReason: 'SUPERSEDED', endedAt: now, lastSyncedAt: now } },
      { new: true }
    ).exec();
    if (ended) trackChange(ended, other.status, 'CANCELLED', 'RECONCILE');
  }
}

// ── Verify (the checkout sheet's success) ───────────────────────────────────

export type VerifyAutopayResult =
  | { kind: 'SYNCED'; status: AutopayStatus; recordedCharges: number }
  | { kind: 'BAD_SIGNATURE' }
  | { kind: 'UNKNOWN_MANDATE' }
  | { kind: 'UNAVAILABLE' };

/**
 * The app hands over what the sheet returned. The signature proves it came
 * out of a real checkout for THIS subscription; after that it is just a sync
 * — the charge is recorded from Razorpay's invoice, never from the body.
 */
export async function verifyAutopay(
  catalogId: Types.ObjectId,
  input: { subscriptionId: string; paymentId: string; signature: string },
  now: Date = new Date()
): Promise<VerifyAutopayResult> {
  if (!isRazorpayConfigured()) return { kind: 'UNAVAILABLE' };
  if (!verifySubscriptionSignature(input.subscriptionId, input.paymentId, input.signature)) {
    return { kind: 'BAD_SIGNATURE' };
  }
  const mine = await AutopayMandate.exists({
    catalogId,
    providerSubscriptionId: input.subscriptionId,
  }).exec();
  if (!mine) return { kind: 'UNKNOWN_MANDATE' };

  const result = await syncMandate(input.subscriptionId, 'CLIENT', now);
  if (result.kind !== 'SYNCED') return { kind: 'UNAVAILABLE' };
  return { kind: 'SYNCED', status: result.status, recordedCharges: result.recordedCharges };
}

// ── Off ─────────────────────────────────────────────────────────────────────

export type CancelAutopayResult =
  | { outcome: 'CANCELLED'; activeUntil: Date | null }
  /** There is no mandate that could charge. */
  | { outcome: 'NOT_ON' }
  | { outcome: 'UNAVAILABLE' };

/**
 * Turns autopay off: every live or halted mandate is cancelled at Razorpay
 * NOW. The period already paid for is untouched — it is the catalog's, not
 * Razorpay's — so the owner keeps everything until `periodEnd` and is simply
 * not charged again.
 */
export async function cancelAutopay(
  catalogId: Types.ObjectId,
  reason: 'OWNER_CANCELLED' | 'CATALOG_DELETED',
  now: Date = new Date()
): Promise<CancelAutopayResult> {
  const mandates = await AutopayMandate.find({
    catalogId,
    status: { $in: [...LIVE_AUTOPAY_STATUSES, 'HALTED', 'CREATED'] },
  }).exec();
  const chargeable = mandates.filter((m) => m.status !== 'CREATED');
  if (chargeable.length === 0 && reason === 'OWNER_CANCELLED') return { outcome: 'NOT_ON' };
  if (!isRazorpayConfigured()) return { outcome: 'UNAVAILABLE' };

  let failed = false;
  for (const mandate of mandates) {
    try {
      await getRazorpayClient().cancelSubscription(mandate.providerSubscriptionId, false);
    } catch (err) {
      // A CREATED one nobody approved expires by itself; a chargeable one we
      // could not cancel is a real problem and is reported as unavailable.
      if (mandate.status !== 'CREATED') failed = true;
      console.error(`[autopay] cancel failed for ${mandate.providerSubscriptionId}`, err);
      continue;
    }
    const ended = await AutopayMandate.findOneAndUpdate(
      { _id: mandate._id, status: mandate.status },
      { $set: { status: 'CANCELLED', endReason: reason, endedAt: now, lastSyncedAt: now } },
      { new: true }
    ).exec();
    if (ended) trackChange(ended, mandate.status, 'CANCELLED', 'OWNER');
  }
  if (failed) return { outcome: 'UNAVAILABLE' };

  const current = await CatalogSubscription.findOne({ catalogId })
    .select({ status: 1, periodEnd: 1 })
    .lean<{ status: string; periodEnd: Date }>()
    .exec();
  const activeUntil =
    current && current.status === 'ACTIVE' && current.periodEnd > now ? current.periodEnd : null;

  const turnedOff = chargeable[0];
  if (turnedOff && reason === 'OWNER_CANCELLED') {
    await notifyAutopayTurnedOff({
      catalogId,
      ownerUserId: turnedOff.userId,
      providerSubscriptionId: turnedOff.providerSubscriptionId,
      plan: turnedOff.quote.planSnapshot,
      interval: turnedOff.quote.interval,
      amountPaise: turnedOff.quote.totalPaise,
      activeUntil,
    });
  }
  return { outcome: 'CANCELLED', activeUntil };
}

// ── The safety net ──────────────────────────────────────────────────────────

/** A CREATED mandate younger than this is still being approved on a phone. */
const CREATED_CHECK_AFTER_MS = 5 * MINUTE_MS;
/** A live mandate is re-read at least this often, to notice a cancel from the payer's bank. */
const LIVE_RESYNC_EVERY_MS = 12 * HOUR_MS;
/** How long after expiry an unapproved mandate is still asked about once. */
const CREATED_LATE_WINDOW_MS = 48 * HOUR_MS;
/** Bound on provider calls per reconciler run. */
const RECONCILE_BATCH = 50;

export interface AutopayReconcileReport {
  checked: number;
  recordedCharges: number;
  errors: number;
}

/**
 * The reconciler's autopay pass — for a server the webhook cannot reach, or a
 * webhook that is off. Asks Razorpay about: unapproved mandates that may have
 * been approved; live mandates whose charge is due or past; and live ones not
 * read for a while.
 */
export async function reconcileAutopay(now: Date = new Date()): Promise<AutopayReconcileReport> {
  const report: AutopayReconcileReport = { checked: 0, recordedCharges: 0, errors: 0 };
  if (!isRazorpayConfigured()) return report;

  const due = await AutopayMandate.find({
    $or: [
      {
        status: 'CREATED',
        createdAt: { $lt: new Date(now.getTime() - CREATED_CHECK_AFTER_MS) },
        expiresAt: { $gt: new Date(now.getTime() - CREATED_LATE_WINDOW_MS) },
      },
      { status: { $in: [...LIVE_AUTOPAY_STATUSES] }, chargeAt: { $lte: now } },
      {
        status: { $in: [...LIVE_AUTOPAY_STATUSES, 'HALTED'] },
        $or: [
          { lastSyncedAt: { $exists: false } },
          { lastSyncedAt: { $lt: new Date(now.getTime() - LIVE_RESYNC_EVERY_MS) } },
        ],
      },
    ],
  })
    .sort({ lastSyncedAt: 1 })
    .limit(RECONCILE_BATCH)
    .select({ providerSubscriptionId: 1 })
    .lean<{ providerSubscriptionId: string }[]>()
    .exec();

  for (const row of due) {
    report.checked += 1;
    try {
      const result = await syncMandate(row.providerSubscriptionId, 'RECONCILE', now);
      if (result.kind === 'SYNCED') report.recordedCharges += result.recordedCharges;
      else report.errors += 1;
    } catch (err) {
      report.errors += 1;
      console.error(`[autopay] reconcile failed for ${row.providerSubscriptionId}`, err);
    }
  }
  if (report.recordedCharges + report.errors > 0) {
    console.log(
      `[autopay] reconcile checked=${report.checked} recorded=${report.recordedCharges} ` +
        `errors=${report.errors}`
    );
  }
  return report;
}

/**
 * The owner's own read, for ONE catalog: its unapproved and charge-due
 * mandates. Called from reconcileService's on-read settle, which owns the
 * throttle and the time budget.
 */
export async function syncCatalogMandatesOnRead(
  catalogId: Types.ObjectId,
  now: Date = new Date()
): Promise<number> {
  const rows = await AutopayMandate.find({
    catalogId,
    $or: [
      { status: 'CREATED', expiresAt: { $gt: new Date(now.getTime() - CREATED_LATE_WINDOW_MS) } },
      { status: { $in: [...LIVE_AUTOPAY_STATUSES] }, chargeAt: { $lte: now } },
    ],
  })
    .sort({ createdAt: -1 })
    .limit(3)
    .select({ providerSubscriptionId: 1 })
    .lean<{ providerSubscriptionId: string }[]>()
    .exec();
  let recorded = 0;
  for (const row of rows) {
    try {
      const result = await syncMandate(row.providerSubscriptionId, 'RECONCILE', now);
      if (result.kind === 'SYNCED') recorded += result.recordedCharges;
    } catch (err) {
      console.error(`[autopay] on-read sync failed for ${row.providerSubscriptionId}`, err);
    }
  }
  return recorded;
}

/** Used by the webhook route: the subscription id a `subscription.*` event is about. */
export function subscriptionIdOfEvent(event: unknown): string | null {
  if (typeof event !== 'object' || event === null) return null;
  const root = event as { event?: unknown; payload?: { subscription?: { entity?: { id?: unknown } } } };
  if (typeof root.event !== 'string' || !root.event.startsWith('subscription.')) return null;
  const id = root.payload?.subscription?.entity?.id;
  return typeof id === 'string' && id.length > 0 ? id : null;
}
