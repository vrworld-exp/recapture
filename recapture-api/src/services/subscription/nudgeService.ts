// src/services/subscription/nudgeService.ts
//
// The rep's "Notify owner to pay" nudge — Door 2's one on-demand tool
// (docs/subscription/stage-04-rep-tools.md). A rep standing in a restaurant
// asks the owner, by SMS and by the in-app bell, to open the app and pay.
//
// WHAT THIS NEVER DOES (AC-7.3): read-modify-write a `CatalogSubscription` or
// a `PaymentRecord`. It reads the subscription to choose a sentence and writes
// one `Notification` row plus one stub SMS. A nudge cannot confirm, extend or
// change a payment, and the test suite hashes both collections before and
// after to prove it.
//
// RATE-LIMITED PER CATALOG, NOT PER REP, and with no admin bypass: the thing
// being protected is the owner's phone, and it does not matter who is tapping.
// The automated reminder schedule (Stage 6) is NOT here — this is the manual
// door only.
import { Types } from 'mongoose';

import { env } from '@/config/env';
import type { ICatalog } from '@/models/Catalog';
import { User } from '@/models/User';
import type { Actor, SubscriptionStatus } from '@/models/types/subscription.types';
import { sendTemplatedSms, renderSmsTemplate } from '@/providers/sms';
import { createNotification } from '@/services/notificationsService';
import { getSubscriptionSummary } from '@/services/subscription/subscriptionService';
import { track, AnalyticsEvent } from '@/utils/analytics';
import { toDisplayName } from '@/utils/catalogNames';
import { hashIdentifier } from '@/utils/otp';
import { consumeRateWindow, peekRateWindow } from '@/utils/rateLimit';

export type NudgeChannel = 'SMS' | 'IN_APP';

export type NotifyOwnerResult =
  | { outcome: 'SENT'; channels: NudgeChannel[]; nextAllowedAt: Date | null }
  | { outcome: 'RATE_LIMITED'; retryAfter: number; nextAllowedAt: Date }
  | { outcome: 'NO_PHONE' }
  | { outcome: 'NOT_NEEDED' }
  | { outcome: 'FAILED' };

/**
 * An ACTIVE owner with more than this many days left is paid up — a nudge is
 * refused so a rep cannot lean on a restaurant that owes nothing.
 */
const NOT_NEEDED_ABOVE_DAYS = 7;

/** The in-app route the bell's tap handler pushes (lib/app/routes/app_router.dart). */
export const NUDGE_ACTION_ROUTE = '/catalog/subscription';

const rateKey = (catalogId: Types.ObjectId) => `sub-nudge:${catalogId.toHexString()}`;

/**
 * The clause that goes into "{restaurant}: your Mirage Menu {what} — open the
 * ReCapture app…", chosen from the status. Null means there is nothing to
 * pay for: ACTIVE with more than a week left, or a comp.
 */
export function nudgeClauseFor(
  status: SubscriptionStatus | 'NONE',
  daysLeft: number | null
): string | null {
  const days = (n: number) => `${n} day${n === 1 ? '' : 's'}`;
  switch (status) {
    case 'TRIAL':
      return `trial ends in ${days(daysLeft ?? 0)}`;
    // The sharpest clause there is, because it is the only one where the
    // customer page itself is what runs out. The rep's nudge is the main way
    // this ever reaches an owner who has not opened the app.
    case 'PENDING_PAYMENT':
      return `live page switches off in ${days(daysLeft ?? 0)} unless it is paid for`;
    case 'ACTIVE':
      if (daysLeft !== null && daysLeft > NOT_NEEDED_ABOVE_DAYS) return null;
      return `plan expires in ${days(daysLeft ?? 0)}`;
    case 'GRACE':
      return 'payment is overdue';
    case 'PAUSED':
      return '3D menu is paused';
    case 'CANCELLED':
    case 'NONE':
      return 'has no plan yet';
    case 'COMPED':
      return null;
  }
}

/**
 * When the NEXT nudge on this catalog would be accepted: null when one is
 * allowed right now, otherwise the instant the window lapses. Read-only — the
 * GET route peeks so the button can show its cooldown before a tap.
 */
