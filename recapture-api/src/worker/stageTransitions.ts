// src/worker/stageTransitions.ts
//
// FENCED, atomic DB writes for pipeline stage transitions. Every write here is
// ONE conditional findOneAndUpdate/updateOne (the codebase's no-transactions
// atomicity pattern, AGENTS.md §Data layer) with a three-part fence:
//
//   1. claimedBy === this worker      — a stolen (lease-expired, re-claimed)
//      job makes every write from the old owner lose → ClaimLostError;
//   2. state is an ACTIVE worker state — an externally-flipped CANCELED (or
//      any terminal state) makes the write lose → JobCanceledError, so
//      cancellation stops the pipeline at its next persistence point;
//   3. stageProgress.stage permits the move — the DB-side mirror of the pure
//      machine in processingStages.ts, so even a racing duplicate runner
//      cannot skip a stage or double-advance.
//
// Each successful write also bumps claimedAt — pipeline persistence doubles
// as lease renewal, so a healthy long-running job is never "stale" as long as
// it keeps transitioning or reporting progress. (A single silent stage longer
// than WORKER_CLAIM_TIMEOUT_MS still needs the engine to emit progress; the
// stub does, and a real adapter must.)
//
// Advancing into stage S+1 and durably recording stage S's completion
// (completedAt + engine output) happen in the SAME update — there is no
// instant where the stage pointer has advanced but the prior stage's output
// is not persisted. Crash between engine success and that write ⇒ the stage
// pointer still names S ⇒ S re-runs idempotently. The persisted stage never
// advances before the work behind it is durable.
import type { Types } from 'mongoose';
import { Job } from '@/models/Job';
import type { ExecutableStage, JobState } from '@/models/types/job.types';
import {
  InvalidStageTransitionError,
  nextStage,
} from '@/worker/processingStages';
import { ClaimLostError, JobCanceledError } from '@/worker/workerTypes';

/** Job states a live pipeline run may be observed in (fence part 2). */
export const ACTIVE_PIPELINE_STATES: readonly JobState[] = [
  'CLAIMED',
  'PROCESSING',
  'TEXTURING',
  'OPTIMIZING',
];

/** A completed stage handed to enterStage to be recorded with the advance. */
export interface CompletedStage {
  stage: ExecutableStage;
  /** Engine-adapter output — persisted under stageOutputs.<stage>. */
  output: Record<string, unknown>;
}

/**
 * Enters `to` in one atomic write: state=to, stageProgress={to, 0}, the
 * stage's startedAt, lease renewal — and, when advancing (`completed` given),
 * the prior stage's completedAt + engine output.
 *
 * Without `completed` this is (re-)ENTRY: first entry into PROCESSING, or the
 * crash/retry resume re-run of the stage the durable pointer already names.
 * With `completed` it is an ADVANCE and must be exactly one step forward
 * (pure-machine check throws InvalidStageTransitionError before any IO).
 *
 * Losing the fenced write raises the appropriate error (see module header);
 * an unexplained loss (externally forced state/stage) also raises
 * InvalidStageTransitionError.
 */
