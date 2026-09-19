// src/services/subscription/checkoutService.ts
//
// Door 2, the first half: the owner asks for something to pay. We mint ONE
// Razorpay order per catalog, freeze the quote on a CHECKOUT_CREATED ledger
// row for `orderTtlHours`, and hand back the ids the in-app SDK needs. The
// second half — the money actually arriving — is webhookService.ts, and
// NOTHING here activates anything (RECAPTURE_SUBSCRIPTION_PLAN.md §7 rule 1).
//
// No Express types. The route maps the result union onto the envelope.
import { Types } from 'mongoose';

import { env } from '@/config/env';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { PaymentRecord, type IPaymentRecord, type PaymentQuote } from '@/models/PaymentRecord';
import type { ICatalogSubscription } from '@/models/CatalogSubscription';
import {
  yearlyPricePaise,
  type Actor,
  type BillingInterval,
  type PlanCatalog,
  type PlanId,
} from '@/models/types/subscription.types';
import { getRazorpayClient, isRazorpayConfigured } from '@/providers/razorpay';
import { getPlanCatalog } from '@/services/subscription/planCatalogService';
import { daysForfeitedFor } from '@/services/subscription/subscriptionService';
import { track, AnalyticsEvent } from '@/utils/analytics';
import { consumeRateWindow } from '@/utils/rateLimit';

const HOUR_MS = 3_600_000;

/** Fresh orders per catalog per hour — retries of an OPEN order do not count (E8). */
const CHECKOUT_MAX_NEW_ORDERS_PER_HOUR = 10;

/** What the client needs to open the SDK — and nothing it could misuse. No URL. */
export interface CheckoutOrderDto {
  providerOrderId: string;
  amountPaise: number;
  currency: 'INR';
  /** The public half of the key pair; the SDK needs it. Never the secret. */
  keyId: string;
  quote: PaymentQuote;
  /** ISO — when this order stops being payable and a new quote is minted. */
  expiresAt: string;
  /** ISO, or null when the catalog has no period running. */
  currentPeriodEnd: string | null;
  /** Days on the current period a payment now would forfeit (E9). 0 when none. */
  daysForfeited: number;
}

export type CreateOrderResult =
  | { outcome: 'OK'; reused: boolean; order: CheckoutOrderDto }
  /** RAZORPAY_* not configured, or Razorpay did not answer (D7 → 503). */
  | { outcome: 'UNAVAILABLE' }
  | { outcome: 'RATE_LIMITED'; retryAfter: number };

/** The quote for a plan at an interval — the ONE place the total is computed. */
export function quoteFor(
  plans: PlanCatalog,
  planId: PlanId,
  interval: BillingInterval
): PaymentQuote {
  const plan = plans.plans[planId];
  return {
    planId,
    planSnapshot: plan,
    interval,
    totalPaise: interval === 'YEARLY' ? yearlyPricePaise(plan) : plan.priceMonthlyPaise,
  };
}

type CurrentRow = Pick<ICatalogSubscription, '_id' | 'status' | 'periodEnd'>;

function toDto(
  row: Pick<IPaymentRecord, 'providerOrderId' | 'amountPaise' | 'currency' | 'quote' | 'expiresAt'>,
  current: CurrentRow | null,
  now: Date
): CheckoutOrderDto {
  return {
    providerOrderId: row.providerOrderId!,
    amountPaise: row.amountPaise,
    currency: 'INR',
    keyId: env.RAZORPAY_KEY_ID!,
    quote: row.quote!,
    expiresAt: row.expiresAt!.toISOString(),
    currentPeriodEnd: current ? current.periodEnd.toISOString() : null,
    daysForfeited: daysForfeitedFor(current, now),
  };
}

function isDuplicateKey(err: unknown): boolean {
  return (
    typeof err === 'object' &&
    err !== null &&
    'code' in err &&
    (err as { code?: unknown }).code === 11000
  );
}

