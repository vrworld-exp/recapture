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
};

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
