// src/services/subscription/ownerNotifications.ts
//
// EVERY subscription event an owner is told about, in one voice
// (RECAPTURE_SUBSCRIPTION_PLAN.md §6, §9; learn.txt requirement 3).
//
// Before this file the owner heard from us on exactly two occasions: the four
// COUNTDOWN reminders the sweep sends (−7 d, −1 d, on GRACE, grace midpoint)
// and the rep's manual nudge. Everything that ACTUALLY HAPPENED — a payment
// landing, a trial starting, 3D going off, the live page going dark, a cash
// payment being refused — happened silently, and the only way to find out was
// to open the app and read a card. The counterpart to `adminAlerts.ts`: that
// one is "something about money needs a human", this one is "something about
// YOUR subscription just happened".
//
// THREE RULES, and every helper below keeps all three:
//
//  1. THE WRITE NEVER THROWS. Every caller is in the middle of something that
//     must finish — a webhook that owes Razorpay a 200, a sweep pass, a
//     publish a rep is standing at a table waiting on. A store failure or a
//     duplicate key is logged and dropped; the state change already happened
//     and the screens show it. This is a courtesy layer, never a step. (What
//     is NOT swallowed is a caller handing a helper a missing required field
//     — that is a programming error, `tsc` is what stops it, and hiding it
//     here would only move the bug somewhere quieter.)
//
//  2. KEYED, so a replay is one message. The paid-period activation primitive
//     is deliberately idempotent and is reached by the webhook AND the
//     reconciler AND the admin's manual VERIFY — without a key an owner would
//     get "payment received" three times for one payment. (That identifier is
//     NOT spelled out anywhere in this file on purpose: a guardrail test greps
//     `src/` for its name to pin who may call it, and a mention in a comment
//     would read as a caller.) The key goes on
//     `Notification.key`, whose unique partial index is the authority, and a
//     duplicate insert is a success with nothing written (the same mechanism
//     `promo-blocked:<productId>` uses in catalogModelPromotionService).
//
//  3. NO PII AND NO INTERNAL PROSE. These rows name amounts, dates and plan
//     names — never a phone, an email, an admin's note or a provider's
//     message. An admin's rejection note especially: it is written for us,
//     and a restaurant reading "looks fake, no receipt" would be a different
//     kind of incident.
//
// WHAT IS DELIBERATELY NOT HERE:
//   • The four countdown reminders — they live in `lifecycleSweep.ts` behind
//     the `ReminderLog` unique index, which is a per-PERIOD dedupe rather than
//     a per-EVENT one. Two mechanisms because they answer two questions.
//   • Chargebacks. `disputeService` moves ACTIVE → GRACE and the sweep's
//     GRACE_STARTED reminder then reaches the owner in the ordinary words. A
//     second message saying "your bank has opened a dispute" would land on an
//     owner who very often did not open one.
//   • SMS/WhatsApp. Stage 6 (§12). The in-app bell is the channel here, and
//     the rep's nudge is the only thing that leaves the app today.
import { Types } from 'mongoose';

import { Notification } from '@/models/Notification';
import type { BillingInterval, PlanDefinition } from '@/models/types/subscription.types';
import { formatInrPaise, formatReceiptDate } from '@/services/subscription/receiptPdf';
import { track, AnalyticsEvent } from '@/utils/analytics';

/**
 * The in-app route every one of these rows points at — the owner's
 * Subscription screen (`lib/app/routes/app_router.dart`). One constant;
 * `nudgeService` re-exports it under its own name so a rep's nudge and an
 * automatic message can never open two different screens.
 */
export const SUBSCRIPTION_ACTION_ROUTE = '/catalog/subscription';

/**
 * What just happened. The analytics dimension and the key prefix both come
 * from this, so adding a member without a `keyFor` branch is a compile error.
 */
export type OwnerSubscriptionEvent =
  | 'TRIAL_STARTED'
  | 'PLAN_ACTIVATED'
  | 'COMP_GRANTED'
  | 'PAYMENT_WINDOW_OPENED'
  | 'THREE_D_PAUSED'
  | 'PAGE_DEACTIVATED'
  | 'MANUAL_PAYMENT_SUBMITTED'
  | 'MANUAL_PAYMENT_REJECTED'
  | 'REFUND_ISSUED'
  | 'GRACE_EXTENDED'
  | 'NO_PLAN_YET';

/** `Notification.title` is capped at 80 and `message` at 500 — clip, never reject. */
function clip(value: string, max: number): string {
  return value.length <= max ? value : `${value.slice(0, max - 1)}…`;
}

