// src/worker/processingStages.ts
//
// The PURE processing-pipeline stage machine — no IO, no mongoose. The single
// authority on stage ordering and transition validity:
//
//   QUEUED → PROCESSING → TEXTURING → OPTIMIZING → COMPLETED   (forward by one)
//   any non-terminal stage → FAILED                             (on error)
//
// No skipping, no going backward. The one non-transition movement is RESUME:
// re-entering the stage `stageProgress.stage` already points at (crash
// recovery / retry-from-failed-stage) — that is a re-run of the current
// stage, not a stage change, and stage work must therefore be idempotent.
//
// DB-side enforcement lives in stageTransitions.ts (fenced conditional
// updates); this module is what those filters and the unit tests both derive
// from, so they can never disagree.
import type { ExecutableStage, ProcessingStage, StageProgress } from '@/models/types/job.types';

/** Full stage order, rest states included. */
export const PIPELINE_STAGE_ORDER: readonly ProcessingStage[] = [
  'QUEUED',
  'PROCESSING',
  'TEXTURING',
  'OPTIMIZING',
  'COMPLETED',
];

/** The stages that run engine work, in execution order. */
export const EXECUTABLE_STAGES: readonly ExecutableStage[] = [
  'PROCESSING',
  'TEXTURING',
  'OPTIMIZING',
];

/** The next stage forward, or null from the terminal stage. */
export function nextStage(stage: ProcessingStage): ProcessingStage | null {
  const i = PIPELINE_STAGE_ORDER.indexOf(stage);
  return i >= 0 && i < PIPELINE_STAGE_ORDER.length - 1 ? PIPELINE_STAGE_ORDER[i + 1] : null;
}

/**
 * Whether `from → to` is a legal transition: exactly one step forward, or
 * FAILED from anything not already COMPLETED. Everything else — skipping,
 * backward, self — is invalid.
 */
export function canTransition(from: ProcessingStage, to: ProcessingStage | 'FAILED'): boolean {
  if (to === 'FAILED') return from !== 'COMPLETED';
  return nextStage(from) === to;
}

/** Thrown when a transition the pure machine forbids is attempted. */
export class InvalidStageTransitionError extends Error {
  constructor(
    public readonly from: ProcessingStage | 'none',
    public readonly to: ProcessingStage
  ) {
    super(`Invalid pipeline stage transition: ${from} → ${to}`);
    this.name = 'InvalidStageTransitionError';
  }
}

/**
 * Where a (re-)claimed job's pipeline run starts: the executable stage its
 * durable stage pointer already sits in (crash resume / retry-from-failed-
 * stage), or PROCESSING for a fresh job (no stageProgress yet, or still
 * QUEUED). stageProgress can never read COMPLETED on a claimable job — that
 * stamp is written atomically with the COMPLETED state flip.
 */
export function resumeStageFor(stageProgress: StageProgress | undefined): ExecutableStage {
  const current = stageProgress?.stage;
  return current && (EXECUTABLE_STAGES as readonly string[]).includes(current)
    ? (current as ExecutableStage)
    : 'PROCESSING';
}

/** The executable stages from `start` (inclusive) to the end of the pipeline. */
export function stagesFrom(start: ExecutableStage): readonly ExecutableStage[] {
  return EXECUTABLE_STAGES.slice(EXECUTABLE_STAGES.indexOf(start));
}
