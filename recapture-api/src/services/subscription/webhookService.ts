// src/services/subscription/webhookService.ts
//
// Door 2, the second half: money arrived. This file is the ONLY automated
// path that activates or renews a subscription (RECAPTURE_SUBSCRIPTION_PLAN.md
// §7 rule 1) — the route that calls it has already checked the HMAC, and the
// reconciler (reconcileService.ts) calls the same functions when a webhook
// never came.
//
// `recordOnlinePayment` is TWO PHASES, each idempotent on its own, because the
// process can die between them:
//   Phase 1 — RECORD: insert the PAID row, keyed on `payment:<paymentId>`. A
//             replay hits the unique index and loads the row instead.
//   Phase 2 — APPLY: decide the outcome, apply the period if it earned one,
//             then ONE conditional write on `appliedAt: null`. Two workers
//             deciding at once both apply the same idempotent upsert; only one
//             gets to stamp the row (B2, E1, E2).
// Neither phase throws for a business outcome — every branch ends in a row
// and a 200, because a non-2xx makes Razorpay retry and then disable the
// webhook (E4).
//
// PII: the body is parsed for ids and amounts. Nothing else is read, nothing
// is stored, and the raw body is never logged.
import { Types } from 'mongoose';

import { Catalog } from '@/models/Catalog';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { PaymentRecord, type IPaymentRecord, type PaymentQuote } from '@/models/PaymentRecord';
import {
  BILLING_INTERVALS,
  PLAN_IDS,
  type BillingInterval,
  type PlanId,
  type SubscriptionStatus,
} from '@/models/types/subscription.types';
import { alertAdmins } from '@/services/subscription/adminAlerts';
import { quoteFor } from '@/services/subscription/checkoutService';
import { onDisputeClosed, onDisputeCreated } from '@/services/subscription/disputeService';
import { getPlanCatalog } from '@/services/subscription/planCatalogService';
import { applyPaidPeriod, type ApplyVia } from '@/services/subscription/subscriptionService';
import { track, AnalyticsEvent } from '@/utils/analytics';
import { hashIdentifier } from '@/utils/otp';

// ── Outcomes ────────────────────────────────────────────────────────────────

/**
 * What became of a payment. The four flagged outcomes are ALSO the `note` on
 * the PAID row, so the admin queue and this union can never name them apart.
 */
export type OnlinePaymentOutcome =
  | 'APPLIED'
  | 'ALREADY_APPLIED'
  /** Another worker stamped the row first; whatever it decided stands. */
  | 'RACED'
  | 'DUPLICATE_SUSPECTED'
  | 'AMOUNT_MISMATCH'
  | 'ORPHAN_PAYMENT'
  /** Not on the ledger and no usable notes — nothing written (E3, test-mode leak). */
  | 'UNKNOWN_ORDER';

export interface OnlinePaymentInput {
  orderId: string;
  paymentId: string;
  /** Razorpay's `amount` — already paise. Never multiplied. */
  amountPaise: number;
  /** The order's `notes` as Razorpay echoes them — our own breadcrumb (E3). */
  notes?: Record<string, unknown> | null;
  via: Extract<ApplyVia, 'WEBHOOK' | 'RECONCILE'>;
  now?: Date;
}

// ── Helpers ─────────────────────────────────────────────────────────────────

function isDuplicateKey(err: unknown): boolean {
  return (
    typeof err === 'object' &&
    err !== null &&
    'code' in err &&
    (err as { code?: unknown }).code === 11000
  );
}

/** A catalog that still exists and is not soft-deleted. */
async function catalogIsLive(catalogId: Types.ObjectId): Promise<boolean> {
  const found = await Catalog.exists({ _id: catalogId, deletedAt: null }).exec();
  return found !== null;
}

/** Where the money should land — from our checkout row, or rebuilt from the notes. */
type OrderContext =
  | {
      kind: 'KNOWN';
      catalogId: Types.ObjectId;
      ownerUserId: Types.ObjectId;
      subscriptionId: Types.ObjectId | null;
      quote: PaymentQuote;
      /** True when no CHECKOUT_CREATED row exists — the insert failed after Razorpay minted it. */
      orphanOrder: boolean;
    }
  | { kind: 'UNKNOWN' };

function isPlanId(v: unknown): v is PlanId {
  return typeof v === 'string' && (PLAN_IDS as readonly string[]).includes(v);
}
function isInterval(v: unknown): v is BillingInterval {
  return typeof v === 'string' && (BILLING_INTERVALS as readonly string[]).includes(v);
}

