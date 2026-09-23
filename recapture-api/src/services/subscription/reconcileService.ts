// src/services/subscription/reconcileService.ts
//
// The safety net under the webhook (RECAPTURE_SUBSCRIPTION_PLAN.md B1). Run by
// the worker loop every SUBSCRIPTION_ORDER_RECONCILE_INTERVAL_MS; three scans,
// in this order:
//   1. PAID rows never stamped `appliedAt` — Phase 2 died after Phase 1 (E2).
//      Re-run Phase 2. No provider call.
//   2. Open CHECKOUT_CREATED rows older than five minutes — ask Razorpay
//      whether they were paid; if so, record the payment as if the webhook
//      had (it is idempotent, so a late webhook after this is harmless).
//   3. Orders that EXPIRED in the last 48 h with no PAID row — a UPI collect
//      approved hours late still pays the quoted price (E7).
// Nothing here decides anything about money on its own: the outcomes are the
// webhook service's, reached by the same two functions.
//
// If the reconciler is the one finding payments in two consecutive runs, the
// webhook is almost certainly disabled on Razorpay's side (E4) — that is the
// one alarm this file raises itself.
import type { Types } from 'mongoose';
import { PaymentRecord, type IPaymentRecord } from '@/models/PaymentRecord';
import { getRazorpayClient, isRazorpayConfigured } from '@/providers/razorpay';
import { alertAdmins } from '@/services/subscription/adminAlerts';
import { applyRecordedPayment, recordOnlinePayment } from '@/services/subscription/webhookService';

const MINUTE_MS = 60_000;
const HOUR_MS = 3_600_000;

/** A PAID row older than this with `appliedAt: null` is a crash, not a request in flight. */
export const HALF_APPLIED_AFTER_MS = 2 * MINUTE_MS;
/** An open order younger than this is still being paid on a phone; leave it be. */
export const OPEN_ORDER_CHECK_AFTER_MS = 5 * MINUTE_MS;
/** How long after expiry an order is still checked for a late settlement. */
export const LATE_PAYMENT_WINDOW_MS = 48 * HOUR_MS;

export interface ReconcileReport {
  /** True when RAZORPAY_* is absent — nothing was scanned. */
  skipped: boolean;
  /** Scan 1: half-applied PAID rows whose Phase 2 was re-run. */
  reapplied: number;
  /** Scans 2 + 3: payments RECORDED by this run that the webhook never delivered. */
  rescuedByReconcile: number;
  /** Scans 2 + 3: orders asked about at Razorpay. */
  checkedAtProvider: number;
  /** Scans that threw (provider or DB) and were skipped; the next run retries. */
  errors: number;
}

const EMPTY: ReconcileReport = {
  skipped: false,
  reapplied: 0,
  rescuedByReconcile: 0,
  checkedAtProvider: 0,
  errors: 0,
};

// Runs are process-local by design: the alarm is "this worker keeps finding
// payments the webhook missed", and two workers each seeing one is the same
// symptom twice. Exposed for tests only.
let consecutiveRescueRuns = 0;
export function resetReconcileState(): void {
  consecutiveRescueRuns = 0;
}

/** Records one settled order. Returns whether this call was the first to record it. */
async function settleIfPaid(
  row: Pick<IPaymentRecord, 'providerOrderId'>,
  now: Date
): Promise<boolean> {
  const orderId = row.providerOrderId!;
  const client = getRazorpayClient();
  const order = await client.fetchOrder(orderId);
  if (order.status !== 'paid') return false;
  const payments = await client.fetchPaymentsForOrder(orderId);
  const captured = payments.find((p) => p.status === 'captured');
  if (!captured) return false;
  const { recorded } = await recordOnlinePayment({
    orderId,
    paymentId: captured.id,
    amountPaise: captured.amount,
    notes: null,
    via: 'RECONCILE',
    now,
  });
  return recorded;
}

