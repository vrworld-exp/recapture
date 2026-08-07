// src/worker/workerTypes.ts
//
// Shared types for the MongoDB-polled background worker (src/worker/).
//
// QUEUE MODEL: there is NO separate queue collection — the Job document itself
// is the queue entry. POST /jobs/:id/finalize's conditional QUEUED flip is the
// enqueue (see src/services/jobsService.ts), and the worker discovers work by
// polling `state: 'QUEUED'` and claiming it with one atomic findOneAndUpdate
// (src/worker/jobQueue.ts). The processor/registry surface below is
// deliberately queue-agnostic so a future BullMQ swap only replaces
// jobQueue.ts + worker.ts.
import type { Types } from 'mongoose';
import {
  CAPTURE_PROCESSING_JOB_TYPE,
  MESHY_MODEL_GENERATION_JOB_TYPE,
  MODEL_OPTIMIZATION_JOB_TYPE,
  type ExecutableStage,
  type JobState,
  type StageProgress,
  type UploadInfo,
} from '@/models/types/job.types';
import type { CaptureSummary, ObjectSize } from '@/models/types/capture.types';
import type { CaptureFlowVariant, CaptureMode } from '@/models/types/captureVariants';

/** jobType every upload-pipeline job carries (the schema default). */
export const DEFAULT_JOB_TYPE = CAPTURE_PROCESSING_JOB_TYPE;

export {
  CAPTURE_PROCESSING_JOB_TYPE,
  MESHY_MODEL_GENERATION_JOB_TYPE,
  MODEL_OPTIMIZATION_JOB_TYPE,
};

/** Fallback for job documents created before the worker fields existed. */
export const DEFAULT_MAX_ATTEMPTS = 3;

/**
 * The lean (POJO) job shape the claim query returns and processors receive.
 * Worker fields are optional because jobs enqueued before this schema
 * extension lack them — consumers must apply the DEFAULT_* fallbacks.
 * CAPTURE_PROCESSING needs no `payload`: the job document itself carries
 * everything (upload.rawBucket/rawPrefix/manifestKey, objectSize, …). Job types
 * whose work isn't described by those capture fields (MESHY_MODEL_GENERATION)
 * carry their input in `payload` instead.
 */
export interface WorkerJob {
  _id: Types.ObjectId;
  projectId?: Types.ObjectId;
  userId?: Types.ObjectId;
  state: JobState;
  jobType?: string;
  /** Job-type-specific input; unset for CAPTURE_PROCESSING. */
  payload?: Record<string, unknown>;
  priority?: number;
  attempts?: number;
  maxAttempts?: number;
  lastError?: string | null;
  claimedAt?: Date | null;
  claimedBy?: string | null;
  nextRetryAt?: Date | null;
  objectSize?: ObjectSize;
  captureVariant?: CaptureFlowVariant;
  captureMode?: CaptureMode;
  upload?: UploadInfo;
  captureSummary?: CaptureSummary;
  /** Durable pipeline stage pointer — the resume/retry entry point. */
  stageProgress?: StageProgress;
  /** Persisted engine outputs of already-completed stages (resume inputs). */
  stageOutputs?: Record<string, Record<string, unknown>>;
  queuedAt?: Date;
  createdAt: Date;
  updatedAt: Date;
}

/**
 * One job type's processing function. Receives the claimed (lean) job and
 * returns a JSON-safe result persisted on the job's `result` field. A plain
 * throw (or rejection) routes the job through the retry/backoff path; a
 * NonRetryableJobError fails it terminally on the spot.
 */
export type JobProcessor = (job: WorkerJob) => Promise<Record<string, unknown>>;

/**
 * A processor-raised failure that retrying can NEVER fix — e.g. the bundle's
 * manifest is gone from S3, or its content breaks a validation rule. The
 * worker loop routes this straight to terminal FAILED (the codebase's
 * dead-letter equivalent: `error` sub-doc populated for the client's
 * Processing Failed surface), skipping the retry/backoff path entirely.
 *
 * `code` must be a stable JobError code (see models/types/job.types.ts —
 * e.g. MANIFEST_MISSING, MANIFEST_INVALID, FILE_COUNT_MISMATCH); `details`
 * is optional admin-only diagnostics (rule findings, never PII).
 */
export class NonRetryableJobError extends Error {
  constructor(
    public readonly code: string,
    message: string,
    public readonly details?: string
  ) {
    super(message);
    this.name = 'NonRetryableJobError';
  }
}

/**
 * Raised by a fenced pipeline write when the job's state turned CANCELED
 * under the running stage. Cancellation is TERMINAL and externally owned
 * (the cancel endpoint flips the state; the pipeline only observes it): the
 * worker loop stops the pipeline and writes NOTHING more to the job — no
 * markCompleted, no markFailed, no attempt consumed.
 */
export class JobCanceledError extends Error {
  constructor(public readonly jobId: string) {
    super(`Job ${jobId} was canceled — pipeline stopped`);
    this.name = 'JobCanceledError';
  }
}

/**
 * Raised by a fenced pipeline write when `claimedBy` no longer names this
 * worker — the lease expired mid-stage and another instance re-claimed the
 * job. The loser must go silent immediately (no state writes: the new owner's
 * transitions are now authoritative); the stage's idempotency contract makes
 * the overlap harmless.
 */
export class ClaimLostError extends Error {
  constructor(
    public readonly jobId: string,
    public readonly claimedBy: string
  ) {
    super(`Job ${jobId} is no longer claimed by ${claimedBy} — another worker took it over`);
    this.name = 'ClaimLostError';
  }
}

/**
 * The stage a pipeline error escaped from, when it carries one. The pipeline
 * tags every stage failure (via `Object.assign`) instead of wrapping, so
 * NonRetryableJobError keeps its class for the terminal-vs-retry routing.
 */
export function failedStageOf(err: unknown): ExecutableStage | undefined {
  const stage = (err as { failedStage?: unknown })?.failedStage;
  return stage === 'PROCESSING' || stage === 'TEXTURING' || stage === 'OPTIMIZING'
    ? stage
    : undefined;
}

export interface WorkerConfig {
  /** How often to poll for claimable jobs (ms). */
  pollIntervalMs: number;
  /** Lease length before a CLAIMED/PROCESSING job counts as orphaned (ms). */
  claimTimeoutMs: number;
  /** How many jobs this instance processes simultaneously. */
  concurrency: number;
  /** Unique id of this worker instance (goes into `claimedBy` + logs). */
  workerId: string;
  /** Log a heartbeat (with queue-depth breakdown) every N polls. */
  heartbeatEveryNPolls: number;
  /**
   * Test seam: aborting stops the loop through the same graceful-shutdown
   * path as SIGTERM/SIGINT (tests can't emit real process signals without
   * tripping the test runner's own handlers).
   */
  stopSignal?: AbortSignal;
}