async function resolveOrderContext(
  orderId: string,
  notes: Record<string, unknown> | null
): Promise<OrderContext> {
  const checkout = await PaymentRecord.findOne({
    kind: 'CHECKOUT_CREATED',
    providerOrderId: orderId,
  })
    .lean<IPaymentRecord>()
    .exec();
  if (checkout?.quote) {
    return {
      kind: 'KNOWN',
      catalogId: checkout.catalogId,
      ownerUserId: checkout.userId,
      subscriptionId: checkout.subscriptionId ?? null,
      quote: checkout.quote,
      orphanOrder: false,
    };
  }

  // E3: Razorpay created the order, our insert did not land. The notes WE
  // wrote at order create are the only thread back to the catalog.
  const rawCatalogId = notes?.catalogId;
  if (
    typeof rawCatalogId !== 'string' ||
    !Types.ObjectId.isValid(rawCatalogId) ||
    !isPlanId(notes?.planId) ||
    !isInterval(notes?.interval)
  ) {
    return { kind: 'UNKNOWN' };
  }
  const catalogId = new Types.ObjectId(rawCatalogId);
  const [catalog, subscription, plans] = await Promise.all([
    Catalog.findOne({ _id: catalogId }).select({ userId: 1, deletedAt: 1 }).lean().exec(),
    CatalogSubscription.findOne({ catalogId }).select({ _id: 1, userId: 1 }).lean().exec(),
    getPlanCatalog(),
  ]);
  const ownerUserId = catalog?.userId ?? subscription?.userId;
  // Nothing anywhere names this catalog — not the catalog, not a subscription
  // row that outlived it. There is no owner to write a ledger row against.
  if (!ownerUserId) return { kind: 'UNKNOWN' };

  console.warn(
    `[webhook] order ${orderId} has no CHECKOUT_CREATED row; quote rebuilt from notes (E3)`
  );
  return {
    kind: 'KNOWN',
    catalogId,
    ownerUserId,
    subscriptionId: subscription ? (subscription._id as Types.ObjectId) : null,
    quote: quoteFor(plans, notes!.planId as PlanId, notes!.interval as BillingInterval),
    orphanOrder: true,
  };
}

// ── Phase 1: record ─────────────────────────────────────────────────────────

/**
 * Inserts the PAID row, or loads the one a replay already inserted. Returns
 * null only when the order already has a PAID row under a DIFFERENT payment
 * id — Razorpay does not capture two payments on one order, so that is an
 * anomaly for a human, not a row.
 */
async function recordPaidRow(
  ctx: Extract<OrderContext, { kind: 'KNOWN' }>,
  input: OnlinePaymentInput
): Promise<{ row: IPaymentRecord; inserted: boolean } | null> {
  const idempotencyKey = `payment:${input.paymentId}`;
  try {
    const row = await PaymentRecord.create({
      catalogId: ctx.catalogId,
      userId: ctx.ownerUserId,
      ...(ctx.subscriptionId ? { subscriptionId: ctx.subscriptionId } : {}),
      kind: 'PAID',
      amountPaise: input.amountPaise,
      currency: 'INR',
      quote: ctx.quote,
      providerOrderId: input.orderId,
      providerPaymentId: input.paymentId,
      idempotencyKey,
      initiatedBy: { userId: ctx.ownerUserId, role: 'USER' },
      appliedAt: null,
    });
    return { row, inserted: true };
  } catch (err) {
    if (!isDuplicateKey(err)) throw err;
  }
  const existing = await PaymentRecord.findOne({ idempotencyKey }).exec();
  if (existing) return { row: existing, inserted: false };

  const other = await PaymentRecord.findOne({ kind: 'PAID', providerOrderId: input.orderId })
    .select({ providerPaymentId: 1 })
    .lean()
    .exec();
  void alertAdmins({
    kind: 'DUPLICATE_SUSPECTED',
    catalogId: ctx.catalogId,
    title: 'Second payment on one order',
    message:
      `Razorpay reports payment ${input.paymentId} on order ${input.orderId}, ` +
      `which is already settled by payment ${other?.providerPaymentId ?? '?'}. Not recorded.`,
  });
  return null;
}

// ── Phase 2: apply ──────────────────────────────────────────────────────────

/**
 * Decides what a recorded PAID row earns and stamps it, exactly once. Safe to
 * call on any PAID row at any time — the reconciler calls it on rows whose
 * first attempt died mid-way (E2). Everything it needs is on the row.
 */