function isDuplicateKey(err: unknown): boolean {
  return typeof err === 'object' && err !== null && (err as { code?: unknown }).code === 11000;
}

interface SendInput {
  event: OwnerSubscriptionEvent;
  catalogId: Types.ObjectId;
  ownerUserId: Types.ObjectId;
  /**
   * The idempotency key. ALWAYS present: there is no event here that cannot be
   * replayed by a retried webhook, a second sweep instance or an admin
   * double-press, and "this one is safe" is how a duplicate ships.
   */
  key: string;
  /** `PAYMENT_ACTIVATE` for good news, `PAYMENT_DUE` for money owed, `INFO` for neither. */
  kind: 'PAYMENT_ACTIVATE' | 'PAYMENT_DUE' | 'INFO';
  title: string;
  message: string;
  /** The CTA label. Omitted → no button (nothing for the owner to do). */
  actionLabel?: string;
  /**
   * Hidden from the feed after this instant (E44). Set it on anything that
   * carries a deadline or a date, so an owner who opens the app in March does
   * not read January's countdown as news.
   */
  expiresAt?: Date;
}

/**
 * The one write. Resolves `true` when a row was created, `false` when the key
 * already existed or the write failed — no caller branches on it today, but a
 * helper that swallowed its own outcome would be untestable.
 */
async function send(input: SendInput): Promise<boolean> {
  try {
    await Notification.create({
      key: input.key,
      kind: input.kind,
      title: clip(input.title, 80),
      message: clip(input.message, 500),
      ...(input.actionLabel
        ? { action: { label: input.actionLabel, url: SUBSCRIPTION_ACTION_ROUTE } }
        : {}),
      audienceType: 'USERS',
      audienceUserIds: [input.ownerUserId],
      ...(input.expiresAt ? { expiresAt: input.expiresAt } : {}),
      deletedAt: null,
    });
  } catch (err) {
    // The unique `key` index: this event was already announced. The common
    // case on every replay, and not a problem.
    if (isDuplicateKey(err)) return false;
    const message = err instanceof Error ? err.message : 'unknown error';
    console.warn(
      `[subscription-notify] ${input.event} for catalog ${input.catalogId.toHexString()} ` +
        `could not be written (${message})`
    );
    return false;
  }

  track(AnalyticsEvent.SUBSCRIPTION_OWNER_NOTIFIED, {
    catalog_id: input.catalogId.toHexString(),
    event: input.event,
  });
  return true;
}

/** The instant part of a key: stable for one event, different for the next. */
const stamp = (when: Date): string => String(when.getTime());

const days = (n: number): string => (n === 1 ? '1 day' : `${n} days`);

// ── Good news ────────────────────────────────────────────────────────────────

export interface TrialStartedInput {
  catalogId: Types.ObjectId;
  ownerUserId: Types.ObjectId;
  /** The trial's own end — the row's `periodEnd`. */
  endsAt: Date;
  trialDays: number;
  /** The trial's 3D cap, so the sentence promises exactly what was granted. */
  threeDDishCap: number;
}

/**
 * A rep or admin just started this restaurant's free trial — usually while
 * standing in it, which is exactly why the owner needs a copy in writing: the
 * rep leaves, and the end date leaves with them.
 */
export async function notifyTrialStarted(input: TrialStartedInput): Promise<boolean> {
  return send({
    event: 'TRIAL_STARTED',
    catalogId: input.catalogId,
    ownerUserId: input.ownerUserId,
    key: `sub-trial:${input.catalogId.toHexString()}:${stamp(input.endsAt)}`,
    kind: 'PAYMENT_ACTIVATE',
    title: 'Your free trial has started',
    message:
      `Your ${input.trialDays}-day free trial runs until ` +
      `${formatReceiptDate(input.endsAt)}, with up to ${input.threeDDishCap} 3D dishes. ` +
      'Choose a plan before then to keep your 3D menu live without a break.',
    actionLabel: 'See plans',
    expiresAt: input.endsAt,
  });
}

export interface PlanActivatedInput {
  catalogId: Types.ObjectId;
  ownerUserId: Types.ObjectId;
  /** The ledger row that bought this period — the key, and the reason it is exactly-once. */
  paymentRecordId: Types.ObjectId;
  plan: PlanDefinition;
  interval: BillingInterval;
  amountPaise: number;
  periodEnd: Date;
  /** The 3D dishes were switched back on by this payment (came out of PAUSED/CANCELLED). */
  resumedThreeD: boolean;
  /** The customer page was dark, or carrying a deadline, and this payment cleared it. */
  restoredPage: boolean;
}

