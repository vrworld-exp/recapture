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
//   3. In-app reminders at −7 d, −1 d, on GRACE and at grace midpoint (E14),
//      deduped through ReminderLog so two instances send one.
//   4. (nothing else) — the sweep never reads `activePublishRunId`, never
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
import { getPlanCatalog } from '@/services/subscription/planCatalogService';
import { track, AnalyticsEvent } from '@/utils/analytics';

const DAY_MS = 86_400_000;

/** The statuses a period runs under — the ones that can lapse into GRACE. */
const LAPSABLE: readonly SubscriptionStatus[] = ['TRIAL', 'ACTIVE', 'COMPED'];

export interface SweepReport {
  toGrace: number;
  toPaused: number;
  /** Pause jobs enqueued — equals `toPaused` unless an enqueue threw. */
  pausesEnqueued: number;
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

// ── 3. Reminders ─────────────────────────────────────────────────────────────

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
  if (LAPSABLE.includes(row.status)) {
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
        // four stale countdowns. Everything here is moot once grace ends.
        expiresAt: row.graceEndsAt ?? new Date(row.periodEnd.getTime() + graceDays * DAY_MS),
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
  const remindersSent = await sweepReminders(now, graceDays);

  const durationMs = Date.now() - startedAt;
  track(AnalyticsEvent.SUBSCRIPTION_SWEEP_RAN, {
    to_grace: toGrace,
    to_paused: toPaused,
    duration_ms: durationMs,
  });
  console.log(
    `[subscription-sweep] to_grace=${toGrace} to_paused=${toPaused} ` +
      `pauses_enqueued=${pausesEnqueued} reminders_sent=${remindersSent} duration_ms=${durationMs}`
  );

  return { toGrace, toPaused, pausesEnqueued, resumesEnqueued: 0, remindersSent, durationMs };
}
