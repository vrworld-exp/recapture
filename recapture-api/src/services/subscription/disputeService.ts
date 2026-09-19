// src/services/subscription/disputeService.ts
//
// B9 — a chargeback. The customer's bank has pulled the money back and asked
// Razorpay to justify the charge. Two facts about how this is handled, both
// from RECAPTURE_SUBSCRIPTION_PLAN.md §8 B9 and gaps-addendum G1:
//   • ACTIVE → GRACE, never straight to PAUSED. The owner keeps full access
//     for the grace window while a human sorts it out; the sweep (Stage 5)
//     pauses the row at `graceEndsAt` like any other lapsed grace.
//   • NO REFUND. A dispute is not the B3 exception — the money is already in
//     the bank's hands, and issuing a refund on top would pay it out twice.
//
// `disputeGraceAt` on the subscription is what lets `won` tell "the grace
// this dispute started" from "a grace the period's end started": only the
// former is restored to ACTIVE when the dispute is won. Every row written
// here is keyed on the dispute id, so a replayed delivery is a no-op.
//
// Called from the webhook's event switch; like every other handler there it
// never throws for a business outcome.
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { PaymentRecord, type IPaymentRecord } from '@/models/PaymentRecord';
import type { SubscriptionStatus } from '@/models/types/subscription.types';
import { alertAdmins } from '@/services/subscription/adminAlerts';
import { getPlanCatalog } from '@/services/subscription/planCatalogService';
import { track, AnalyticsEvent } from '@/utils/analytics';

const DAY_MS = 86_400_000;

function isDuplicateKey(err: unknown): boolean {
  return (
    typeof err === 'object' &&
    err !== null &&
    'code' in err &&
    (err as { code?: unknown }).code === 11000
  );
}

export interface DisputeCreatedInput {
  /** Razorpay's `disp_…` id. */
  disputeId: string;
  paymentId: string | null;
  /** Razorpay's `amount` — already paise. */
  amountPaise: number | null;
  reasonCode: string | null;
}

export type DisputeCreatedOutcome =
  /** Row written, subscription moved ACTIVE → GRACE. */
  | 'GRACE'
  /** Row written; the subscription was not ACTIVE (already GRACE, TRIAL, COMPED, …) so it was left alone. */
  | 'RECORDED'
  /** A replayed delivery — nothing written. */
  | 'REPLAY'
  /** No PAID row carries this payment id — a MANUAL/COMP row can never be disputed, so this is noise. */
  | 'UNKNOWN_PAYMENT';

/** The PAID row a dispute is about, or null. */
async function paidRowFor(paymentId: string | null): Promise<IPaymentRecord | null> {
  if (!paymentId) return null;
  return PaymentRecord.findOne({ kind: 'PAID', providerPaymentId: paymentId }).exec();
}

export async function onDisputeCreated(
  input: DisputeCreatedInput,
  now: Date = new Date()
): Promise<DisputeCreatedOutcome> {
  const paid = await paidRowFor(input.paymentId);
  if (!paid) {
    console.warn(`[webhook] dispute ${input.disputeId} names no PAID row; ignored`);
    void alertAdmins({
      kind: 'DISPUTE',
      title: 'Chargeback on an unknown payment',
      message:
        `Razorpay opened dispute ${input.disputeId} on payment ${input.paymentId ?? '?'}, ` +
        'which is not on the ledger. Nothing written.',
    });
    return 'UNKNOWN_PAYMENT';
  }

  const amountPaise = input.amountPaise ?? paid.amountPaise;
  try {
    await PaymentRecord.create({
      catalogId: paid.catalogId,
      userId: paid.userId,
      ...(paid.subscriptionId ? { subscriptionId: paid.subscriptionId } : {}),
      kind: 'DISPUTED',
      amountPaise,
      currency: paid.currency,
      providerPaymentId: paid.providerPaymentId,
      idempotencyKey: `dispute:${input.disputeId}`,
      // No admin of ours pressed anything; the owner is the only actor the
      // row can name (same shape as an external refund).
      initiatedBy: paid.initiatedBy,
      reference: input.disputeId,
      ...(input.reasonCode ? { note: input.reasonCode.slice(0, 1000) } : {}),
    });
  } catch (err) {
    if (!isDuplicateKey(err)) throw err;
    return 'REPLAY';
  }

  // Only from ACTIVE. A row already in GRACE keeps its clock; TRIAL, COMPED,
  // PAUSED and CANCELLED are not what this payment bought and are untouched.
  const { graceDays } = await getPlanCatalog();
  const moved = await CatalogSubscription.findOneAndUpdate(
    { catalogId: paid.catalogId, status: 'ACTIVE' },
    {
      $set: {
        status: 'GRACE',
        graceEndsAt: new Date(now.getTime() + graceDays * DAY_MS),
        disputeGraceAt: now,
      },
    },
    { new: false }
  )
    .select({ status: 1 })
    .lean<{ status: SubscriptionStatus }>()
    .exec();

  const previousStatus: SubscriptionStatus | 'NONE' = moved
    ? moved.status
    : ((
        await CatalogSubscription.findOne({ catalogId: paid.catalogId })
          .select({ status: 1 })
          .lean<{ status: SubscriptionStatus }>()
          .exec()
      )?.status ?? 'NONE');

  const catalogId = paid.catalogId.toHexString();
  track(AnalyticsEvent.SUBSCRIPTION_DISPUTE_RECEIVED, {
    catalog_id: catalogId,
    amount_paise: amountPaise,
    previous_status: previousStatus,
  });
  if (moved) {
    track(AnalyticsEvent.SUBSCRIPTION_STATE_CHANGED, {
      catalog_id: catalogId,
      from: 'ACTIVE',
      to: 'GRACE',
      by: 'DISPUTE',
    });
  }

  void alertAdmins({
    kind: 'DISPUTE',
    catalogId: paid.catalogId,
    title: 'Chargeback opened on a payment',
    message:
      `Dispute ${input.disputeId} (${amountPaise} paise) was opened on payment ` +
      `${paid.providerPaymentId}${input.reasonCode ? `, reason ${input.reasonCode}` : ''}. ` +
      (moved
        ? `The subscription is in grace for ${graceDays} days. No refund was issued.`
        : `The subscription was ${previousStatus} and was left as it is. No refund was issued.`),
  });

  return moved ? 'GRACE' : 'RECORDED';
}