export async function applyRecordedPayment(
  paid: IPaymentRecord,
  via: Extract<ApplyVia, 'WEBHOOK' | 'RECONCILE'>,
  now: Date = new Date()
): Promise<OnlinePaymentOutcome> {
  if (paid.appliedAt) return 'ALREADY_APPLIED';

  const quote = paid.quote;
  let note: 'AMOUNT_MISMATCH' | 'ORPHAN_PAYMENT' | 'DUPLICATE_SUSPECTED' | null = null;

  if (!quote || paid.amountPaise !== quote.totalPaise) {
    note = 'AMOUNT_MISMATCH';
  } else if (!(await catalogIsLive(paid.catalogId))) {
    note = 'ORPHAN_PAYMENT';
  } else {
    // A period that started AFTER this checkout was opened means the checkout
    // is already paid for — a second capture on the same intent, not a renewal.
    const [checkout, current] = await Promise.all([
      PaymentRecord.findOne({ kind: 'CHECKOUT_CREATED', providerOrderId: paid.providerOrderId })
        .select({ createdAt: 1 })
        .lean<{ createdAt: Date }>()
        .exec(),
      CatalogSubscription.findOne({ catalogId: paid.catalogId })
        .select({ status: 1, periodStart: 1 })
        .lean<{ status: SubscriptionStatus; periodStart: Date }>()
        .exec(),
    ]);
    const openedAt = checkout?.createdAt ?? paid.createdAt;
    if (current && current.status === 'ACTIVE' && current.periodStart >= openedAt) {
      note = 'DUPLICATE_SUSPECTED';
    }
  }

  if (note === null && quote) {
    await applyPaidPeriod({
      catalogId: paid.catalogId,
      ownerUserId: paid.userId,
      planId: quote.planId,
      interval: quote.interval,
      source: 'ONLINE',
      paidAt: now,
      planSnapshot: quote.planSnapshot,
      standeeIncluded: quote.planSnapshot.includedStandeeCount,
      amountPaise: paid.amountPaise,
      paymentRecordId: paid._id as Types.ObjectId,
      via,
    });
  }

  // THE one conditional write. Null means another worker got here first.
  const stamped = await PaymentRecord.findOneAndUpdate(
    { _id: paid._id, appliedAt: null },
    { $set: { appliedAt: now, ...(note ? { note } : {}) } },
    { new: true }
  ).exec();
  if (!stamped) return 'RACED';

  const catalogId = paid.catalogId.toHexString();
  switch (note) {
    case 'AMOUNT_MISMATCH':
      track(AnalyticsEvent.RAZORPAY_WEBHOOK_REJECTED, { reason: 'AMOUNT_MISMATCH' });
      void alertAdmins({
        kind: 'AMOUNT_MISMATCH',
        catalogId: paid.catalogId,
        title: 'Payment amount does not match its quote',
        message:
          `Payment ${paid.providerPaymentId} paid ${paid.amountPaise} paise against a quote of ` +
          `${quote?.totalPaise ?? '?'} paise. Recorded, not activated.`,
      });
      break;
    case 'ORPHAN_PAYMENT':
      void alertAdmins({
        kind: 'ORPHAN_PAYMENT',
        catalogId: paid.catalogId,
        title: 'Payment for a deleted catalog',
        message:
          `Payment ${paid.providerPaymentId} (${paid.amountPaise} paise) arrived for a catalog ` +
          'that no longer exists. Recorded, not activated — a refund case (E5).',
      });
      break;
    case 'DUPLICATE_SUSPECTED':
      track(AnalyticsEvent.SUBSCRIPTION_DUPLICATE_PAYMENT_FLAGGED, {
        catalog_id: catalogId,
        payment_id_hash: hashIdentifier(paid.providerPaymentId ?? String(paid._id)),
      });
      void alertAdmins({
        kind: 'DUPLICATE_SUSPECTED',
        catalogId: paid.catalogId,
        title: 'Possible duplicate payment',
        message:
          `Payment ${paid.providerPaymentId} (${paid.amountPaise} paise) arrived for a period ` +
          'that is already paid. Recorded, period not extended — review for refund.',
      });
      break;
    case null:
      break;
  }

  // Close the checkout: the order is settled, whatever the outcome was.
  if (paid.providerOrderId) {
    await PaymentRecord.updateOne(
      { kind: 'CHECKOUT_CREATED', providerOrderId: paid.providerOrderId, expiresAt: { $gt: now } },
      { $set: { expiresAt: now } }
    ).exec();
  }

  return note ?? 'APPLIED';
}