/**
 * Create-or-return. The open order is returned UNCHANGED even when the owner
 * has since picked a different plan (Assumption A1): the quote is frozen for
 * its TTL and a client that wants a different one waits for expiry. What that
 * buys is that a double-tap, a retried UPI attempt and a re-opened screen all
 * see the same `providerOrderId`, so the webhook can only ever match one row.
 */
export async function createOrReturnOrder(
  catalogId: Types.ObjectId,
  ownerUserId: Types.ObjectId,
  actor: Actor,
  input: { planId: PlanId; interval: BillingInterval },
  now: Date = new Date()
): Promise<CreateOrderResult> {
  if (!isRazorpayConfigured()) return { outcome: 'UNAVAILABLE' };

  const current = await CatalogSubscription.findOne({ catalogId })
    .select({ _id: 1, status: 1, periodEnd: 1 })
    .lean<CurrentRow>()
    .exec();

  const open = await PaymentRecord.findOne({
    catalogId,
    kind: 'CHECKOUT_CREATED',
    expiresAt: { $gt: now },
  })
    .sort({ createdAt: -1 })
    .lean<IPaymentRecord>()
    .exec();
  if (open) {
    track(AnalyticsEvent.SUBSCRIPTION_ORDER_CREATED, {
      catalog_id: catalogId.toHexString(),
      plan_id: open.quote!.planId,
      interval: open.quote!.interval,
      amount_paise: open.amountPaise,
      reused: true,
    });
    return { outcome: 'OK', reused: true, order: toDto(open, current, now) };
  }

  // Metered HERE, after the open-order check, so retrying a failed attempt on
  // an open order is never what locks an owner out (E8).
  const rate = await consumeRateWindow(
    `checkout:${catalogId.toHexString()}`,
    CHECKOUT_MAX_NEW_ORDERS_PER_HOUR,
    3600,
    now.getTime()
  );
  if (rate.limited) return { outcome: 'RATE_LIMITED', retryAfter: rate.retryAfter };

  const plans = await getPlanCatalog();
  const quote = quoteFor(plans, input.planId, input.interval);

  let providerOrder: { id: string };
  try {
    providerOrder = await getRazorpayClient().createOrder({
      amountPaise: quote.totalPaise,
      currency: 'INR',
      receipt: `cat_${catalogId.toHexString()}_${now.getTime()}`,
      // The recovery breadcrumb the webhook reads when OUR insert below fails
      // (E3). Ids and enums only — never a phone or a name (§7 rule 8).
      notes: { catalogId: catalogId.toHexString(), planId: quote.planId, interval: quote.interval },
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : 'unknown error';
    console.warn(`[checkout] Razorpay order create failed (${message})`);
    return { outcome: 'UNAVAILABLE' };
  }

  const expiresAt = new Date(now.getTime() + plans.orderTtlHours * HOUR_MS);
  let row: IPaymentRecord;
  try {
    row = await PaymentRecord.create({
      catalogId,
      userId: ownerUserId,
      ...(current ? { subscriptionId: current._id } : {}),
      kind: 'CHECKOUT_CREATED',
      amountPaise: quote.totalPaise,
      currency: 'INR',
      quote,
      providerOrderId: providerOrder.id,
      idempotencyKey: `order:${providerOrder.id}`,
      initiatedBy: actor,
      expiresAt,
    });
  } catch (err) {
    if (!isDuplicateKey(err)) throw err;
    // The provider order id is already on the ledger — a replayed create for
    // the same Razorpay order. Return the row that won (§7 rule 2).
    const winner = await PaymentRecord.findOne({ providerOrderId: providerOrder.id })
      .lean<IPaymentRecord>()
      .exec();
    if (!winner) throw err;
    return { outcome: 'OK', reused: true, order: toDto(winner, current, now) };
  }

  track(AnalyticsEvent.SUBSCRIPTION_ORDER_CREATED, {
    catalog_id: catalogId.toHexString(),
    plan_id: quote.planId,
    interval: quote.interval,
    amount_paise: quote.totalPaise,
    reused: false,
  });

  return { outcome: 'OK', reused: false, order: toDto(row, current, now) };
}
