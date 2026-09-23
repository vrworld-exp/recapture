// src/services/subscription/lifecycleSweep.ts
//
// The lifecycle sweep (RECAPTURE_SUBSCRIPTION_PLAN.md §6, §12 Stage 5): run by
// the worker loop every SUBSCRIPTION_SWEEP_INTERVAL_MS. Four scans, in order:
//   1. TRIAL | ACTIVE | COMPED whose `periodEnd` has passed → GRACE, with
//      `graceEndsAt = periodEnd + graceDays` derived from EACH row's own
//      `periodEnd` (a pipeline update, AC-3.1) and `graceFrom` remembering
//      which state it came from (E16).
//   2. GRACE whose `graceEndsAt` has passed → PAUSED, one conditional
//      findOneAndUpdate per row, and ONLY a row this sweep actually moved
//      gets a SUBSCRIPTION_AR_ENTITLEMENT job. A row that changed under us
//      (the owner paid between the find and the update) matches nothing and
//      enqueues nothing (D4).
//   3. PENDING_PAYMENT whose `periodEnd` has passed → PAUSED with
//      `pageDeactivatedAt` set, one conditional findOneAndUpdate per row, and a
//      SUBSCRIPTION_PAGE_STATE job that takes the CUSTOMER PAGE down plus a
//      SUBSCRIPTION_AR_ENTITLEMENT job that takes 3D with it (requirement 2).
//      This is the ONE scan that can make a live link go dark, and it can only
//      ever reach a restaurant that never paid a rupee — see the note there.
//   4. In-app reminders at −7 d, −1 d, on GRACE and at grace midpoint (E14),
//      deduped through ReminderLog so two instances send one.
//   5. (nothing else) — the sweep never reads `activePublishRunId`, never
//      touches `Catalog.status`, `publishedRevision` or a Mirage item (D5,
//      AC-4.1). Pausing is a flag on Mirage's restaurant, written by the job.
//
// CLOCK RULE (D3): every comparison is `$lte: now`. The sweep can only ever be
// LATE — an instance that slept for an hour pauses an hour late, never a
// minute early. Nothing here extrapolates.
import { Types } from 'mongoose';

import { CatalogSubscription } from '@/models/CatalogSubscription';
import { Notification } from '@/models/Notification';
import { ReminderLog, type ReminderMilestone } from '@/models/ReminderLog';
import type { SubscriptionStatus } from '@/models/types/subscription.types';
import { enqueueArEntitlementJob } from '@/services/subscription/arEntitlementJobs';
import { enqueuePageStateJob } from '@/services/subscription/pageStateJobs';
import { getPlanCatalog } from '@/services/subscription/planCatalogService';
import { track, AnalyticsEvent } from '@/utils/analytics';

const DAY_MS = 86_400_000;

/**
 * The statuses a period runs under — the ones that can lapse into GRACE.
 *
 * PENDING_PAYMENT IS NOT ONE OF THEM, deliberately. Grace is the courtesy a
 * restaurant that has paid gets while the next payment is chased; a window that
 * was never paid for has no next payment to chase and its `periodEnd` IS its
 * deadline. Adding it here would silently double the free ride to
 * `pendingPaymentDays + graceDays` and end in the wrong place (3D off, page up)
 * instead of the page going dark. Scan 3 owns it end to end.
 */
const LAPSABLE: readonly SubscriptionStatus[] = ['TRIAL', 'ACTIVE', 'COMPED'];

export interface SweepReport {
  toGrace: number;
  toPaused: number;
  /** Pause jobs enqueued — equals `toPaused` unless an enqueue threw. */
  pausesEnqueued: number;
  /**
   * Pending-payment windows this pass expired — live links switched off for
   * non-payment. Its own counter and not folded into `toPaused`, because one
   * means "a plan lapsed" and the other means "a customer page went dark", and
   * a runbook watching for the second must not have it hidden inside the first.
   */
  toPageOff: number;
  /** Page-off jobs enqueued — equals `toPageOff` unless an enqueue threw. */
  pageOffsEnqueued: number;
  /**
   * Always 0 here: a resume is enqueued by the payment that causes it (the
   * activation primitive in subscriptionService), never by the sweep. Reported
   * so the log line reads as a complete account of what the sweep may do.
   */
  resumesEnqueued: 0;
  remindersSent: number;
  durationMs: number;
}

interface LapsedRow {
  _id: Types.ObjectId;
  catalogId: Types.ObjectId;
  status: SubscriptionStatus;
}

// ── 1. → GRACE ───────────────────────────────────────────────────────────────