export interface DisputeClosedInput {
  disputeId: string;
  paymentId: string | null;
  /** Razorpay's final `status` — `won` | `lost`; anything else is treated as lost. */
  status: string | null;
}

export type DisputeClosedOutcome =
  /** Won while still in the dispute's own grace — back to ACTIVE. */
  | 'RESTORED'
  /** Row written; no state change (lost, or won after the sweep already moved the row). */
  | 'RECORDED'
  | 'REPLAY'
  | 'UNKNOWN_PAYMENT';

export async function onDisputeClosed(
  input: DisputeClosedInput,
  now: Date = new Date()
): Promise<DisputeClosedOutcome> {
  const paid = await paidRowFor(input.paymentId);
  if (!paid) {
    console.warn(`[webhook] dispute-closed ${input.disputeId} names no PAID row; ignored`);
    return 'UNKNOWN_PAYMENT';
  }
  const won = input.status === 'won';
  const result: 'won' | 'lost' = won ? 'won' : 'lost';

  try {
    await PaymentRecord.create({
      catalogId: paid.catalogId,
      userId: paid.userId,
      ...(paid.subscriptionId ? { subscriptionId: paid.subscriptionId } : {}),
      kind: 'DISPUTED',
      amountPaise: paid.amountPaise,
      currency: paid.currency,
      providerPaymentId: paid.providerPaymentId,
      idempotencyKey: `dispute-closed:${input.disputeId}`,
      initiatedBy: paid.initiatedBy,
      reference: input.disputeId,
      note: `CLOSED_${(input.status ?? 'unknown').toUpperCase()}`.slice(0, 1000),
    });
  } catch (err) {
    if (!isDuplicateKey(err)) throw err;
    return 'REPLAY';
  }

  let restored = false;
  if (won) {
    // Only the grace THIS mechanism started, and only while the paid period
    // itself still has days on it — a won dispute on an expired period has
    // nothing to restore. Lost → no change; the sweep pauses it on schedule.
    const updated = await CatalogSubscription.findOneAndUpdate(
      {
        catalogId: paid.catalogId,
        status: 'GRACE',
        disputeGraceAt: { $ne: null },
        periodEnd: { $gt: now },
      },
      { $set: { status: 'ACTIVE', graceEndsAt: null, disputeGraceAt: null } },
      { new: true }
    )
      .select({ _id: 1 })
      .lean()
      .exec();
    restored = updated !== null;
  }

  const catalogId = paid.catalogId.toHexString();
  track(AnalyticsEvent.SUBSCRIPTION_DISPUTE_CLOSED, { catalog_id: catalogId, result });
  if (restored) {
    track(AnalyticsEvent.SUBSCRIPTION_STATE_CHANGED, {
      catalog_id: catalogId,
      from: 'GRACE',
      to: 'ACTIVE',
      by: 'DISPUTE',
    });
  }

  const current = await CatalogSubscription.findOne({ catalogId: paid.catalogId })
    .select({ status: 1 })
    .lean<{ status: SubscriptionStatus }>()
    .exec();
  void alertAdmins({
    kind: 'DISPUTE',
    catalogId: paid.catalogId,
    title: won ? 'Chargeback won' : 'Chargeback lost',
    message:
      `Dispute ${input.disputeId} on payment ${paid.providerPaymentId} closed as ${result}. ` +
      (restored
        ? 'The subscription is ACTIVE again.'
        : `The subscription is ${current?.status ?? 'gone'}${
            won && current?.status === 'PAUSED'
              ? ' — grace ran out before the ruling; comp it if the owner should be live'
              : ''
          }.`),
  });

  return restored ? 'RESTORED' : 'RECORDED';
}