/**
 * Both phases. The webhook and the reconciler's order scans call this.
 * `recorded` says whether THIS call inserted the PAID row — the reconciler's
 * "the webhook missed one" signal (E4).
 */
export async function recordOnlinePayment(
  input: OnlinePaymentInput
): Promise<{ outcome: OnlinePaymentOutcome; paidRowId: string | null; recorded: boolean }> {
  const now = input.now ?? new Date();
  const ctx = await resolveOrderContext(input.orderId, input.notes ?? null);
  if (ctx.kind === 'UNKNOWN') {
    track(AnalyticsEvent.RAZORPAY_WEBHOOK_REJECTED, { reason: 'UNKNOWN_ORDER' });
    void alertAdmins({
      kind: 'UNKNOWN_ORDER',
      title: 'Payment for an unknown order',
      message:
        `Razorpay reports payment ${input.paymentId} (${input.amountPaise} paise) on order ` +
        `${input.orderId}, which is not on the ledger and carries no usable notes. Nothing written.`,
    });
    return { outcome: 'UNKNOWN_ORDER', paidRowId: null, recorded: false };
  }

  const paid = await recordPaidRow(ctx, input);
  if (!paid) return { outcome: 'DUPLICATE_SUSPECTED', paidRowId: null, recorded: false };

  const outcome = await applyRecordedPayment(paid.row, input.via, now);
  return { outcome, paidRowId: String(paid.row._id), recorded: paid.inserted };
}

// ── Refund events ───────────────────────────────────────────────────────────

async function onRefundProcessed(refund: {
  id: string;
  paymentId: string | null;
  amountPaise: number | null;
}): Promise<void> {
  const own = await PaymentRecord.findOneAndUpdate(
    { kind: 'REFUNDED', providerRefundId: refund.id },
    { $set: { note: 'REFUND_PROCESSED' } }
  ).exec();
  if (own) return;

  // E38: refunded from the Razorpay dashboard, not through our route. The
  // ledger must not stay "paid" while Razorpay says "refunded".
  const paid = refund.paymentId
    ? await PaymentRecord.findOne({ kind: 'PAID', providerPaymentId: refund.paymentId }).exec()
    : null;
  if (!paid) {
    void alertAdmins({
      kind: 'EXTERNAL_REFUND',
      title: 'Refund for a payment not on the ledger',
      message: `Razorpay processed refund ${refund.id}, but no PAID row matches its payment. Nothing written.`,
    });
    return;
  }
  try {
    await PaymentRecord.create({
      catalogId: paid.catalogId,
      userId: paid.userId,
      ...(paid.subscriptionId ? { subscriptionId: paid.subscriptionId } : {}),
      kind: 'REFUNDED',
      amountPaise: refund.amountPaise ?? paid.amountPaise,
      currency: paid.currency,
      providerPaymentId: paid.providerPaymentId,
      providerRefundId: refund.id,
      idempotencyKey: `refund:${refund.id}`,
      refundsPaymentId: paid._id,
      // No admin of ours pressed anything; the owner is the only actor the
      // row can name, and the note is what says where it really came from.
      initiatedBy: paid.initiatedBy,
      note: 'EXTERNAL_REFUND',
    });
  } catch (err) {
    if (!isDuplicateKey(err)) throw err;
    return; // a replay — the row is already there
  }
  void alertAdmins({
    kind: 'EXTERNAL_REFUND',
    catalogId: paid.catalogId,
    title: 'Refund issued outside the app',
    message:
      `Refund ${refund.id} for payment ${paid.providerPaymentId} was processed from the Razorpay ` +
      'dashboard. A REFUNDED row was added so the ledger matches.',
  });
}

async function onRefundFailed(refund: { id: string; reason: string }): Promise<void> {
  const own = await PaymentRecord.findOneAndUpdate(
    { kind: 'REFUNDED', providerRefundId: refund.id },
    { $set: { note: `REFUND_FAILED:${refund.reason}`.slice(0, 1000) } }
  ).exec();
  void alertAdmins({
    kind: 'REFUND_FAILED',
    ...(own ? { catalogId: own.catalogId } : {}),
    title: 'Refund failed at Razorpay',
    message: `Refund ${refund.id} failed (${refund.reason}). The money has not moved.`,
  });
}

// ── The event switch ────────────────────────────────────────────────────────

