// src/providers/razorpay.ts
//
// The Razorpay seam — the ONLY file that imports the `razorpay` SDK.
//
// Same shape as the Meshy client (worker/engine/meshy/meshyClient.ts): a tiny
// interface, a default implementation over the official package, and an
// injection point so tests script the provider and CI never calls a live API.
//
// What this file deliberately does NOT do:
//   • decide anything about subscriptions — it moves paise and ids, nothing else;
//   • touch the ledger — services/subscription/* own every PaymentRecord write;
//   • carry PII — `notes` is `{ catalogId, planId, interval }` and nothing more
//     (RECAPTURE_SUBSCRIPTION_PLAN.md §7 rule 8): no phone, no name, no email.
import { createHmac, timingSafeEqual } from 'node:crypto';
import Razorpay from 'razorpay';
import { env } from '@/config/env';

/** The transport surface. Amounts are INTEGER PAISE on both sides. */
export interface RazorpayClient {
  createOrder(input: {
    amountPaise: number;
    currency: 'INR';
    receipt: string;
    notes: Record<string, string>;
  }): Promise<{ id: string; amount: number; status: string }>;
  fetchOrder(orderId: string): Promise<{
    id: string;
    status: 'created' | 'attempted' | 'paid';
    amount: number;
  }>;
  fetchPaymentsForOrder(
    orderId: string
  ): Promise<Array<{ id: string; status: string; amount: number }>>;
  createRefund(
    paymentId: string,
    input: { amountPaise: number; notes: Record<string, string> }
  ): Promise<{ id: string; status: string }>;
  /** One payment by id — the admin journal's lookup of a `pay_…` it has never seen. */
  fetchPayment(paymentId: string): Promise<{
    id: string;
    status: string;
    amount: number;
    orderId: string | null;
    notes: Record<string, string>;
  }>;
  /** Capture an AUTHORIZED payment for exactly `amountPaise` (the admin journal's capture). */
  capturePayment(paymentId: string, amountPaise: number): Promise<{ id: string; status: string }>;

  // ── Autopay (Razorpay Subscriptions) ──────────────────────────────────────

  /** A Razorpay plan: one price, charged every `period`. Immutable once made. */
  createPlan(input: {
    period: 'monthly' | 'yearly';
    amountPaise: number;
    name: string;
    notes: Record<string, string>;
  }): Promise<{ id: string }>;
  /**
   * A subscription on a plan. `startAt` (unix seconds) defers the first
   * charge; omitted, the first cycle is charged when the owner authorises.
   * `expireBy` (unix seconds) is when an unauthorised subscription stops
   * being payable.
   */
  createSubscription(input: {
    planId: string;
    totalCount: number;
    startAt?: number;
    expireBy: number;
    notes: Record<string, string>;
  }): Promise<RazorpaySubscriptionSnapshot>;
  fetchSubscription(subscriptionId: string): Promise<RazorpaySubscriptionSnapshot>;
  /** `atCycleEnd`: stop future charges but let the paid cycle run out. */
  cancelSubscription(
    subscriptionId: string,
    atCycleEnd: boolean
  ): Promise<RazorpaySubscriptionSnapshot>;
  /** Every invoice Razorpay raised on a subscription — one per charge attempt cycle. */
  fetchSubscriptionInvoices(subscriptionId: string): Promise<RazorpayInvoiceSnapshot[]>;
}

/** What we read off a Razorpay subscription. Times are unix SECONDS, as Razorpay sends them. */
export interface RazorpaySubscriptionSnapshot {
  id: string;
  planId: string;
  status: string;
  currentStart: number | null;
  currentEnd: number | null;
  chargeAt: number | null;
  startAt: number | null;
  paidCount: number;
  /** When it ended (cancelled / completed / halted), when it has. */
  endedAt: number | null;
}