export async function enterStage(
  jobId: Types.ObjectId,
  claimedBy: string,
  to: ExecutableStage,
  completed?: CompletedStage
): Promise<void> {
  const now = new Date();

  let stageFence: Record<string, unknown>;
  if (completed) {
    if (nextStage(completed.stage) !== to) {
      throw new InvalidStageTransitionError(completed.stage, to);
    }
    stageFence = { 'stageProgress.stage': completed.stage };
  } else {
    // (Re-)entry: the pointer already names `to`, or — for the pipeline's
    // first stage only — there is no pointer yet (or finalize left QUEUED).
    const allowed: Record<string, unknown>[] = [{ 'stageProgress.stage': to }];
    if (to === 'PROCESSING') {
      allowed.push({ stageProgress: { $exists: false } }, { 'stageProgress.stage': 'QUEUED' });
    }
    stageFence = { $or: allowed };
  }

  const res = await Job.updateOne(
    {
      _id: jobId,
      claimedBy,
      state: { $in: [...ACTIVE_PIPELINE_STATES] },
      ...stageFence,
    },
    {
      $set: {
        state: to,
        stageProgress: { stage: to, percent: 0 },
        claimedAt: now,
        [`stageTimestamps.${to}.startedAt`]: now,
        // A re-run must not keep a stale completedAt from a previous attempt.
        [`stageTimestamps.${to}.completedAt`]: null,
        ...(completed
          ? {
              [`stageTimestamps.${completed.stage}.completedAt`]: now,
              [`stageOutputs.${completed.stage}`]: completed.output,
            }
          : {}),
      },
    }
  ).exec();

  if (res.matchedCount === 0) {
    throw await diagnoseLostWrite(jobId, claimedBy, to, completed?.stage);
  }
}

/**
 * Durably records the FINAL stage's success — OPTIMIZING's completedAt,
 * engine output, artifacts, percent 100 — in one fenced write, WITHOUT
 * advancing the stage pointer. The COMPLETED flip itself belongs to the
 * worker loop's markCompleted; a crash between the two leaves the pointer on
 * OPTIMIZING, which simply re-runs idempotently on re-claim.
 */
export async function recordFinalStage(
  jobId: Types.ObjectId,
  claimedBy: string,
  completed: CompletedStage,
  artifacts: Record<string, unknown>
): Promise<void> {
  const now = new Date();
  const res = await Job.updateOne(
    {
      _id: jobId,
      claimedBy,
      state: { $in: [...ACTIVE_PIPELINE_STATES] },
      'stageProgress.stage': completed.stage,
    },
    {
      $set: {
        'stageProgress.percent': 100,
        claimedAt: now,
        [`stageTimestamps.${completed.stage}.completedAt`]: now,
        [`stageOutputs.${completed.stage}`]: completed.output,
        artifacts,
      },
    }
  ).exec();

  if (res.matchedCount === 0) {
    throw await diagnoseLostWrite(jobId, claimedBy, completed.stage, completed.stage);
  }
}

/**
 * Persists intra-stage progress (0–100, engine-reported) and renews the
 * lease. NOT best-effort on a fence loss: a lost write means cancel or claim
 * theft, and throwing here is exactly what aborts the running engine call
 * promptly instead of at the next transition.
 */
export async function recordStageProgress(
  jobId: Types.ObjectId,
  claimedBy: string,
  stage: ExecutableStage,
  percent: number
): Promise<void> {
  const clamped = Math.max(0, Math.min(100, Math.round(percent)));
  const res = await Job.updateOne(
    {
      _id: jobId,
      claimedBy,
      state: { $in: [...ACTIVE_PIPELINE_STATES] },
      'stageProgress.stage': stage,
    },
    { $set: { 'stageProgress.percent': clamped, claimedAt: new Date() } }
  ).exec();

  if (res.matchedCount === 0) {
    throw await diagnoseLostWrite(jobId, claimedBy, stage, stage);
  }
}

/** Reads the job once to turn a lost fenced write into the right error. */
async function diagnoseLostWrite(
  jobId: Types.ObjectId,
  claimedBy: string,
  to: ExecutableStage,
  from: ExecutableStage | undefined
): Promise<Error> {
  const doc = await Job.findById(jobId)
    .select('state claimedBy stageProgress')
    .lean<{ state: JobState; claimedBy?: string | null }>()
    .exec();

  if (doc?.state === 'CANCELED') return new JobCanceledError(jobId.toString());
  if (!doc || doc.claimedBy !== claimedBy) {
    return new ClaimLostError(jobId.toString(), claimedBy);
  }
  // Claim intact, not canceled — the state/stage itself forbade the move
  // (e.g. an externally forced stage). Surface it as a machine violation.
  return new InvalidStageTransitionError(from ?? 'none', to);
}