/**
 * Find first, then update BY ID with the same guard: the count and the
 * per-row events agree, and a row that moved between the two queries is
 * simply not in the update's match.
 */
async function sweepToGrace(now: Date, graceDays: number): Promise<number> {
  const lapsed = await CatalogSubscription.find({
    status: { $in: LAPSABLE },
    periodEnd: { $lte: now },
  })
    .select({ _id: 1, catalogId: 1, status: 1 })
    .lean<LapsedRow[]>()
    .exec();
  if (lapsed.length === 0) return 0;

  const result = await CatalogSubscription.updateMany(
    { _id: { $in: lapsed.map((r) => r._id) }, status: { $in: LAPSABLE }, periodEnd: { $lte: now } },
    [
      {
        $set: {
          graceFrom: '$status',
          status: 'GRACE',
          graceEndsAt: { $add: ['$periodEnd', graceDays * DAY_MS] },
        },
      },
    ]
  ).exec();

  // The guard can only shrink the set, never change which rows were eligible
  // — and a shrunken set means a row paid mid-sweep, which is not our event.
  if (result.modifiedCount === lapsed.length) {
    for (const row of lapsed) {
      track(AnalyticsEvent.SUBSCRIPTION_STATE_CHANGED, {
        catalog_id: row.catalogId.toHexString(),
        from: row.status,
        to: 'GRACE',
        by: 'SWEEP',
      });
    }
  } else {
    // Re-read which of them actually moved, so the events stay honest. A row
    // that paid in between is ACTIVE again (the payment clears `graceFrom`);
    // one that moved is GRACE — or already PAUSED, if the pause scan of a
    // concurrent sweep got to it first.
    const moved = await CatalogSubscription.find({
      _id: { $in: lapsed.map((r) => r._id) },
      status: { $in: ['GRACE', 'PAUSED'] },
      graceFrom: { $in: LAPSABLE },
    })
      .select({ _id: 1, catalogId: 1, graceFrom: 1 })
      .lean<{ _id: Types.ObjectId; catalogId: Types.ObjectId; graceFrom: SubscriptionStatus }[]>()
      .exec();
    for (const row of moved) {
      track(AnalyticsEvent.SUBSCRIPTION_STATE_CHANGED, {
        catalog_id: row.catalogId.toHexString(),
        from: row.graceFrom,
        to: 'GRACE',
        by: 'SWEEP',
      });
    }
  }
  return result.modifiedCount;
}

// ── 2. → PAUSED ──────────────────────────────────────────────────────────────

async function sweepToPaused(now: Date): Promise<{ toPaused: number; pausesEnqueued: number }> {
  const due = await CatalogSubscription.find({ status: 'GRACE', graceEndsAt: { $lte: now } })
    .select({ _id: 1 })
    .lean<{ _id: Types.ObjectId }[]>()
    .exec();

  let toPaused = 0;
  let pausesEnqueued = 0;
  for (const { _id } of due) {
    // THE D4 GUARD. The filter repeats the eligibility, so a row the owner
    // paid a second ago (now ACTIVE) returns null and nothing is enqueued.
    const paused = await CatalogSubscription.findOneAndUpdate(
      { _id, status: 'GRACE', graceEndsAt: { $lte: now } },
      { $set: { status: 'PAUSED', pausedAt: now } },
      { new: true }
    )
      .select({ catalogId: 1, userId: 1, updatedAt: 1 })
      .lean<{ catalogId: Types.ObjectId; userId: Types.ObjectId; updatedAt: Date }>()
      .exec();
    if (!paused) continue;
    toPaused += 1;

    track(AnalyticsEvent.SUBSCRIPTION_STATE_CHANGED, {
      catalog_id: paused.catalogId.toHexString(),
      from: 'GRACE',
      to: 'PAUSED',
      by: 'SWEEP',
    });

    try {
      await enqueueArEntitlementJob({
        catalogId: paused.catalogId,
        ownerUserId: paused.userId,
        enabled: false,
        reason: 'GRACE_EXPIRED',
        dedupeAt: paused.updatedAt,
      });
      pausesEnqueued += 1;
    } catch (err) {
      // The row IS paused (the gate already refuses 3D publishes); only the
      // Mirage flag is late. The admin's resync covers it, and the next
      // payment's resume job would overwrite it anyway.
      console.error(
        `[subscription-sweep] pause job enqueue failed for catalog ${paused.catalogId.toHexString()}`,
        err
      );
    }
  }
  return { toPaused, pausesEnqueued };
}

