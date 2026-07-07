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
import type { JobState, UploadInfo } from '@/models/types/job.types';
import type { CaptureSummary, ObjectSize } from '@/models/types/capture.types';

/** jobType every upload-pipeline job carries (the schema default). */
export const DEFAULT_JOB_TYPE = 'CAPTURE_PROCESSING';

/** Fallback for job documents created before the worker fields existed. */
export const DEFAULT_MAX_ATTEMPTS = 3;

/**
 * The lean (POJO) job shape the claim query returns and processors receive.
 * Worker fields are optional because jobs enqueued before this schema
 * extension lack them — consumers must apply the DEFAULT_* fallbacks.
 * There is no `payload` field: the job document itself carries everything a
 * processor needs (upload.rawBucket/rawPrefix/manifestKey, objectSize, …).
 */
export interface WorkerJob {
  _id: Types.ObjectId;
  projectId?: Types.ObjectId;
  userId?: Types.ObjectId;
  state: JobState;
  jobType?: string;
  priority?: number;
  attempts?: number;
  maxAttempts?: number;
  lastError?: string | null;
  claimedAt?: Date | null;
  claimedBy?: string | null;
  nextRetryAt?: Date | null;
  objectSize?: ObjectSize;
  upload?: UploadInfo;
  captureSummary?: CaptureSummary;
  queuedAt?: Date;
  createdAt: Date;
  updatedAt: Date;
}

/**
 * One job type's processing function. Receives the claimed (lean) job and
 * returns a JSON-safe result persisted on the job's `result` field. A throw
 * (or rejection) routes the job through the retry/backoff path.
 */
export type JobProcessor = (job: WorkerJob) => Promise<Record<string, unknown>>;

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
