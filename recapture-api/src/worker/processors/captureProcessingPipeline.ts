// src/worker/processors/captureProcessingPipeline.ts
//
// The processing-pipeline ORCHESTRATOR: drives one validated capture bundle
// through PROCESSING → TEXTURING → OPTIMIZING, delegating each stage's actual
// work to the reconstruction-engine adapter and persisting every transition
// atomically (stageTransitions.ts). The COMPLETED flip itself stays with the
// worker loop's markCompleted — by the time this returns, everything except
// that flip (final outputs, artifacts, timestamps) is already durable.
//
// RESUME, not restart: the entry stage comes from the job's durable
// stageProgress pointer, so a crash-recovered claim or a retry-after-failure
// re-enters exactly the stage that was running, with the persisted outputs of
// earlier stages fed back to the engine as priorOutputs. Fresh jobs enter at
// PROCESSING.
//
// Failure tagging: any error escaping a stage is tagged with `failedStage`
// (Object.assign — wrapping would strip NonRetryableJobError's class and with
// it the terminal-vs-retry routing) so markFailed can record WHERE the
// pipeline died. JobCanceledError/ClaimLostError pass through untagged-ish
// (tag is harmless) and make the worker loop go silent instead of marking.
import type { ExecutableStage } from '@/models/types/job.types';
import {
  getReconstructionEngine,
  type EngineStageInput,
  type OptimizeOutput,
  type ReconstructionEngine,
} from '@/worker/engine/reconstructionEngine';
import { resumeStageFor, stagesFrom } from '@/worker/processingStages';
import {
  enterStage,
  recordFinalStage,
  recordStageProgress,
  type CompletedStage,
} from '@/worker/stageTransitions';
import { log } from '@/worker/workerLog';
import type { WorkerJob } from '@/worker/workerTypes';

/** What the validation stage hands to the pipeline. */
export interface ValidatedBundle {
  /** Parsed capture_manifest.json — structure already validated upstream. */
  manifest: unknown;
  /** S3-listed object count under the job's prefix (manifest included). */
  filesVerified: number;
}

const ENGINE_METHOD: Record<ExecutableStage, keyof ReconstructionEngine> = {
  PROCESSING: 'reconstruct',
  TEXTURING: 'texture',
  OPTIMIZING: 'optimize',
};

/**
 * Runs (or resumes) the stage pipeline for one validated bundle. The job is
 * already claimed by this worker and in an active state; a throw here routes
 * through the worker's retry/backoff (or NonRetryableJobError → terminal
 * FAILED, or JobCanceledError/ClaimLostError → silent stop).
 */
export async function runCaptureProcessing(
  job: WorkerJob,
  bundle: ValidatedBundle
): Promise<Record<string, unknown>> {
  const upload = job.upload;
  const claimedBy = job.claimedBy;
  if (!upload || !claimedBy) {
    // Both are guaranteed by the processor's validation and the claim itself;
    // reaching here is a programming error, not a job problem.
    throw new Error('runCaptureProcessing requires a claimed job with an upload block');
  }

  const engine = getReconstructionEngine();
  const entryStage = resumeStageFor(job.stageProgress);
  const priorOutputs: Record<string, Record<string, unknown>> = { ...(job.stageOutputs ?? {}) };

  if (entryStage !== 'PROCESSING') {
    log('info', 'Resuming pipeline from persisted stage', {
      jobId: job._id,
      entryStage,
      priorStages: Object.keys(priorOutputs),
    });
  }

  // Rolls forward one stage at a time. `completedPrev` carries the previous
  // iteration's result into enterStage so "stage S is durably done" and
  // "stage S+1 has begun" are ONE atomic write.
  let completedPrev: CompletedStage | undefined;
  let finalOutput: OptimizeOutput | undefined;

  for (const stage of stagesFrom(entryStage)) {
    await enterStage(job._id, claimedBy, stage, completedPrev);

    const input: EngineStageInput = {
      jobId: job._id.toString(),
      projectId: job.projectId?.toString(),
      rawBucket: upload.rawBucket,
      rawPrefix: upload.rawPrefix,
      manifestKey: upload.manifestKey,
      manifest: bundle.manifest,
      filesVerified: bundle.filesVerified,
      priorOutputs,
      onProgress: (percent) => recordStageProgress(job._id, claimedBy, stage, percent),
    };

    let output: Record<string, unknown>;
    try {
      output = await engine[ENGINE_METHOD[stage]](input);
    } catch (err: unknown) {
      // Tag with the failing stage for markFailed's error sub-doc; keep the
      // original error object so its class still routes terminal vs retry.
      throw Object.assign(err instanceof Error ? err : new Error(String(err)), {
        failedStage: stage,
      });
    }

    priorOutputs[stage] = output;
    if (stage === 'OPTIMIZING') {
      finalOutput = output as OptimizeOutput;
    } else {
      completedPrev = { stage, output };
    }
    log('info', 'Pipeline stage finished', { jobId: job._id, stage });
  }

  // OPTIMIZING succeeded: persist its output + the artifact refs durably
  // BEFORE the loop's COMPLETED flip. A crash in between leaves the stage
  // pointer on OPTIMIZING → idempotent re-run on re-claim, never a job that
  // claims COMPLETED without durable artifacts.
  if (!finalOutput || !finalOutput.artifacts) {
    throw Object.assign(
      new Error('Engine optimize() returned no artifacts — cannot complete the job'),
      { failedStage: 'OPTIMIZING' as const }
    );
  }
  const artifacts = finalOutput.artifacts;
  await recordFinalStage(
    job._id,
    claimedBy,
    { stage: 'OPTIMIZING', output: finalOutput },
    artifacts
  );

  return {
    pipeline: 'engine',
    entryStage,
    stagesRun: stagesFrom(entryStage),
    artifacts,
  };
}