export interface RazorpayInvoiceSnapshot {
  id: string;
  /** `paid` is the only status that means money moved. */
  status: string;
  paymentId: string | null;
  orderId: string | null;
  /** Paise. */
  amountPaid: number;
  paidAt: number | null;
  billingStart: number | null;
  billingEnd: number | null;
}

/**
 * Whether checkout can work at all. env.ts already guarantees the three keys
 * are present-or-absent together, so one check is the whole answer.
 */
export function isRazorpayConfigured(): boolean {
  if (configuredOverride !== null) return configuredOverride;
  return Boolean(env.RAZORPAY_KEY_ID && env.RAZORPAY_KEY_SECRET && env.RAZORPAY_WEBHOOK_SECRET);
}

let configuredOverride: boolean | null = null;

/**
 * TEST SEAM ONLY. env is validated and frozen at import, so a suite cannot
 * flip the keys per test; this lets the "keys absent → 503" path be exercised
 * in the same process as the configured one. `null` restores the env answer.
 */
export function setRazorpayConfiguredForTests(value: boolean | null): void {
  configuredOverride = value;
}

/**
 * Thrown by the default client when Razorpay cannot be reached or refuses the
 * call. Callers map it to 503 PAYMENTS_UNAVAILABLE (D7) — never a 500, and
 * never the provider's message verbatim (it may echo request fields).
 */
export class RazorpayUnavailableError extends Error {
  constructor(operation: string, cause?: unknown) {
    super(`Razorpay ${operation} failed`);
    this.name = 'RazorpayUnavailableError';
    if (cause !== undefined) (this as { cause?: unknown }).cause = cause;
  }
}

let sdk: Razorpay | undefined;

/** Lazily built so importing this module never requires the keys. */
function instance(): Razorpay {
  if (!sdk) {
    if (!isRazorpayConfigured()) {
      throw new RazorpayUnavailableError('client construction', 'RAZORPAY_* env not configured');
    }
    sdk = new Razorpay({ key_id: env.RAZORPAY_KEY_ID, key_secret: env.RAZORPAY_KEY_SECRET });
  }
  return sdk;
}

async function guarded<T>(operation: string, run: () => Promise<T>): Promise<T> {
  try {
    return await run();
  } catch (err) {
    throw new RazorpayUnavailableError(operation, err);
  }
}

function orderStatus(raw: unknown): 'created' | 'attempted' | 'paid' {
  return raw === 'paid' || raw === 'attempted' ? raw : 'created';
}

