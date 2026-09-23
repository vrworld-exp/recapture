// src/services/subscription/clientVerifyService.ts
//
// Door 2's fast path: the app hands over what the Razorpay sheet returned on
// success, and the payment is recorded NOW instead of whenever the webhook
// arrives (or never, on a server the webhook cannot reach).
//
// The app is not trusted with the money. Two checks, both server-side:
//   1. The checkout signature — HMAC(KEY_SECRET, orderId|paymentId). Only a
//      real Razorpay checkout for this order can produce it.
//   2. Razorpay itself — the payment must be CAPTURED on that order, and the
//      amount recorded is Razorpay's, never the body's.
// Then the same `recordOnlinePayment` the webhook and the reconciler call, so
// all three converge on one PAID row by idempotency key (`payment:<id>`): a
// webhook that lands after this is a no-op, and so is this after the webhook.
//
// A payment that is authorized but not yet captured, or a Razorpay outage, is
// PENDING — not a failure. The webhook, the reconciler and the settle-on-read
// are all still in place behind this.
import type { Types } from 'mongoose';
import { PaymentRecord } from '@/models/PaymentRecord';
import {
  getRazorpayClient,
  isRazorpayConfigured,
  verifyCheckoutSignature,
} from '@/providers/razorpay';
import {
  recordOnlinePayment,
  type OnlinePaymentOutcome,
} from '@/services/subscription/webhookService';

export interface ClientVerifyInput {
  orderId: string;
  paymentId: string;
  signature: string;
}

export type ClientVerifyResult =
  /** The PAID row exists (this call or an earlier one); `outcome` is how it applied. */
  | { kind: 'RECORDED'; outcome: OnlinePaymentOutcome }
  /** Genuine, but Razorpay has not captured it yet, or could not be asked. */
  | { kind: 'PENDING' }
  | { kind: 'BAD_SIGNATURE' }
  /** Not an order this catalog opened. */
  | { kind: 'UNKNOWN_ORDER' }
  | { kind: 'UNAVAILABLE' };

export async function verifyClientPayment(
  catalogId: Types.ObjectId,
  input: ClientVerifyInput,
  now: Date = new Date()
): Promise<ClientVerifyResult> {
  if (!isRazorpayConfigured()) return { kind: 'UNAVAILABLE' };
  if (!verifyCheckoutSignature(input.orderId, input.paymentId, input.signature)) {
    return { kind: 'BAD_SIGNATURE' };
  }

  const order = await PaymentRecord.exists({
    catalogId,
    kind: 'CHECKOUT_CREATED',
    providerOrderId: input.orderId,
  }).exec();
  if (!order) return { kind: 'UNKNOWN_ORDER' };

  let captured: { id: string; amount: number } | undefined;
  try {
    const payments = await getRazorpayClient().fetchPaymentsForOrder(input.orderId);
    captured = payments.find((p) => p.id === input.paymentId && p.status === 'captured');
  } catch (err) {
    console.error(`[client-verify] provider check failed for order ${input.orderId}`, err);
    return { kind: 'PENDING' };
  }
  if (!captured) return { kind: 'PENDING' };

  const { outcome } = await recordOnlinePayment({
    orderId: input.orderId,
    paymentId: captured.id,
    amountPaise: captured.amount,
    notes: null,
    via: 'CLIENT',
    now,
  });
  return { kind: 'RECORDED', outcome };
}