type Json = Record<string, unknown>;
const obj = (v: unknown): Json | null => (typeof v === 'object' && v !== null ? (v as Json) : null);
const str = (v: unknown): string | null => (typeof v === 'string' && v.length > 0 ? v : null);
const int = (v: unknown): number | null =>
  typeof v === 'number' && Number.isInteger(v) ? v : null;

export interface WebhookHandleResult {
  ignored: boolean;
  outcome?: OnlinePaymentOutcome;
}

/**
 * Routes one verified, parsed Razorpay event. `payment.captured` and
 * `order.paid` are the same fact from two angles and either may arrive first
 * (Assumption A3) — both go through `recordOnlinePayment`, which is idempotent
 * on the payment id. Everything unrecognised is acknowledged and ignored.
 */
export async function handleRazorpayEvent(
  event: unknown,
  now: Date = new Date()
): Promise<WebhookHandleResult> {
  const root = obj(event);
  const name = str(root?.event);
  const payload = obj(root?.payload);
  const payment = obj(obj(payload?.payment)?.entity);
  const order = obj(obj(payload?.order)?.entity);
  const refund = obj(obj(payload?.refund)?.entity);
  const dispute = obj(obj(payload?.dispute)?.entity);

  switch (name) {
    case 'payment.captured':
    case 'order.paid': {
      const orderId = str(payment?.order_id) ?? str(order?.id);
      const paymentId = str(payment?.id);
      const amountPaise = int(payment?.amount);
      if (!orderId || !paymentId || amountPaise === null) {
        track(AnalyticsEvent.RAZORPAY_WEBHOOK_REJECTED, { reason: 'MALFORMED' });
        return { ignored: true };
      }
      const notes = obj(order?.notes) ?? obj(payment?.notes);
      const { outcome } = await recordOnlinePayment({
        orderId,
        paymentId,
        amountPaise,
        notes,
        via: 'WEBHOOK',
        now,
      });
      return { ignored: false, outcome };
    }

    case 'payment.failed': {
      // No row, no state change: the open order stays open so the owner can
      // retry, and the SDK already told the client. Only the analytics trace.
      const orderId = str(payment?.order_id);
      const checkout = orderId
        ? await PaymentRecord.findOne({ kind: 'CHECKOUT_CREATED', providerOrderId: orderId })
            .select({ catalogId: 1 })
            .lean<{ catalogId: Types.ObjectId }>()
            .exec()
        : null;
      const notesCatalog = str(obj(payment?.notes)?.catalogId);
      track(AnalyticsEvent.SUBSCRIPTION_PAYMENT_FAILED, {
        catalog_id: checkout?.catalogId.toHexString() ?? notesCatalog ?? 'unknown',
        failure_reason: (str(payment?.error_code) ?? 'unknown').slice(0, 64),
      });
      return { ignored: false };
    }

    case 'refund.processed': {
      const id = str(refund?.id);
      if (!id) return { ignored: true };
      await onRefundProcessed({
        id,
        paymentId: str(refund?.payment_id),
        amountPaise: int(refund?.amount),
      });
      return { ignored: false };
    }

    case 'refund.failed': {
      const id = str(refund?.id);
      if (!id) return { ignored: true };
      await onRefundFailed({
        id,
        reason: (str(refund?.error_reason) ?? str(refund?.status) ?? 'unknown').slice(0, 120),
      });
      return { ignored: false };
    }

    // B9 — a chargeback. ACTIVE → GRACE and an admin alert; never PAUSED,
    // never a refund (disputeService.ts).
    case 'payment.dispute.created': {
      const id = str(dispute?.id);
      if (!id) return { ignored: true };
      await onDisputeCreated(
        {
          disputeId: id,
          paymentId: str(dispute?.payment_id),
          amountPaise: int(dispute?.amount),
          reasonCode: str(dispute?.reason_code),
        },
        now
      );
      return { ignored: false };
    }

    case 'payment.dispute.closed':
    case 'payment.dispute.won':
    case 'payment.dispute.lost': {
      const id = str(dispute?.id);
      if (!id) return { ignored: true };
      // Three names for one fact. `won` / `lost` say it in the name;
      // `closed` carries it in the entity's status. Anything that is not
      // plainly `won` is treated as lost — the direction that never restores
      // access by mistake.
      const status =
        name === 'payment.dispute.won'
          ? 'won'
          : name === 'payment.dispute.lost'
            ? 'lost'
            : (str(dispute?.status) ?? 'closed');
      await onDisputeClosed({ disputeId: id, paymentId: str(dispute?.payment_id), status }, now);
      return { ignored: false };
    }

    default:
      return { ignored: true };
  }
}
