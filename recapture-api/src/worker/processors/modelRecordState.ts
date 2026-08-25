// src/worker/processors/modelRecordState.ts
//
// The ProjectModel record bookkeeping shared by every processor that OWNS a
// model record for the length of a job: today the Meshy generation and the
// glTF-Transform optimization.
//
// Extracted verbatim from meshyModelProcessor when the optimization processor
// needed the identical four operations. It is deliberately only the RECORD's
// state — the Job's own stage/lease writes stay in stageTransitions.ts, and
// nothing here knows what work the processor is actually doing.
import { ProjectModel, type IProjectModel } from '@/models/ProjectModel';
import type { ModelProgressPhase } from '@/models/types/projectModel.types';
import { DEFAULT_MAX_ATTEMPTS, NonRetryableJobError, type WorkerJob } from '@/worker/workerTypes';

/**
 * Publishes "what the worker is doing right now" onto the record, for the staff
 * progress UI (the admin app polls the models list while a record is pending).
 *
 * STRICTLY BEST-EFFORT: display data must never fail or delay real work, so
 * errors are swallowed and the write is fenced on `status: 'PROCESSING'` — it
 * can never resurrect a record that has already reached a terminal state.
 */
export async function reportProgress(
  record: IProjectModel,
  phase: ModelProgressPhase,
  percent: number
): Promise<void> {
  const clamped = Math.max(0, Math.min(100, Math.round(percent)));
  try {
    await ProjectModel.updateOne(
      { _id: record._id, status: 'PROCESSING' },
      { $set: { progress: { phase, percent: clamped } } }
    ).exec();
  } catch {
    // Ignored by design — the next tick (or the terminal status) supersedes it.
  }
}

/** Removes the live progress once the record is terminal — SUCCEEDED/FAILED
 * carry their own truth and a stale "FINALIZING 100%" would only confuse. */
export async function clearProgress(record: IProjectModel): Promise<void> {
  try {
    await ProjectModel.updateOne({ _id: record._id }, { $unset: { progress: 1 } }).exec();
  } catch {
    // Best-effort for the same reason as reportProgress; clients ignore
    // `progress` on terminal statuses anyway.
  }
}

export async function setStatus(
  record: IProjectModel,
  status: IProjectModel['status']
): Promise<void> {
  if (record.status === status) return;
  record.status = status;
  await record.save();
}

/**
 * Moves the record to FAILED only when nothing more will run for it: either the
 * error is terminal, or this was the job's last attempt. On a retryable error
 * with attempts remaining, the record stays PROCESSING — which is the truth,
 * since the worker will pick it up again after the backoff.
 *
 * Cancel/claim-loss are neither: another owner now decides the outcome, so the
 * record is left exactly as it is.
 */
export async function failRecordIfTerminal(
  job: WorkerJob,
  record: IProjectModel,
  err: unknown,
  fallbackCode: string,
  fallbackMessage: string
): Promise<void> {
  const isTerminal = err instanceof NonRetryableJobError;
  const attemptsSoFar = job.attempts ?? 0;
  const maxAttempts = job.maxAttempts ?? DEFAULT_MAX_ATTEMPTS;
  const isFinalAttempt = attemptsSoFar + 1 >= maxAttempts;

  const name = (err as { name?: string })?.name;
  if (name === 'JobCanceledError' || name === 'ClaimLostError') return;
  if (!isTerminal && !isFinalAttempt) return;

  record.status = 'FAILED';
  record.error = {
    code: isTerminal ? (err as NonRetryableJobError).code : fallbackCode,
    // OUR OWN MESSAGES ONLY. Every thrower on these paths is careful never to
    // interpolate a response body, an S3 key or a presigned URL into one, which
    // is what makes this safe to persist and render.
    message: err instanceof Error ? err.message : fallbackMessage,
  };
  await record.save();
  await clearProgress(record);
}
