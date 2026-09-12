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
  renewClaim,
} from '@/worker/jobQueue';
import { getProcessor, listRegisteredTypes } from '@/worker/processorRegistry';
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
 * How many times per lease the heartbeat renews it. Three, so two consecutive
 * renewals can be lost (a Mongo blip, an event loop stalled by a CPU-bound
 * stage) before the lease actually lapses and another poll re-claims the job.
 */
const LEASE_RENEWALS_PER_TIMEOUT = 3;

/**
 * Runs the worker until a shutdown signal (SIGTERM/SIGINT, or the config's
 * stopSignal test seam) arrives, then drains in-flight jobs and resolves.
 */
export async function startWorker(config: WorkerConfig): Promise<void> {
  const { pollIntervalMs, claimTimeoutMs, concurrency, workerId, heartbeatEveryNPolls } = config;

  let running = true;
  let pollCount = 0;
  // Two budgets, not one. `activeJobs` is the general budget every type shares;
  // `activeLaneJobs` is the reserved lane's own, spent only when the general
  // one is full. A job claimed into the general budget while it had room counts
  // there even if its type is a lane type — the lane is a floor, not a cap.
  let activeJobs = 0;
  let activeLaneJobs = 0;

  // Read ONCE, here, because the registry is written entirely at boot
  // (registerAllProcessors) and frozen for the process's life — and because
  // this list is the worker's declaration of what it is allowed to take off a
  // SHARED queue. Claiming a type it has no processor for would fail that job
  // terminally below, so a build that predates a job type must not be able to
  // touch one; see the note on claimNextJob's `jobTypes` parameter.
  const processableTypes = config.jobTypes ?? listRegisteredTypes();

  // THE RESERVED LANE. Long-running jobs — a Meshy generation can hold a slot
  // for MESHY_TASK_TIMEOUT_MS — fill the general budget for minutes at a time,
  // and a job type that a person is standing and waiting on (a catalog
  // publish, with a rep at a restaurant table) used to queue behind them for
  // exactly that long. The lane lets `lane.slots` more of those types run
  // beyond `concurrency`, so they are claimed within one poll of being
  // enqueued whatever else is in flight. Intersected with processableTypes so
  // the lane can never claim a job this build has no processor for.
  const laneTypes = (config.reservedLane?.jobTypes ?? []).filter((type) =>
    processableTypes.includes(type)
  );
  const laneSlots = laneTypes.length > 0 ? (config.reservedLane?.slots ?? 0) : 0;

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
    processableTypes,
    ...(laneSlots > 0 ? { reservedLane: { jobTypes: laneTypes, slots: laneSlots } } : {}),
  });
  // An empty registry is a boot bug, not a quiet idle worker: the loop below
  // would poll forever and claim nothing while the queue grows.
  if (processableTypes.length === 0) {
    log('error', 'No processors registered — this worker will claim nothing', { workerId });
  }

  while (running) {
    pollCount++;

    if (pollCount % heartbeatEveryNPolls === 0) {
      const depth = await getQueueDepth().catch((err: unknown) => {
        log('error', 'Failed to read queue depth', { workerId, error: toError(err).message });
        return {} as Record<string, number>;
      });
      // A steadily growing QUEUED count here = backpressure. First scaling
      // lever: raise WORKER_CONCURRENCY or run more worker instances.
      log('info', 'Worker heartbeat', {
        workerId,
        pollCount,
        activeJobs,
        activeLaneJobs,
        depth,
      });
    }

    // Which budget this poll can spend. General first; when it is full, only
    // the reserved lane's types are eligible and they are charged to the lane.
    const generalOpen = activeJobs < concurrency;
    const laneOpen = activeLaneJobs < laneSlots;
    if (!generalOpen && !laneOpen) {
      await sleep(pollIntervalMs);
      continue;
    }
    const claimableTypes = generalOpen ? processableTypes : laneTypes;
    const viaLane = !generalOpen;

    const job = await claimNextJob(workerId, claimTimeoutMs, claimableTypes).catch((err: unknown) => {
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
    if (viaLane) activeLaneJobs++;
    else activeJobs++;
    void processJob(job, workerId, claimTimeoutMs)
      .catch((err: unknown) =>
        log('error', 'Unhandled error in processJob', {
          jobId: job._id,
          workerId,
          error: toError(err).message,
        })
      )
      .finally(() => {
        if (viaLane) activeLaneJobs--;
        else activeJobs--;
      });

    await sleep(CLAIM_YIELD_MS);
  }

  log('info', 'Draining active jobs before exit', { workerId, activeJobs, activeLaneJobs });
  while (activeJobs + activeLaneJobs > 0) {
    await sleep(DRAIN_POLL_MS);
  }
  process.removeListener('SIGTERM', onSigterm);
  process.removeListener('SIGINT', onSigint);
  log('info', 'Worker shut down cleanly', { workerId });
}

async function processJob(job: WorkerJob, workerId: string, claimTimeoutMs: number): Promise<void> {
  const jobType = jobTypeOf(job);
  const attempts = job.attempts ?? 0;
  const maxAttempts = job.maxAttempts ?? DEFAULT_MAX_ATTEMPTS;
  const processor = getProcessor(jobType);

  if (!processor) {
    // Defence in depth. claimNextJob now filters on the registered types, so
    // reaching here means the registry changed under a claim we already hold —
    // it is no longer the deployment-mismatch path, which is handled by simply
    // never claiming the row. Fail terminally: retrying cannot add a processor.
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

  // THE LEASE HEARTBEAT. While the processor runs, `claimedAt` is renewed a
  // few times per lease so a job that legitimately outlasts
  // WORKER_CLAIM_TIMEOUT_MS is not re-claimed — by another instance, or by this
  // one's other slot — and walked twice at once. Fenced (see renewClaim): the
  // first renewal that finds the fence gone stops the heartbeat, and the
  // processor's own fenced writes discover the loss the way they always did.
  //
  // What this deliberately does NOT change: a worker that DIES stops
  // heartbeating, and its job is re-claimed one lease later exactly as before.
  // The lease still recovers crashes; it just no longer punishes slow work.
  //
  // TODO(hardening): wrap the processor call in Promise.race with a JOB_TIMEOUT_MS
  // env var so a hung (never-resolving) processor fails fast — with the
  // heartbeat, a hang is no longer bounded by the lease.
  const stopHeartbeat = startLeaseHeartbeat(job, workerId, claimTimeoutMs);
  try {
    const result = await processor(job);
    stopHeartbeat();
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
    stopHeartbeat();
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

/**
 * Renews the job's lease every `claimTimeoutMs / LEASE_RENEWALS_PER_TIMEOUT`
 * until the returned stop function is called, or until a renewal reports the
 * fence lost. Never throws: a renewal that fails to write is logged and the
 * next tick tries again — two misses in a row still leave the lease alive.
 */
function startLeaseHeartbeat(job: WorkerJob, workerId: string, claimTimeoutMs: number): () => void {
  const everyMs = Math.max(1, Math.floor(claimTimeoutMs / LEASE_RENEWALS_PER_TIMEOUT));
  let stopped = false;
  let inFlight = false;

  const stop = (): void => {
    if (stopped) return;
    stopped = true;
    clearInterval(timer);
  };

  const timer = setInterval(() => {
    if (stopped || inFlight) return;
    inFlight = true;
    renewClaim(job._id, workerId)
      .then((stillOurs) => {
        if (stillOurs || stopped) return;
        log('warn', 'Lease heartbeat found the claim gone — stopping renewals', {
          jobId: job._id,
          workerId,
        });
        stop();
      })
      .catch((err: unknown) => {
        log('warn', 'Lease heartbeat failed to renew the claim', {
          jobId: job._id,
          workerId,
          error: toError(err).message,
        });
      })
      .finally(() => {
        inFlight = false;
      });
  }, everyMs);
  // The heartbeat must never be what keeps a draining process alive.
  timer.unref();

  return stop;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