/**
 * THE message this whole file was written for: "subs done, next date for
 * payment". A payment has been applied and a period is running.
 *
 * Keyed on the LEDGER ROW, not on the period's dates. The webhook, the
 * reconciler and an admin's VERIFY all converge on one message for one
 * payment, including the case the reconciler exists for — a period applied by
 * a webhook that then crashed before stamping `appliedAt`, re-applied later
 * with a fresh clock. Same payment, different `paidAt`, one message.
 */
export async function notifyPlanActivated(input: PlanActivatedInput): Promise<boolean> {
  const interval = input.interval === 'YEARLY' ? 'yearly' : 'monthly';
  const restored = input.restoredPage
    ? ' Your live menu is back on at the same QR code.'
    : input.resumedThreeD
      ? ' Your 3D menu is live again.'
      : '';
  return send({
    event: 'PLAN_ACTIVATED',
    catalogId: input.catalogId,
    ownerUserId: input.ownerUserId,
    key: `sub-activated:${input.paymentRecordId.toHexString()}`,
    kind: 'PAYMENT_ACTIVATE',
    title: 'Payment received — your plan is active',
    message:
      `${formatInrPaise(input.amountPaise)} received. Your ${input.plan.displayName} ` +
      `(${interval}) is active until ${formatReceiptDate(input.periodEnd)}, which is when ` +
      `your next payment is due.${restored}`,
    actionLabel: 'View plan',
    // The sentence names a date and calls it "next payment due"; past that
    // date the row is in grace and the message is no longer true.
    expiresAt: input.periodEnd,
  });
}

export interface CompGrantedInput {
  catalogId: Types.ObjectId;
  ownerUserId: Types.ObjectId;
  /** `periodStart` — what makes the key unique when a comp is extended twice. */
  grantedAt: Date;
  until: Date;
}

/** Door 4. No money moved, so the words must not imply any did. */
export async function notifyCompGranted(input: CompGrantedInput): Promise<boolean> {
  return send({
    event: 'COMP_GRANTED',
    catalogId: input.catalogId,
    ownerUserId: input.ownerUserId,
    key: `sub-comp:${input.catalogId.toHexString()}:${stamp(input.grantedAt)}`,
    kind: 'PAYMENT_ACTIVATE',
    title: 'Your menu is live, with our compliments',
    message:
      `Your full 3D menu is active until ${formatReceiptDate(input.until)} at no charge. ` +
      "We'll remind you before it ends so nothing goes off without warning.",
    actionLabel: 'View plan',
    expiresAt: input.until,
  });
}

export interface RefundIssuedInput {
  catalogId: Types.ObjectId;
  ownerUserId: Types.ObjectId;
  /** The REFUNDED ledger row — one refund, one message. */
  paymentRecordId: Types.ObjectId;
  amountPaise: number;
  /** A cash refund arrives by hand; a Razorpay one takes working days. */
  manual: boolean;
}

/**
 * The B3 refund (§7 rule 9): a duplicate payment given back. The period is
 * deliberately untouched by a refund, and the message says so — an owner who
 * reads "refunded" and assumes their menu just went off would be the expensive
 * misunderstanding here.
 */
export async function notifyRefundIssued(input: RefundIssuedInput): Promise<boolean> {
  const arrival = input.manual
    ? 'It has been returned by the same route it was paid.'
    : 'It usually reaches the original payment method within 5–7 working days.';
  return send({
    event: 'REFUND_ISSUED',
    catalogId: input.catalogId,
    ownerUserId: input.ownerUserId,
    key: `sub-refund:${input.paymentRecordId.toHexString()}`,
    kind: 'PAYMENT_ACTIVATE',
    title: 'A duplicate payment has been refunded',
    message:
      `${formatInrPaise(input.amountPaise)} has been refunded. ${arrival} ` +
      'Your plan and its dates are unchanged.',
    actionLabel: 'View payments',
  });
}

// ── Money owed ───────────────────────────────────────────────────────────────

export interface NoPlanYetInput {
  catalogId: Types.ObjectId;
  ownerUserId: Types.ObjectId;
}