// ── 3. PENDING_PAYMENT → page off ────────────────────────────────────────────

/**
 * The scan requirement 2 turns on: a rep/staff publish that nobody paid for has
 * reached its deadline, so the CUSTOMER PAGE is switched off.
 *
 * THE ONE PLACE A LIVE LINK DIES FOR NON-PAYMENT, and it is reachable only from
 * `status: 'PENDING_PAYMENT'` — a status only `startPendingPayment` writes, and
 * only for an owner with no payment in their history. A restaurant that ever
 * paid cannot be in this scan, which is how AC-4's promise ("your photo menu
 * stays live at the printed QR") survives this feature intact.
 *
 * The row lands on PAUSED, not on a status of its own: from here on it behaves
 * exactly like any other unentitled row — the gate refuses 3D publishes, the
 * copy says what is off, a payment resumes it. What tells it apart is
 * `pageDeactivatedAt`, which is what an activation reads to know it has a page
 * to turn back ON as well as 3D.
 *
 * TWO JOBS, both best-effort and both idempotent on the row's `updatedAt`:
 * the page-state job (`isPublished: false`) and the entitlement job
 * (`enabled: false`). They are separate because their Mirage bodies are
 * separate, and a failure of either leaves the page late in the safe direction —
 * still up — with the admin resync as the backstop.
 */
async function sweepToPageOff(
  now: Date
): Promise<{ toPageOff: number; pageOffsEnqueued: number }> {
  const due = await CatalogSubscription.find({
    status: 'PENDING_PAYMENT',
    periodEnd: { $lte: now },
  })
    .select({ _id: 1 })
    .lean<{ _id: Types.ObjectId }[]>()
    .exec();

  let toPageOff = 0;
  let pageOffsEnqueued = 0;
  for (const { _id } of due) {
    // THE D4 GUARD, and here it is the one that matters most: a row the owner
    // paid a second ago is no longer PENDING_PAYMENT, returns null, and nothing
    // is enqueued — so a stale sweep can never take a paying restaurant's page
    // down. The processor re-checks the same thing again before it writes.
    const closed = await CatalogSubscription.findOneAndUpdate(
      { _id, status: 'PENDING_PAYMENT', periodEnd: { $lte: now } },
      { $set: { status: 'PAUSED', pausedAt: now, pageDeactivatedAt: now } },
      { new: true }
    )
      .select({ catalogId: 1, userId: 1, periodEnd: 1, updatedAt: 1 })
      .lean<{
        catalogId: Types.ObjectId;
        userId: Types.ObjectId;
        periodEnd: Date;
        updatedAt: Date;
      }>()
      .exec();
    if (!closed) continue;
    toPageOff += 1;

    track(AnalyticsEvent.SUBSCRIPTION_PENDING_PAYMENT_EXPIRED, {
      catalog_id: closed.catalogId.toHexString(),
    });
    track(AnalyticsEvent.SUBSCRIPTION_STATE_CHANGED, {
      catalog_id: closed.catalogId.toHexString(),
      from: 'PENDING_PAYMENT',
      to: 'PAUSED',
      by: 'SWEEP',
    });

    try {
      await enqueuePageStateJob({
        catalogId: closed.catalogId,
        ownerUserId: closed.userId,
        isPublished: false,
        // Kept rather than cleared: the Mirage side still wants to say WHAT it
        // is waiting for, and the processor re-derives it from the row anyway.
        paymentDueAt: closed.periodEnd,
        reason: 'PENDING_PAYMENT_EXPIRED',
        dedupeAt: closed.updatedAt,
      });
      pageOffsEnqueued += 1;
    } catch (err) {
      // The row IS closed (the gate already refuses 3D publishes); only the
      // Mirage write is late, which means the page is still up. The admin
      // resync covers it, and a payment would overwrite it anyway.
      console.error(
        `[subscription-sweep] page-off job enqueue failed for catalog ${closed.catalogId.toHexString()}`,
        err
      );
    }

    // 3D goes with it. A separate job because it is a separate Mirage field
    // with a separate contract (see pageStateJobs.ts); losing this one only
    // means a dark page's items keep an `arEnabled` nobody can see.
    try {
      await enqueueArEntitlementJob({
        catalogId: closed.catalogId,
        ownerUserId: closed.userId,
        enabled: false,
        reason: 'GRACE_EXPIRED',
        dedupeAt: closed.updatedAt,
      });
    } catch (err) {
      console.error(
        `[subscription-sweep] entitlement job enqueue failed for expired window ` +
          `${closed.catalogId.toHexString()}`,
        err
      );
    }
  }
  return { toPageOff, pageOffsEnqueued };
}