export async function nudgeNextAllowedAt(
  catalogId: Types.ObjectId,
  now: Date = new Date()
): Promise<Date | null> {
  const peek = await peekRateWindow(
    rateKey(catalogId),
    env.SUBSCRIPTION_NUDGE_MAX_PER_WINDOW,
    env.SUBSCRIPTION_NUDGE_WINDOW_SECONDS,
    now.getTime()
  );
  return peek.limited ? peek.resetsAt : null;
}

/**
 * Sends the nudge: one templated SMS through the provider seam and one
 * in-app notification for the owner, in parallel. The in-app row is the one
 * that must land — the SMS stub is what runs today, so its failure is logged
 * and the request still succeeds with `channels: ['IN_APP']`. Both failing is
 * FAILED (the route's 502).
 *
 * The window is consumed FIRST, before any check that could refuse (the
 * order the stage doc fixes). A refused attempt therefore costs a slot — the
 * price of never letting a retry loop reach the owner's phone, and cheap at
 * two a day.
 */
export async function notifyOwnerToPay(
  catalog: ICatalog,
  actor: Actor,
  now: Date = new Date()
): Promise<NotifyOwnerResult> {
  const catalogId = catalog._id as Types.ObjectId;
  const catalogIdHex = catalogId.toHexString();
  const refused = (reason: 'RATE_LIMITED' | 'NO_PHONE' | 'NOT_NEEDED' | 'FAILED') =>
    track(AnalyticsEvent.SUBSCRIPTION_NUDGE_REFUSED, { catalog_id: catalogIdHex, reason });

  const rate = await consumeRateWindow(
    rateKey(catalogId),
    env.SUBSCRIPTION_NUDGE_MAX_PER_WINDOW,
    env.SUBSCRIPTION_NUDGE_WINDOW_SECONDS,
    now.getTime()
  );
  if (rate.limited) {
    refused('RATE_LIMITED');
    return {
      outcome: 'RATE_LIMITED',
      retryAfter: rate.retryAfter,
      nextAllowedAt: new Date(now.getTime() + rate.retryAfter * 1000),
    };
  }

  const owner = await User.findById(catalog.userId).select({ phone: 1 }).lean().exec();
  const phone = owner?.phone?.trim();
  if (!owner || !phone) {
    refused('NO_PHONE');
    return { outcome: 'NO_PHONE' };
  }

  const summary = await getSubscriptionSummary(catalogId, catalog.userId, now);
  const status: SubscriptionStatus | 'NONE' = summary?.status ?? 'NONE';
  const clause = nudgeClauseFor(status, summary?.daysLeft ?? null);
  if (clause === null) {
    refused('NOT_NEEDED');
    return { outcome: 'NOT_NEEDED' };
  }

  const restaurant = catalog.businessName?.trim() || toDisplayName(catalog.name);
  const vars = { restaurant, what: clause };
  const sentence = renderSmsTemplate('SUBSCRIPTION_PAY_NUDGE', vars);

  const [sms, inApp] = await Promise.allSettled([
    sendTemplatedSms(phone, 'SUBSCRIPTION_PAY_NUDGE', vars),
    createNotification(
      {
        kind: 'PAYMENT_DUE',
        title: 'Keep your 3D menu live',
        message: sentence,
        action: { label: 'Pay now', url: NUDGE_ACTION_ROUTE },
        audience: { type: 'USERS', userIds: [catalog.userId.toHexString()] },
      },
      actor.userId.toHexString()
    ),
  ]);

  const channels: NudgeChannel[] = [];
  if (sms.status === 'fulfilled') channels.push('SMS');
  else console.warn('[nudge] SMS dispatch failed; in-app only', { catalogId: catalogIdHex });
  if (inApp.status === 'fulfilled') channels.push('IN_APP');
  else console.warn('[nudge] in-app notification failed', { catalogId: catalogIdHex });

  if (channels.length === 0) {
    refused('FAILED');
    return { outcome: 'FAILED' };
  }

  track(AnalyticsEvent.SUBSCRIPTION_NUDGE_SENT, {
    catalog_id: catalogIdHex,
    actor_id_hash: hashIdentifier(actor.userId.toHexString()),
    owner_id_hash: hashIdentifier(catalog.userId.toHexString()),
    subscription_status: status,
    channels,
  });

  return { outcome: 'SENT', channels, nextAllowedAt: await nudgeNextAllowedAt(catalogId, now) };
}