/** At most one provider check per catalog per this long, however often the owner reads. */
export const ON_READ_MIN_GAP_MS = 5_000;
/** A read waits this long for the provider, then answers with what the DB says. */
export const ON_READ_BUDGET_MS = 4_000;
/** Only the newest few orders — an owner who tapped Pay ten times has one that matters. */
const ON_READ_MAX_ORDERS = 3;

const lastOnReadCheck = new Map<string, number>();
const onReadInFlight = new Map<string, Promise<number>>();

/** Exposed for tests only. */
export function resetOnReadSettleState(): void {
  lastOnReadCheck.clear();
  onReadInFlight.clear();
}

async function settleCatalogOrders(catalogId: Types.ObjectId, now: Date): Promise<number> {
  const rows = await PaymentRecord.find({
    catalogId,
    kind: 'CHECKOUT_CREATED',
    expiresAt: { $gt: new Date(now.getTime() - LATE_PAYMENT_WINDOW_MS) },
  })
    .sort({ createdAt: -1 })
    .limit(ON_READ_MAX_ORDERS)
    .select({ providerOrderId: 1 })
    .lean<Pick<IPaymentRecord, '_id' | 'providerOrderId'>[]>()
    .exec();
  const orderIds = rows.map((r) => r.providerOrderId!).filter(Boolean);
  if (orderIds.length === 0) return 0;
  const settled = new Set(
    await PaymentRecord.distinct('providerOrderId', {
      kind: 'PAID',
      providerOrderId: { $in: orderIds },
    }).exec()
  );

  let recorded = 0;
  for (const row of rows) {
    if (!row.providerOrderId || settled.has(row.providerOrderId)) continue;
    try {
      if (await settleIfPaid(row, now)) recorded += 1;
    } catch (err) {
      console.error(`[reconcile] on-read check failed for order ${row.providerOrderId}`, err);
    }
  }
  if (recorded > 0) {
    console.log(`[reconcile] on-read recorded=${recorded} catalog=${String(catalogId)}`);
  }
  return recorded;
}

/**
 * The owner's own read as a reconcile trigger, for ONE catalog. A paid order
 * must not wait on a webhook that cannot reach this server (a dev box, a
 * disabled hook) or on the worker's next five-minute pass — or on the worker
 * being up at all. So `GET /catalog` and `GET /catalog/subscription` ask
 * Razorpay about this catalog's unsettled orders first, with no five-minute
 * floor: the checkout screen's activation poll is exactly this read.
 *
 * FAIL-OPEN: never throws, and never holds the read past [ON_READ_BUDGET_MS]
 * (a check still running then finishes in the background — recording is
 * idempotent). Throttled per catalog; a catalog with no open order costs one
 * indexed query. Does not feed the WEBHOOKS_SILENT alarm, which is about the
 * worker's own passes.
 */
export async function settleOpenOrdersOnRead(
  catalogId: Types.ObjectId,
  now: Date = new Date()
): Promise<number> {
  if (!isRazorpayConfigured()) return 0;
  const key = String(catalogId);
  let pending = onReadInFlight.get(key);
  if (!pending) {
    const last = lastOnReadCheck.get(key);
    if (last !== undefined && now.getTime() - last < ON_READ_MIN_GAP_MS) return 0;
    if (lastOnReadCheck.size > 1000) {
      for (const [k, at] of lastOnReadCheck) {
        if (now.getTime() - at >= ON_READ_MIN_GAP_MS) lastOnReadCheck.delete(k);
      }
    }
    lastOnReadCheck.set(key, now.getTime());
    pending = settleCatalogOrders(catalogId, now)
      .catch((err: unknown) => {
        console.error(`[reconcile] on-read scan failed for catalog ${key}`, err);
        return 0;
      })
      .finally(() => onReadInFlight.delete(key));
    onReadInFlight.set(key, pending);
  }
  let timer: NodeJS.Timeout | undefined;
  const budget = new Promise<number>((resolve) => {
    timer = setTimeout(() => resolve(0), ON_READ_BUDGET_MS);
  });
  try {
    return await Promise.race([pending, budget]);
  } finally {
    clearTimeout(timer);
  }
}

