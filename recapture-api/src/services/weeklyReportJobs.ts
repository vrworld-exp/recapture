// src/services/weeklyReportJobs.ts
//
// The weekly-report sweep (more-customization Stage 9, Part C): a periodic task
// on the worker loop that, from Monday 09:30 IST onward, enqueues ONE
// WEEKLY_REPORT job per published catalog still owed last week's report.
//
// WHY A FAN-OUT OF JOBS AND NOT ONE LOOP. Each report costs five Mirage reads;
// a loop over every catalog inside one periodic tick would hold the tick for
// minutes and lose everything on one throw. As jobs, each catalog retries on
// its own, and the Job collection's unique (userId, idempotencyKey) index makes
// "the sweep ran again ten minutes later" enqueue nothing.
//
// Off unless WEEKLY_REPORTS_ENABLED — see the flag's note in config/env.ts.
import { Types } from 'mongoose';

import { env } from '@/config/env';
import { Job } from '@/models/Job';
import { WEEKLY_REPORT_JOB_TYPE } from '@/models/types/job.types';
import {
  catalogsDueForReport,
  isReportSendTime,
  lastCompletedWeekStart,
} from '@/services/weeklyReportService';

export interface WeeklyReportJobPayload {
  catalogId: string;
  /** The Monday, `YYYY-MM-DD` in Asia/Kolkata. */
  weekStart: string;
}

export const weeklyReportIdempotencyKey = (catalogId: Types.ObjectId, weekStart: string): string =>
  `weekly-report:${catalogId.toHexString()}:${weekStart}`;

function isDuplicateKey(err: unknown): boolean {
  return typeof err === 'object' && err !== null && (err as { code?: unknown }).code === 11000;
}

/** Enqueues one catalog's report job. `false` when the key already named one. */
export async function enqueueWeeklyReportJob(input: {
  catalogId: Types.ObjectId;
  ownerUserId: Types.ObjectId;
  weekStart: string;
}): Promise<boolean> {
  const payload: WeeklyReportJobPayload = {
    catalogId: input.catalogId.toHexString(),
    weekStart: input.weekStart,
  };
  try {
    await Job.create({
      userId: input.ownerUserId,
      jobType: WEEKLY_REPORT_JOB_TYPE,
      state: 'QUEUED',
      // Schema default priority: nobody is standing and waiting on a report,
      // so it never jumps a publish or a Meshy generation.
      idempotencyKey: weeklyReportIdempotencyKey(input.catalogId, input.weekStart),
      queuedAt: new Date(),
      payload,
    });
    return true;
  } catch (err) {
    if (isDuplicateKey(err)) return false;
    throw err;
  }
}

export interface WeeklyReportSweepReport {
  weekStart: string | null;
  due: number;
  enqueued: number;
}

/**
 * The periodic task body. Cheap when there is nothing to do: before Monday
 * 09:30 it returns without a query, and after it the "due" list shrinks to
 * zero as the reports land.
 */
export async function runWeeklyReportSweep(
  now: Date = new Date()
): Promise<WeeklyReportSweepReport> {
  if (!env.WEEKLY_REPORTS_ENABLED || !isReportSendTime(now)) {
    return { weekStart: null, due: 0, enqueued: 0 };
  }
  const weekStart = lastCompletedWeekStart(now);
  const due = await catalogsDueForReport(weekStart);

  let enqueued = 0;
  for (const catalog of due) {
    try {
      if (
        await enqueueWeeklyReportJob({
          catalogId: catalog._id,
          ownerUserId: catalog.userId,
          weekStart,
        })
      ) {
        enqueued += 1;
      }
    } catch (err) {
      // One bad row must not stop the rest of the fan-out.
      console.warn(
        `[weekly-report] enqueue failed for ${catalog._id.toHexString()}`,
        (err as Error).message
      );
    }
  }
  if (enqueued > 0)
    console.info(`[weekly-report] ${weekStart}: enqueued ${enqueued}/${due.length}`);
  return { weekStart, due: due.length, enqueued };
}