// ── 4. Reminders ─────────────────────────────────────────────────────────────

interface ReminderRow {
  catalogId: Types.ObjectId;
  userId: Types.ObjectId;
  status: SubscriptionStatus;
  periodEnd: Date;
  graceEndsAt?: Date;
  graceFrom?: SubscriptionStatus;
}

function periodNoun(status: SubscriptionStatus, graceFrom?: SubscriptionStatus): string {
  switch (graceFrom ?? status) {
    case 'TRIAL':
      return 'free trial';
    case 'COMPED':
      return 'complimentary period';
    default:
      return 'plan';
  }
}

/** The four sentences. Whole days, ceil'd like the DTO's `daysLeft` (D6). */
function reminderCopy(
  milestone: ReminderMilestone,
  row: ReminderRow,
  now: Date
): { title: string; message: string } {
  const noun = periodNoun(row.status, row.graceFrom);
  const daysToPeriodEnd = Math.max(0, Math.ceil((row.periodEnd.getTime() - now.getTime()) / DAY_MS));
  const graceEnd = row.graceEndsAt ?? row.periodEnd;
  const daysToGraceEnd = Math.max(0, Math.ceil((graceEnd.getTime() - now.getTime()) / DAY_MS));
  const days = (n: number): string => (n === 1 ? '1 day' : `${n} days`);

  // A pending-payment window's consequence is not the one every other sentence
  // here describes. "Your 3D menu pauses" would be a lie about a page that is
  // going to stop answering altogether, and it is the lie most likely to be
  // believed — so this status gets its own two sentences and shares none.
  if (row.status === 'PENDING_PAYMENT') {
    return {
      title: `Your live menu switches off in ${days(daysToPeriodEnd)}`,
      message:
        'Your menu is live, but it has not been paid for yet. Choose a plan to keep the ' +
        'QR code working — nothing is deleted, and it comes straight back when you pay.',
    };
  }

  switch (milestone) {
    case 'T_MINUS_7D':
    case 'T_MINUS_1D':
      return {
        title: `Your ${noun} ends in ${days(daysToPeriodEnd)}`,
        message:
          noun === 'plan'
            ? 'Renew to keep your 3D menu live without a break.'
            : 'Choose a plan to keep your 3D menu live without a break.',
      };
    case 'GRACE_STARTED':
      return {
        title:
          noun === 'plan' ? 'Payment overdue — 3D menu pauses soon' : `Your ${noun} has ended`,
        message:
          `Your 3D menu pauses in ${days(daysToGraceEnd)} unless a plan is active. ` +
          'Your photo menu stays live either way.',
      };
    case 'GRACE_MIDPOINT':
      return {
        title: `3D menu pauses in ${days(daysToGraceEnd)}`,
        message:
          'Pay now to keep 3D live. If it pauses, your photo menu stays up at the same QR ' +
          'and 3D comes back the moment you pay.',
      };
  }
}

/**
 * Which milestone, if any, a row is due for RIGHT NOW. Windows do not
 * overlap so a row that lapsed while the worker slept gets the latest one,
 * not four at once (a first sweep after a long sleep must not stack them).
 */
function dueMilestone(row: ReminderRow, now: Date): ReminderMilestone | null {
  const t = now.getTime();
  const end = row.periodEnd.getTime();
  // PENDING_PAYMENT borrows the two countdown milestones and never the grace
  // ones: there is no grace behind it. With the default seven-day window the
  // -7d milestone fires on the day it opens (the rep is often still there to
  // explain it) and the -1d one the day before the page goes dark.
  if (LAPSABLE.includes(row.status) || row.status === 'PENDING_PAYMENT') {
    if (t >= end - DAY_MS && t < end) return 'T_MINUS_1D';
    if (t >= end - 7 * DAY_MS && t < end - DAY_MS) return 'T_MINUS_7D';
    return null;
  }
  if (row.status === 'GRACE') {
    const graceEnd = (row.graceEndsAt ?? row.periodEnd).getTime();
    if (t >= graceEnd) return null; // the pause scan owns it now
    const midpoint = end + (graceEnd - end) / 2;
    return t >= midpoint ? 'GRACE_MIDPOINT' : 'GRACE_STARTED';
  }
  return null;
}

function isDuplicateKey(err: unknown): boolean {
  return (
    typeof err === 'object' &&
    err !== null &&
    'code' in err &&
    (err as { code?: unknown }).code === 11000
  );
}