/** The real thing. Every call is wrapped so a provider failure has ONE type. */
export const razorpayClient: RazorpayClient = {
  async createOrder(input) {
    return guarded('create order', async () => {
      const order = await instance().orders.create({
        amount: input.amountPaise,
        currency: input.currency,
        receipt: input.receipt,
        notes: input.notes,
      });
      return { id: order.id, amount: Number(order.amount), status: String(order.status) };
    });
  },

  async fetchOrder(orderId) {
    return guarded('fetch order', async () => {
      const order = await instance().orders.fetch(orderId);
      return { id: order.id, status: orderStatus(order.status), amount: Number(order.amount) };
    });
  },

  async fetchPaymentsForOrder(orderId) {
    return guarded('fetch order payments', async () => {
      const res = await instance().orders.fetchPayments(orderId);
      return res.items.map((p) => ({
        id: p.id,
        status: String(p.status),
        amount: Number(p.amount),
      }));
    });
  },

  async createRefund(paymentId, input) {
    return guarded('create refund', async () => {
      const refund = await instance().payments.refund(paymentId, {
        amount: input.amountPaise,
        notes: input.notes,
      });
      return { id: refund.id, status: String(refund.status) };
    });
  },

  async fetchPayment(paymentId) {
    return guarded('fetch payment', async () => {
      const p = await instance().payments.fetch(paymentId);
      const notes: Record<string, string> = {};
      if (p.notes && typeof p.notes === 'object') {
        for (const [k, v] of Object.entries(p.notes)) {
          if (typeof v === 'string' || typeof v === 'number') notes[k] = String(v);
        }
      }
      return {
        id: p.id,
        status: String(p.status),
        amount: Number(p.amount),
        orderId: typeof p.order_id === 'string' && p.order_id ? p.order_id : null,
        notes,
      };
    });
  },

  async capturePayment(paymentId, amountPaise) {
    return guarded('capture payment', async () => {
      const p = await instance().payments.capture(paymentId, amountPaise, 'INR');
      return { id: p.id, status: String(p.status) };
    });
  },

  async createPlan(input) {
    return guarded('create plan', async () => {
      const plan = await instance().plans.create({
        period: input.period,
        interval: 1,
        item: { name: input.name, amount: input.amountPaise, currency: 'INR' },
        notes: input.notes,
      });
      return { id: plan.id };
    });
  },

  async createSubscription(input) {
    return guarded('create subscription', async () => {
      const sub = await instance().subscriptions.create({
        plan_id: input.planId,
        total_count: input.totalCount,
        // Razorpay's own SMS/email to the payer (pre-debit notices, receipts).
        // It collects the contact itself in checkout — we never send one (§7 rule 8).
        customer_notify: 1,
        ...(input.startAt !== undefined ? { start_at: input.startAt } : {}),
        expire_by: input.expireBy,
        notes: input.notes,
      });
      return toSubscriptionSnapshot(sub);
    });
  },

  async fetchSubscription(subscriptionId) {
    return guarded('fetch subscription', async () =>
      toSubscriptionSnapshot(await instance().subscriptions.fetch(subscriptionId))
    );
  },

  async cancelSubscription(subscriptionId, atCycleEnd) {
    return guarded('cancel subscription', async () =>
      toSubscriptionSnapshot(await instance().subscriptions.cancel(subscriptionId, atCycleEnd))
    );
  },

  async fetchSubscriptionInvoices(subscriptionId) {
    return guarded('fetch subscription invoices', async () => {
      const res = await instance().invoices.all({ subscription_id: subscriptionId, count: 100 });
      return res.items.map((inv) => ({
        id: String(inv.id),
        status: String(inv.status),
        paymentId: typeof inv.payment_id === 'string' && inv.payment_id ? inv.payment_id : null,
        orderId: typeof inv.order_id === 'string' && inv.order_id ? inv.order_id : null,
        amountPaid: Number(inv.amount_paid ?? 0),
        paidAt: numOrNull(inv.paid_at),
        billingStart: numOrNull(inv.billing_start),
        billingEnd: numOrNull(inv.billing_end),
      }));
    });
  },
};

function numOrNull(v: unknown): number | null {
  const n = typeof v === 'string' ? Number(v) : v;
  return typeof n === 'number' && Number.isFinite(n) && n > 0 ? n : null;
}

function toSubscriptionSnapshot(sub: {
  id: string;
  plan_id: string;
  status: string;
  current_start?: number | null;
  current_end?: number | null;
  charge_at?: number | null;
  start_at?: number | null;
  paid_count?: number | null;
  ended_at?: number | null;
}): RazorpaySubscriptionSnapshot {
  return {
    id: sub.id,
    planId: sub.plan_id,
    status: String(sub.status),
    currentStart: numOrNull(sub.current_start),
    currentEnd: numOrNull(sub.current_end),
    chargeAt: numOrNull(sub.charge_at),
    startAt: numOrNull(sub.start_at),
    paidCount: Number(sub.paid_count ?? 0),
    endedAt: numOrNull(sub.ended_at),
  };
}

let active: RazorpayClient = razorpayClient;

/** Injection seam — tests register a fake so CI never touches the live API. */
export function setRazorpayClient(client: RazorpayClient): void {
  active = client;
}

export function getRazorpayClient(): RazorpayClient {
  return active;
}