/**
 * The one event in this file that is an ABSENCE rather than a transition: this
 * restaurant has never opted into anything — no plan, no trial, not even a
 * pending-payment window. Nothing happens to a catalog like that, so nothing
 * would ever tell its owner, and the only surface that says so today is a
 * paywall they have to walk into.
 *
 * SENT EXACTLY ONCE, EVER, and the key is the whole mechanism: the sweep's
 * fifth scan re-finds the same catalog on every pass for as long as it stays
 * planless, and the unique index is what turns that into one message rather
 * than one every ten minutes. Nothing else here is load-bearing — take the
 * key away and this becomes the worst notification in the app.
 *
 * NO `expiresAt`: it stays true until the owner acts, and the moment they do,
 * the act sends its own message.
 */
export async function notifyNoPlanYet(input: NoPlanYetInput): Promise<boolean> {
  return send({
    event: 'NO_PLAN_YET',
    catalogId: input.catalogId,
    ownerUserId: input.ownerUserId,
    key: `sub-no-plan:${input.catalogId.toHexString()}`,
    kind: 'PAYMENT_DUE',
    title: 'You have not chosen a plan yet',
    message:
      'Your restaurant is not on any plan, so your menu cannot go live. Choose one to ' +
      'publish it, get your QR code and turn on 3D — your dishes, photos and categories ' +
      'stay exactly as they are.',
    actionLabel: 'See plans',
  });
}


export interface PaymentWindowOpenedInput {
  catalogId: Types.ObjectId;
  ownerUserId: Types.ObjectId;
  /** The deadline — the row's `periodEnd`, and the day the page goes dark. */
  paymentDueAt: Date;
  windowDays: number;
}

/**
 * Requirement 2's window just opened: a rep published this restaurant before
 * anybody paid for it. The sweep's countdown reminders start from −7 d, so a
 * window longer than a week would otherwise open in complete silence — and
 * even at seven days, "your menu is live" is news that belongs at the moment
 * it becomes true, not ten minutes later in the words of a countdown.
 *
 * THE ONE SENTENCE HERE THAT MUST NOT BORROW THE GRACE VOCABULARY: what runs
 * out is the customer page, not the 3D on it (see `subscription_copy.dart`).
 */
export async function notifyPaymentWindowOpened(
  input: PaymentWindowOpenedInput
): Promise<boolean> {
  return send({
    event: 'PAYMENT_WINDOW_OPENED',
    catalogId: input.catalogId,
    ownerUserId: input.ownerUserId,
    key: `sub-window:${input.catalogId.toHexString()}:${stamp(input.paymentDueAt)}`,
    kind: 'PAYMENT_DUE',
    title: 'Your menu is live — payment due',
    message:
      `Your QR code is working now. Choose a plan within ${days(input.windowDays)}, by ` +
      `${formatReceiptDate(input.paymentDueAt)}, or the live page switches off. Nothing is ` +
      'deleted — the same QR comes straight back when you pay.',
    actionLabel: 'See plans',
    expiresAt: input.paymentDueAt,
  });
}

export interface ThreeDPausedInput {
  catalogId: Types.ObjectId;
  ownerUserId: Types.ObjectId;
  /** `pausedAt` — the instant the sweep moved the row, and the key's unique part. */
  pausedAt: Date;
}

/**
 * Grace ran out. The countdown reminders stop at the grace midpoint, so
 * without this the owner's last word from us is "3D pauses in N days" and the
 * moment it actually happened is never announced.
 *
 * No `expiresAt`: unlike a countdown this does not go stale — it stays true
 * until a payment changes it, and a payment sends its own message.
 */
export async function notifyThreeDPaused(input: ThreeDPausedInput): Promise<boolean> {
  return send({
    event: 'THREE_D_PAUSED',
    catalogId: input.catalogId,
    ownerUserId: input.ownerUserId,
    key: `sub-paused:${input.catalogId.toHexString()}:${stamp(input.pausedAt)}`,
    kind: 'PAYMENT_DUE',
    title: 'Your 3D menu is now paused',
    message:
      'No payment was received, so 3D and AR are switched off. Your photo menu is still ' +
      'live at the same QR code, and 3D comes back the moment you pay.',
    actionLabel: 'Pay now',
  });
}

export interface PageDeactivatedInput {
  catalogId: Types.ObjectId;
  ownerUserId: Types.ObjectId;
  /** `pageDeactivatedAt` — the sweep instant. */
  deactivatedAt: Date;
}

/**
 * The sharpest message in this file, for the one state where the printed QR
 * stops answering. It gets its own sentences and shares none with the pause
 * above: telling an owner whose link is dead that "your photo menu is still
 * live" is the lie they can disprove in one tap.
 */
