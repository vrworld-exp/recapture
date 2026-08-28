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
import type { ExecutableStage } from '@/models/types/job.types';
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
          // Every state a live pipeline run can sit in — a worker can die
          // mid-TEXTURING/OPTIMIZING just as it can mid-PROCESSING. The
          // re-claimer resumes from the job's durable stageProgress pointer.
          state: { $in: ['CLAIMED', 'PROCESSING', 'TEXTURING', 'OPTIMIZING'] },
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

/**
 * CLAIMED → PROCESSING for a claim this worker still holds. Returns false —
 * and the caller must stop touching the job — when the fence lost: the job
 * was canceled, or its lease was stolen, between the claim and this write.
 */
export async function markProcessing(jobId: Types.ObjectId, claimedBy: string): Promise<boolean> {
  const res = await Job.updateOne(
    { _id: jobId, claimedBy, state: 'CLAIMED' },
    { $set: { state: 'PROCESSING', startedAt: new Date() } }
  ).exec();
  return res.matchedCount > 0;
}

/**
 * The terminal COMPLETED flip — one atomic write closing the pipeline:
 * state, completedAt, result, and the stageProgress pointer's COMPLETED/100
 * stamp. Fenced on claimedBy + non-terminal state, so it can never resurrect
 * a job that was CANCELED (or stolen and finished by another worker) while
 * the processor was returning. A lost fence is a silent no-op (the fence
 * winner's outcome stands); returns whether the write landed.
 */
export async function markCompleted(
  jobId: Types.ObjectId,
  result: Record<string, unknown>,
  claimedBy: string
): Promise<boolean> {
  const res = await Job.updateOne(
    {
      _id: jobId,
      claimedBy,
      state: { $nin: ['CANCELED', 'COMPLETED', 'FAILED'] },
    },
    {
      $set: {
        state: 'COMPLETED',
        completedAt: new Date(),
        result,
        stageProgress: { stage: 'COMPLETED', percent: 100 },
        lastError: null,
        nextRetryAt: null,
      },
    }
  ).exec();
  return res.matchedCount > 0;
}

/** Everything markFailed records beyond the error itself. */
export interface MarkFailedOptions {
  /** NEW attempts total (caller passes previous + 1). */
  attempts: number;
  maxAttempts: number;
  /** Fence: only the claim holder may fail the job (skip to bypass in tools). */
  claimedBy?: string;
  errorCode?: string;
  errorDetails?: string;
  /** Pipeline stage the failure escaped from, when known. */
  failedStage?: ExecutableStage;
}

/**
 * Records a failed attempt. `attempts` is the NEW total (caller passes
 * previous + 1; an explicit $set, not $inc, so a retried write is idempotent).
 * Below maxAttempts the job re-enters the queue with an exponential-backoff
 * `nextRetryAt`; exhausted, it goes terminally FAILED and — per the Job
 * model's documented contract — the structured `error` sub-doc (code,
 * message, the pipeline stage it died in) is populated for the client's
 * Processing Failed surface.
 *
 * RETRY POLICY = resume-from-failed-stage: this deliberately does NOT touch
 * stageProgress/stageOutputs, so a re-queued job re-enters the pipeline at
 * the stage that failed with earlier stages' outputs intact (bounded by
 * maxAttempts). Fenced on claimedBy + non-terminal state like markCompleted;
 * a lost fence no-ops (returns false).
 */
export async function markFailed(
  jobId: Types.ObjectId,
  error: Error,
  opts: MarkFailedOptions
): Promise<boolean> {
  const { attempts, maxAttempts, claimedBy, errorDetails, failedStage } = opts;
  const errorCode = opts.errorCode ?? PROCESSING_FAILED_CODE;
  const exhausted = attempts >= maxAttempts;
  const retryDelayMs = Math.min(
    RETRY_BASE_DELAY_MS * 2 ** Math.max(0, attempts - 1),
    RETRY_MAX_DELAY_MS
  );

  const res = await Job.updateOne(
    {
      _id: jobId,
      ...(claimedBy !== undefined ? { claimedBy } : {}),
      state: { $nin: ['CANCELED', 'COMPLETED', 'FAILED'] },
    },
    {
      $set: {
        state: exhausted ? 'FAILED' : 'QUEUED',
        attempts,
        lastError: error.message,
        claimedAt: null,
        claimedBy: null,
        nextRetryAt: exhausted ? null : new Date(Date.now() + retryDelayMs),
        ...(exhausted
          ? {
              error: {
                code: errorCode,
                message: error.message,
                ...(failedStage ? { stage: failedStage } : {}),
                ...(errorDetails ? { details: errorDetails } : {}),
              },
            }
          : {}),
      },
    }
  ).exec();
  return res.matchedCount > 0;
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