/** Back to the real client (and a fresh SDK instance on next use). */
export function resetRazorpayClient(): void {
  active = razorpayClient;
  sdk = undefined;
}

/**
 * Razorpay signs a webhook as `hex(HMAC-SHA256(secret, rawBody))` in the
 * `X-Razorpay-Signature` header. The HMAC is over the EXACT bytes, which is
 * why the route is mounted with `express.raw` above the JSON parser.
 *
 * Constant-time compare on equal-length buffers; a malformed or wrong-length
 * signature is simply false. Unconfigured secret → false (nothing can verify).
 */
export function verifyWebhookSignature(rawBody: Buffer, signature: string | undefined): boolean {
  const secret = env.RAZORPAY_WEBHOOK_SECRET;
  if (!secret || typeof signature !== 'string' || signature.length === 0) return false;
  const expected = createHmac('sha256', secret).update(rawBody).digest();
  let provided: Buffer;
  try {
    provided = Buffer.from(signature, 'hex');
  } catch {
    return false;
  }
  if (provided.length !== expected.length) return false;
  return timingSafeEqual(provided, expected);
}

/** Test helper: the signature Razorpay would send for this body under this secret. */
export function signWebhookBody(rawBody: Buffer | string, secret: string): string {
  return createHmac('sha256', secret).update(rawBody).digest('hex');
}

/**
 * The Checkout sheet's success handler hands the app `razorpay_order_id`,
 * `razorpay_payment_id` and `razorpay_signature`, where the signature is
 * `hex(HMAC-SHA256(KEY_SECRET, orderId + "|" + paymentId))`. Only Razorpay and
 * this server hold the key secret, so a valid signature proves the pair came
 * out of a real checkout for THIS order — the app cannot mint one.
 *
 * Same constant-time compare as the webhook. Unconfigured secret → false.
 */
export function verifyCheckoutSignature(
  orderId: string,
  paymentId: string,
  signature: string | undefined
): boolean {
  const secret = env.RAZORPAY_KEY_SECRET;
  if (!secret || typeof signature !== 'string' || signature.length === 0) return false;
  const expected = createHmac('sha256', secret).update(`${orderId}|${paymentId}`).digest();
  let provided: Buffer;
  try {
    provided = Buffer.from(signature, 'hex');
  } catch {
    return false;
  }
  if (provided.length !== expected.length) return false;
  return timingSafeEqual(provided, expected);
}

/** Test helper: the signature the Checkout sheet would hand the app. */
export function signCheckoutResponse(orderId: string, paymentId: string, secret: string): string {
  return createHmac('sha256', secret).update(`${orderId}|${paymentId}`).digest('hex');
}

/**
 * The autopay twin of {@link verifyCheckoutSignature}. For a SUBSCRIPTION the
 * sheet returns `razorpay_subscription_id` instead of an order id, and the
 * signature is `hex(HMAC-SHA256(KEY_SECRET, paymentId + "|" + subscriptionId))`
 * — note the order: payment FIRST, the reverse of the order-based one.
 */
export function verifySubscriptionSignature(
  subscriptionId: string,
  paymentId: string,
  signature: string | undefined
): boolean {
  const secret = env.RAZORPAY_KEY_SECRET;
  if (!secret || typeof signature !== 'string' || signature.length === 0) return false;
  const expected = createHmac('sha256', secret).update(`${paymentId}|${subscriptionId}`).digest();
  let provided: Buffer;
  try {
    provided = Buffer.from(signature, 'hex');
  } catch {
    return false;
  }
  if (provided.length !== expected.length) return false;
  return timingSafeEqual(provided, expected);
}

/** Test helper: the signature the sheet hands the app for an autopay authorisation. */
export function signSubscriptionResponse(
  subscriptionId: string,
  paymentId: string,
  secret: string
): string {
  return createHmac('sha256', secret).update(`${paymentId}|${subscriptionId}`).digest('hex');
}