export async function notifyPageDeactivated(input: PageDeactivatedInput): Promise<boolean> {
  return send({
    event: 'PAGE_DEACTIVATED',
    catalogId: input.catalogId,
    ownerUserId: input.ownerUserId,
    key: `sub-page-off:${input.catalogId.toHexString()}:${stamp(input.deactivatedAt)}`,
    kind: 'PAYMENT_DUE',
    title: 'Your live menu has been switched off',
    message:
      'The payment window ended, so your QR code no longer opens your menu. Every dish, ' +
      'photo and category is still here — choose a plan and the same QR code comes ' +
      'straight back on.',
    actionLabel: 'See plans',
  });
}

export interface GraceExtendedInput {
  catalogId: Types.ObjectId;
  ownerUserId: Types.ObjectId;
  graceEndsAt: Date;
  days: number;
}

/**
 * An admin gave this restaurant more time. Worth a message because the owner
 * is, by definition, watching a deadline — and the screens would otherwise
 * move it under them with no explanation.
 */
export async function notifyGraceExtended(input: GraceExtendedInput): Promise<boolean> {
  return send({
    event: 'GRACE_EXTENDED',
    catalogId: input.catalogId,
    ownerUserId: input.ownerUserId,
    key: `sub-grace-extended:${input.catalogId.toHexString()}:${stamp(input.graceEndsAt)}`,
    kind: 'PAYMENT_DUE',
    title: 'Your payment deadline has been extended',
    message:
      `We've given you ${days(input.days)} more. Your 3D menu stays on until ` +
      `${formatReceiptDate(input.graceEndsAt)} — pay before then to keep it live ` +
      'without a break.',
    actionLabel: 'Pay now',
    expiresAt: input.graceEndsAt,
  });
}

// ── Cash, in both directions ─────────────────────────────────────────────────

export interface ManualPaymentInput {
  catalogId: Types.ObjectId;
  ownerUserId: Types.ObjectId;
  /** The MANUAL ledger row — one request, one message per decision. */
  paymentRecordId: Types.ObjectId;
  amountPaise: number;
  /** `CASH` | `BANK_TRANSFER` | `UPI` | `CHEQUE`, as the ledger stores it. */
  method: string;
}

/** "Cash", "Bank transfer", "Upi", "Cheque" — the enum, said out loud. */
function methodLabel(method: string): string {
  const words = method.toLowerCase().replace(/_/g, ' ');
  return words.charAt(0).toUpperCase() + words.slice(1);
}

/**
 * Door 3, first half: a rep or admin recorded a payment taken outside the app.
 * The owner is told because this is the door with a HUMAN STEP in it — nothing
 * activates until an admin verifies, and an owner who is not told will read
 * their own unchanged status as the payment having been lost.
 */
export async function notifyManualPaymentSubmitted(input: ManualPaymentInput): Promise<boolean> {
  return send({
    event: 'MANUAL_PAYMENT_SUBMITTED',
    catalogId: input.catalogId,
    ownerUserId: input.ownerUserId,
    key: `sub-manual-submitted:${input.paymentRecordId.toHexString()}`,
    kind: 'INFO',
    title: 'Payment recorded — awaiting verification',
    message:
      `${formatInrPaise(input.amountPaise)} was recorded as ${methodLabel(input.method)}. ` +
      'Your plan starts as soon as our team confirms it — usually within a working day.',
    actionLabel: 'View payments',
  });
}

/**
 * Door 3, second half. THE ADMIN'S NOTE NEVER APPEARS HERE — it is written for
 * us, about a payment we could not find, and it is not the restaurant's to
 * read. The message says what is true (nothing was activated) and where to go
 * next, and the conversation about why happens between people.
 */
export async function notifyManualPaymentRejected(input: ManualPaymentInput): Promise<boolean> {
  return send({
    event: 'MANUAL_PAYMENT_REJECTED',
    catalogId: input.catalogId,
    ownerUserId: input.ownerUserId,
    key: `sub-manual-rejected:${input.paymentRecordId.toHexString()}`,
    kind: 'PAYMENT_DUE',
    title: 'We could not confirm that payment',
    message:
      `The ${formatInrPaise(input.amountPaise)} recorded as ${methodLabel(input.method)} ` +
      'could not be confirmed, so no plan has been started. You can pay in the app, or ' +
      'talk to us if you think this is a mistake.',
    actionLabel: 'See plans',
  });
}
