// src/worker/worker.ts
//
// The polling loop of the MongoDB-polled background worker: claim → dispatch
// to the registered processor → mark completed/failed, with bounded
// concurrency, heartbeat logging, and graceful drain on SIGTERM/SIGINT.
//
// Deliberately a `while + sleep` loop, NOT setInterval: on shutdown the loop
// simply stops iterating and falls through to the drain phase — setInterval
// cannot drain in-flight jobs cleanly. This file (with jobQueue.ts) is the
// whole surface the planned BullMQ migration replaces; processors and the
// registry are queue-agnostic and survive unchanged.
import {
  claimNextJob,
  getQueueDepth,
  jobTypeOf,
  markCompleted,
  markFailed,
  markProcessing,
} from '@/worker/jobQueue';
import { getProcessor } from '@/worker/processorRegistry';
import { log, toError } from '@/worker/workerLog';
import {
  ClaimLostError,
  DEFAULT_MAX_ATTEMPTS,
  failedStageOf,
  JobCanceledError,
  NonRetryableJobError,
  type WorkerConfig,
  type WorkerJob,
} from '@/worker/workerTypes';

/** `error.code` for a job whose jobType has no registered processor. */
export const UNSUPPORTED_JOB_TYPE_CODE = 'UNSUPPORTED_JOB_TYPE';

// After winning a claim, yield briefly instead of a full poll sleep so a busy
// queue fills the concurrency budget quickly.
const CLAIM_YIELD_MS = 50;
const DRAIN_POLL_MS = 250;

/**
 * Runs the worker until a shutdown signal (SIGTERM/SIGINT, or the config's
 * stopSignal test seam) arrives, then drains in-flight jobs and resolves.
 */
export async function startWorker(config: WorkerConfig): Promise<void> {
  const { pollIntervalMs, claimTimeoutMs, concurrency, workerId, heartbeatEveryNPolls } = config;

  let running = true;
  let pollCount = 0;
  let activeJobs = 0;

  const stop = (signal: string): void => {
    if (!running) return;
    running = false;
    log('info', 'Shutdown signal received', { signal, workerId });
  };
  const onSigterm = (): void => stop('SIGTERM');
  const onSigint = (): void => stop('SIGINT');
  process.once('SIGTERM', onSigterm);
  process.once('SIGINT', onSigint);
  config.stopSignal?.addEventListener('abort', () => stop('stopSignal'), { once: true });

  log('info', 'Worker started', {
    workerId,
    pollIntervalMs,
    claimTimeoutMs,
    concurrency,
    heartbeatEveryNPolls,
  });

  while (running) {
    pollCount++;

    if (pollCount % heartbeatEveryNPolls === 0) {
      const depth = await getQueueDepth().catch((err: unknown) => {
        log('error', 'Failed to read queue depth', { workerId, error: toError(err).message });
        return {} as Record<string, number>;
      });
      // A steadily growing QUEUED count here = backpressure. First scaling
      // lever: raise WORKER_CONCURRENCY or run more worker instances.
      log('info', 'Worker heartbeat', { workerId, pollCount, activeJobs, depth });
    }

    if (activeJobs >= concurrency) {
      await sleep(pollIntervalMs);
      continue;
    }

    const job = await claimNextJob(workerId, claimTimeoutMs).catch((err: unknown) => {
      log('error', 'Failed to claim job', { workerId, error: toError(err).message });
      return null;
    });

    if (!job) {
      await sleep(pollIntervalMs);
      continue;
    }

    // Fire-and-forget so the loop keeps claiming up to `concurrency` jobs. A
    // rejection here means even markFailed could not be written (e.g. Mongo
    // connection drop) — the job stays CLAIMED/PROCESSING and the stale-claim
    // recovery in claimNextJob re-queues it after the lease expires.
    activeJobs++;
    void processJob(job, workerId)
      .catch((err: unknown) =>
        log('error', 'Unhandled error in processJob', {
          jobId: job._id,
          workerId,
          error: toError(err).message,
        })
      )
      .finally(() => {
        activeJobs--;
      });

    await sleep(CLAIM_YIELD_MS);
  }

  log('info', 'Draining active jobs before exit', { workerId, activeJobs });
  while (activeJobs > 0) {
    await sleep(DRAIN_POLL_MS);
  }
  process.removeListener('SIGTERM', onSigterm);
  process.removeListener('SIGINT', onSigint);
  log('info', 'Worker shut down cleanly', { workerId });
}

