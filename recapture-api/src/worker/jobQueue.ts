// src/worker/jobQueue.ts
//
// DB-level job state transitions for the background worker — claim, mark,
// retry, depth. NO processing logic here: this file is the only module the
// planned BullMQ migration replaces (keep the exported signatures stable).
//
// CORRECTNESS CORE: claimNextJob is ONE conditional findOneAndUpdate — the
// same no-transactions atomicity pattern the rest of this codebase uses
// (AGENTS.md §Data layer). Multiple worker instances polling simultaneously
// cannot double-claim: exactly one update matches-and-wins, the rest get null
// and sleep. Never split it into find + update.
import { Types } from 'mongoose';
import { Job } from '@/models/Job';
import { DEFAULT_JOB_TYPE, type WorkerJob } from '@/worker/workerTypes';

// Retry backoff: 1min, 2min, 4min, … doubling per attempt, capped at 30min.
// Deliberately hardcoded (not env) — a queue-shape constant, not an ops tunable.
const RETRY_BASE_DELAY_MS = 60_000;
const RETRY_MAX_DELAY_MS = 1_800_000;

/** Error code stored on the Job's `error` sub-doc when attempts run out. */
export const PROCESSING_FAILED_CODE = 'PROCESSING_FAILED';

/**
 * Atomically claims the next available job for `workerId`. Eligible work, in
 * one query:
 *   1. QUEUED jobs whose retry window (nextRetryAt) is open — null matches
 *      both never-failed jobs and pre-worker documents missing the field;
 *   2. stale CLAIMED/PROCESSING jobs whose lease (`claimedAt`) is older than
 *      `claimTimeoutMs` — crash recovery: a kill -9/OOM'd worker's job is
 *      re-claimed here on a later poll, by any instance.
 *
 * Ordering: priority (desc), then oldest retry window, then FIFO — the exact
 * shape of the {state, priority, nextRetryAt, createdAt} index on Job.
 */
export async function claimNextJob(
  workerId: string,
  claimTimeoutMs: number
): Promise<WorkerJob | null> {
  const now = new Date();
  const staleThreshold = new Date(now.getTime() - claimTimeoutMs);

  return Job.findOneAndUpdate(
    {
      $or: [
        {
          state: 'QUEUED',
          $or: [{ nextRetryAt: null }, { nextRetryAt: { $lte: now } }],
        },
        {
          state: { $in: ['CLAIMED', 'PROCESSING'] },
          claimedAt: { $lte: staleThreshold },
        },
      ],
    },
    {
      $set: { state: 'CLAIMED', claimedAt: now, claimedBy: workerId },
    },
    {
      sort: { priority: -1, nextRetryAt: 1, createdAt: 1 },
      new: true,
    }
  )
    .lean<WorkerJob>()
    .exec();
}

export async function markProcessing(jobId: Types.ObjectId): Promise<void> {
  await Job.findByIdAndUpdate(jobId, {
    $set: { state: 'PROCESSING', startedAt: new Date() },
  }).exec();
}

export async function markCompleted(
  jobId: Types.ObjectId,
  result: Record<string, unknown>
): Promise<void> {
  await Job.findByIdAndUpdate(jobId, {
    $set: {
      state: 'COMPLETED',
      completedAt: new Date(),
      result,
      lastError: null,
      nextRetryAt: null,
    },
  }).exec();
}

/**
 * Records a failed attempt. `attempts` is the NEW total (caller passes
 * previous + 1; an explicit $set, not $inc, so a retried write is idempotent).
 * Below maxAttempts the job re-enters the queue with an exponential-backoff
 * `nextRetryAt`; exhausted, it goes terminally FAILED and — per the Job
 * model's documented contract — the structured `error` sub-doc is populated
 * for the client's Processing Failed surface.
 */
export async function markFailed(
  jobId: Types.ObjectId,
  error: Error,
  attempts: number,
  maxAttempts: number,
  errorCode: string = PROCESSING_FAILED_CODE
): Promise<void> {
  const exhausted = attempts >= maxAttempts;
  const retryDelayMs = Math.min(
    RETRY_BASE_DELAY_MS * 2 ** Math.max(0, attempts - 1),
    RETRY_MAX_DELAY_MS
  );

  await Job.findByIdAndUpdate(jobId, {
    $set: {
      state: exhausted ? 'FAILED' : 'QUEUED',
      attempts,
      lastError: error.message,
      claimedAt: null,
      claimedBy: null,
      nextRetryAt: exhausted ? null : new Date(Date.now() + retryDelayMs),
      ...(exhausted ? { error: { code: errorCode, message: error.message } } : {}),
    },
  }).exec();
}

/** Job counts by state — heartbeat/ops visibility (backpressure shows here). */
export async function getQueueDepth(): Promise<Record<string, number>> {
  const counts = await Job.aggregate<{ _id: string; count: number }>([
    { $group: { _id: '$state', count: { $sum: 1 } } },
  ]).exec();
  return Object.fromEntries(counts.map((c) => [c._id, c.count]));
}

/** jobType with the pre-worker-schema fallback applied. */
export function jobTypeOf(job: WorkerJob): string {
  return job.jobType ?? DEFAULT_JOB_TYPE;
}