export async function reconcileOpenOrders(now: Date = new Date()): Promise<ReconcileReport> {
  if (!isRazorpayConfigured()) return { ...EMPTY, skipped: true };
  const report: ReconcileReport = { ...EMPTY };

  // 1. Half-applied payments.
  const halfApplied = await PaymentRecord.find({
    kind: 'PAID',
    appliedAt: null,
    createdAt: { $lt: new Date(now.getTime() - HALF_APPLIED_AFTER_MS) },
  }).exec();
  for (const row of halfApplied) {
    try {
      const outcome = await applyRecordedPayment(row, 'RECONCILE', now);
      if (outcome !== 'ALREADY_APPLIED' && outcome !== 'RACED') report.reapplied += 1;
    } catch (err) {
      report.errors += 1;
      console.error(`[reconcile] re-apply failed for PAID ${String(row._id)}`, err);
    }
  }

  // 2. Open orders old enough that a phone is no longer mid-payment.
  const open = await PaymentRecord.find({
    kind: 'CHECKOUT_CREATED',
    createdAt: { $lt: new Date(now.getTime() - OPEN_ORDER_CHECK_AFTER_MS) },
    expiresAt: { $gt: now },
  })
    .select({ providerOrderId: 1 })
    .lean<Pick<IPaymentRecord, '_id' | 'providerOrderId'>[]>()
    .exec();

  // 3. Recently expired orders with no PAID row yet.
  const expired = await PaymentRecord.find({
    kind: 'CHECKOUT_CREATED',
    expiresAt: { $lte: now, $gt: new Date(now.getTime() - LATE_PAYMENT_WINDOW_MS) },
  })
    .select({ providerOrderId: 1 })
    .lean<Pick<IPaymentRecord, '_id' | 'providerOrderId'>[]>()
    .exec();
  const expiredOrderIds = expired.map((r) => r.providerOrderId!).filter(Boolean);
  const settledOrderIds = new Set(
    expiredOrderIds.length > 0
      ? await PaymentRecord.distinct('providerOrderId', {
          kind: 'PAID',
          providerOrderId: { $in: expiredOrderIds },
        }).exec()
      : []
  );
  const unsettledExpired = expired.filter(
    (r) => r.providerOrderId && !settledOrderIds.has(r.providerOrderId)
  );

  for (const row of [...open, ...unsettledExpired]) {
    if (!row.providerOrderId) continue;
    report.checkedAtProvider += 1;
    try {
      if (await settleIfPaid(row, now)) report.rescuedByReconcile += 1;
    } catch (err) {
      report.errors += 1;
      console.error(`[reconcile] provider check failed for order ${row.providerOrderId}`, err);
    }
  }

  // E4: the webhook being silent looks exactly like this, and like nothing else.
  if (report.rescuedByReconcile > 0) {
    consecutiveRescueRuns += 1;
    if (consecutiveRescueRuns >= 2) {
      void alertAdmins({
        kind: 'WEBHOOKS_SILENT',
        title: 'Razorpay webhooks may be disabled',
        message:
          `Reconciliation recorded ${report.rescuedByReconcile} payment(s) the webhook never ` +
          'delivered, in two consecutive runs. Check Razorpay Dashboard → Webhooks and re-enable.',
      });
    }
  } else {
    consecutiveRescueRuns = 0;
  }

  if (report.reapplied + report.rescuedByReconcile + report.errors > 0) {
    console.log(
      `[reconcile] reapplied=${report.reapplied} rescued=${report.rescuedByReconcile} ` +
        `checked=${report.checkedAtProvider} errors=${report.errors}`
    );
  }
  return report;
}