async function processJob(job: WorkerJob, workerId: string): Promise<void> {
  const jobType = jobTypeOf(job);
  const attempts = job.attempts ?? 0;
  const maxAttempts = job.maxAttempts ?? DEFAULT_MAX_ATTEMPTS;
  const processor = getProcessor(jobType);

  if (!processor) {
    // Deployment mismatch (job enqueued for a type this build doesn't know).
    // Fail terminally — retrying can never succeed. Alert on this in prod logs.
    log('warn', 'No processor registered for jobType', { jobId: job._id, jobType, workerId });
    await markFailed(job._id, new Error(`No processor for jobType: ${jobType}`), {
      attempts: attempts + 1,
      maxAttempts: attempts + 1, // attempts == maxAttempts → terminal FAILED, no retry
      claimedBy: workerId,
      errorCode: UNSUPPORTED_JOB_TYPE_CODE,
    });
    return;
  }

  if (!(await markProcessing(job._id, workerId))) {
    // The job was canceled (or its lease stolen) between the claim and here —
    // whoever won the fence owns it now; touch nothing.
    log('info', 'Claim no longer valid at processing start — skipping job', {
      jobId: job._id,
      jobType,
      workerId,
    });
    return;
  }
  log('info', 'Job processing started', {
    jobId: job._id,
    jobType,
    attempt: attempts + 1,
    maxAttempts,
    workerId,
  });

  // TODO(hardening): wrap the processor call in Promise.race with a JOB_TIMEOUT_MS
  // env var so a hung (never-resolving) processor fails fast instead of waiting
  // for the stale-claim lease to expire.
  try {
    const result = await processor(job);
    const flipped = await markCompleted(job._id, result, workerId);
    if (flipped) {
      log('info', 'Job completed', { jobId: job._id, jobType, workerId });
    } else {
      log('warn', 'COMPLETED flip lost its fence (job canceled or claim stolen)', {
        jobId: job._id,
        jobType,
        workerId,
      });
    }
  } catch (err: unknown) {
    const error = toError(err);

    // Cancellation and claim loss are NOT failures: the job's outcome is
    // owned elsewhere (the canceler / the new claim holder) — stop silently,
    // consume no attempt, write nothing.
    if (error instanceof JobCanceledError) {
      log('info', 'Job canceled mid-processing — pipeline stopped', {
        jobId: job._id,
        jobType,
        workerId,
      });
      return;
    }
    if (error instanceof ClaimLostError) {
      log('warn', 'Claim lost mid-processing — another worker owns the job now', {
        jobId: job._id,
        jobType,
        workerId,
      });
      return;
    }

    const newAttempts = attempts + 1;
    // Terminal (validation-style) failures skip the retry path: retrying
    // cannot fix a missing/invalid bundle. attempts == maxAttempts forces the
    // exhausted branch in markFailed → FAILED + error sub-doc (the DLQ).
    const terminal = error instanceof NonRetryableJobError ? error : null;
    const failedStage = failedStageOf(error);
    await markFailed(job._id, error, {
      attempts: newAttempts,
      maxAttempts: terminal ? newAttempts : maxAttempts,
      claimedBy: workerId,
      errorCode: terminal?.code,
      errorDetails: terminal?.details,
      failedStage,
    });
    log('error', 'Job failed', {
      jobId: job._id,
      jobType,
      attempt: newAttempts,
      maxAttempts,
      error: error.message,
      willRetry: !terminal && newAttempts < maxAttempts,
      ...(failedStage ? { failedStage } : {}),
      ...(terminal ? { errorCode: terminal.code, terminal: true } : {}),
      workerId,
    });
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