async function sweepReminders(now: Date, graceDays: number): Promise<number> {
  // Everything that could be due: lapsable rows ending within a week, and
  // every GRACE row. Two index walks, no full scan.
  const rows = await CatalogSubscription.find({
    $or: [
      { status: { $in: LAPSABLE }, periodEnd: { $lte: new Date(now.getTime() + 7 * DAY_MS) } },
      // The same window for a pending-payment row. It rides the same
      // `{ status, periodEnd }` index and the same ReminderLog dedupe, so a
      // window whose deadline is inside the week gets one notification per
      // milestone however often the sweep runs.
      {
        status: 'PENDING_PAYMENT',
        periodEnd: { $lte: new Date(now.getTime() + 7 * DAY_MS) },
      },
      { status: 'GRACE' },
    ],
  })
    .select({ catalogId: 1, userId: 1, status: 1, periodEnd: 1, graceEndsAt: 1, graceFrom: 1 })
    .lean<ReminderRow[]>()
    .exec();

  let sent = 0;
  for (const row of rows) {
    const milestone = dueMilestone(row, now);
    if (!milestone) continue;

    // Reserve the log row FIRST; the unique index is the authority. A loser
    // (another instance, or the same milestone sent on an earlier sweep) gets
    // E11000 and sends nothing.
    let logId: Types.ObjectId;
    try {
      const reserved = await ReminderLog.create({
        catalogId: row.catalogId,
        milestone,
        periodEnd: row.periodEnd,
        channel: 'IN_APP',
        sentAt: now,
      });
      logId = reserved._id as Types.ObjectId;
    } catch (err) {
      if (isDuplicateKey(err)) continue;
      throw err;
    }

    try {
      const { title, message } = reminderCopy(milestone, row, now);
      await Notification.create({
        kind: 'PAYMENT_DUE',
        title,
        message,
        action: { label: 'View plans', url: '/catalog/subscription' },
        audienceType: 'USERS',
        audienceUserIds: [row.userId],
        // E44: an owner who first opens the app months later must not find
        // four stale countdowns. Everything here is moot once grace ends — and
        // a pending-payment window has no grace behind it, so its reminders
        // expire at the deadline itself.
        expiresAt:
          row.status === 'PENDING_PAYMENT'
            ? row.periodEnd
            : (row.graceEndsAt ?? new Date(row.periodEnd.getTime() + graceDays * DAY_MS)),
        deletedAt: null,
      });
      sent += 1;
    } catch (err) {
      // Give the reservation back so the next sweep tries again.
      await ReminderLog.deleteOne({ _id: logId }).exec().catch(() => undefined);
      throw err;
    }
  }
  return sent;
}

// ── The sweep ────────────────────────────────────────────────────────────────

/**
 * One pass. Idempotent under concurrent runs: the GRACE update and the PAUSED
 * update are both guarded on the state they leave, the pause job's key is
 * derived from the row's own `updatedAt`, and the reminders reserve a unique
 * row before sending. Two workers running this at the same instant move each
 * row once and enqueue each job once.
 *
 * Throws only on a store failure; the worker's periodic-task wrapper logs it
 * and the loop goes on.
 */
export async function runSubscriptionSweep(now: Date = new Date()): Promise<SweepReport> {
  const startedAt = Date.now();
  const { graceDays } = await getPlanCatalog();

  const toGrace = await sweepToGrace(now, graceDays);
  const { toPaused, pausesEnqueued } = await sweepToPaused(now);
  // AFTER the two above and before the reminders: a window that expires this
  // pass should not also be reminded about in the same pass, and `dueMilestone`
  // reads the status this scan has already changed.
  const { toPageOff, pageOffsEnqueued } = await sweepToPageOff(now);
  const remindersSent = await sweepReminders(now, graceDays);

  const durationMs = Date.now() - startedAt;
  track(AnalyticsEvent.SUBSCRIPTION_SWEEP_RAN, {
    to_grace: toGrace,
    to_paused: toPaused,
    to_page_off: toPageOff,
    duration_ms: durationMs,
  });
  console.log(
    `[subscription-sweep] to_grace=${toGrace} to_paused=${toPaused} ` +
      `to_page_off=${toPageOff} pauses_enqueued=${pausesEnqueued} ` +
      `page_offs_enqueued=${pageOffsEnqueued} reminders_sent=${remindersSent} ` +
      `duration_ms=${durationMs}`
  );

  return {
    toGrace,
    toPaused,
    pausesEnqueued,
    toPageOff,
    pageOffsEnqueued,
    resumesEnqueued: 0,
    remindersSent,
    durationMs,
  };
}
