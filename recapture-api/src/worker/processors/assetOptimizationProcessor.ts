// src/worker/processors/assetOptimizationProcessor.ts
//
// The ASSET_OPTIMIZATION processor: turn the untouched Meshy GLB into a
// web-ready variant, and record both so a human can compare them.
//
// ── WHY THIS IS ITS OWN JOB ──────────────────────────────────────────────────
// It runs AFTER the Meshy record is already SUCCEEDED with a usable original.
// That ordering is the whole design: optimization is a bonus, never a gate.
// If this job fails every attempt, the model still renders — just heavier.
// Nothing here may ever move the ProjectModel's own `status` off SUCCEEDED.
//
// ── WHAT IT DECIDES: THE SERVING POLICY ──────────────────────────────────────
// A validated run AUTO-PROMOTES `optimized.activeVariant` to 'web'.
//
// This reversed with pipeline v2, and the reason is worth keeping: promotion
// used to be manual because the untouched Meshy GLB was itself servable, so
// producing a variant could never be urgent. Generation now asks for ~200k
// triangles and 4k textures — deliberately, because a low budget was breaking
// thin geometry at the source — and that original is past what an Android
// WebView can parse. Leaving 'original' active would ship the crash
// ("We couldn't load this model") to every viewer until an admin noticed.
//
// So the default flipped, but the human's authority did not: an admin who used
// PATCH …/variant sets `variantPinnedByAdmin`, and this job never overrides a
// pinned choice in EITHER direction. Auto-promotion is a default, not a
// verdict — "passed the gates" and "looks right" are still different claims.
//
// Everything ambiguous still falls back to 'original': a skipped run, a gate
// failure, a manifest with no 'web' entry.
//
// The heavy lifting (gltf-transform, sharp, meshopt) lives in
// src/modules/asset-pipeline — a pure library. This file is the seam between
// that library and the queue: load bytes, run, persist, log.
import { BUCKET_ARTIFACTS } from '@/config/s3';
import { ProjectModel, type IProjectModel } from '@/models/ProjectModel';
import {
  ASSET_PIPELINE_VERSION,
  type OptimizedAsset,
} from '@/models/types/assetManifest.types';
import { getObjectBytes } from '@/services/s3ObjectStore';
import { runPipeline } from '@/modules/asset-pipeline';
import { publish } from '@/modules/asset-pipeline/publish';
import { enterStage, recordStageProgress } from '@/worker/stageTransitions';
import { log } from '@/worker/workerLog';
import { NonRetryableJobError, type JobProcessor, type WorkerJob } from '@/worker/workerTypes';

/** Stable JobError codes this processor raises. */
export const AssetOptimizationErrorCode = {
  /** payload.modelId missing — malformed by construction. */
  JOB_MALFORMED: 'ASSET_OPT_JOB_MALFORMED',
  /** The record vanished, or never had a generated GLB to optimize. */
  SOURCE_MISSING: 'ASSET_OPT_SOURCE_MISSING',
  /** The produced asset broke a hard gate. Terminal: a retry produces the same bytes. */
  GATE_FAILED: 'ASSET_OPT_GATE_FAILED',
  /** The source GLB could not be parsed at all. */
  SOURCE_UNREADABLE: 'ASSET_OPT_SOURCE_UNREADABLE',
} as const;

export const assetOptimizationProcessor: JobProcessor = async (job) => {
  const claimedBy = job.claimedBy;
  const modelId = (job.payload as { modelId?: unknown } | undefined)?.modelId;
  if (!claimedBy || typeof modelId !== 'string') {
    throw new NonRetryableJobError(
      AssetOptimizationErrorCode.JOB_MALFORMED,
      'Optimization job is missing its claim or payload.modelId.'
    );
  }

  const record = await ProjectModel.findById(modelId).exec();
  if (!record?.artifacts?.glbKey) {
    // Nothing to optimize and nothing a retry can conjure. Not a model failure.
    throw new NonRetryableJobError(
      AssetOptimizationErrorCode.SOURCE_MISSING,
      'The model record has no generated GLB to optimize.'
    );
  }

  const originalKey = record.artifacts.glbKey;
  const modelPrefix = originalKey.slice(0, originalKey.lastIndexOf('/') + 1);

  // PROCESSING, not OPTIMIZING, despite what this job does: the stage machine
  // (worker/processingStages.ts) models the CAPTURE pipeline, where OPTIMIZING
  // is only reachable via PROCESSING → TEXTURING. Like meshyModelProcessor,
  // this job is one logical unit of work borrowing the fenced stage writes
  // purely for LEASE RENEWAL and cancel/steal detection — so it uses the same
  // single entry stage rather than inventing a transition the machine rejects.
  await enterStage(job._id, claimedBy, 'PROCESSING');
  await setOptimizationStatus(record, 'PROCESSING');

  try {
    const source = await getObjectBytes(BUCKET_ARTIFACTS, originalKey);
    if (source.outcome === 'absent') {
      // The record names a GLB that is not in the bucket. Retrying cannot
      // create it, and the model itself is already (correctly) SUCCEEDED.
      throw new NonRetryableJobError(
        AssetOptimizationErrorCode.SOURCE_MISSING,
        'The generated GLB this optimization was queued for is no longer in storage.'
      );
    }

    // Renews the claim lease before a CPU-heavy stretch that can outlast
    // WORKER_CLAIM_TIMEOUT_MS on a large model, and throws if the job was
    // canceled or stolen (those must propagate untouched).
    await recordStageProgress(job._id, claimedBy, 'PROCESSING', 10);

    const run = await runPipeline(source.body, {
      profileName: 'food',
      logger: (message, meta) => log('info', message, { jobId: job._id, ...meta }),
      context: { jobId: job._id, modelId, projectId: record.projectId },
    });

    if (!run.plan.skip && !run.validation.ok) {
      // Terminal: the recipe is deterministic, so re-running produces the same
      // rejected bytes. An operator fixes this by changing the profile or the
      // recipe, not by waiting.
      throw new NonRetryableJobError(
        AssetOptimizationErrorCode.GATE_FAILED,
        'The optimized asset failed validation and was not published.',
        run.validation.failures.map((f) => `${f.gate}: ${f.message}`).join(' | ')
      );
    }

    await recordStageProgress(job._id, claimedBy, 'PROCESSING', 80);

    const { manifest, reportKey } = await publish({
      modelId,
      modelPrefix,
      run,
      originalKey,
      originalReport: run.sourceReport,
      ...(record.artifacts.previewImageKey
        ? { posterKey: record.artifacts.previewImageKey }
        : {}),
    });

    const pinnedByAdmin = record.optimized?.variantPinnedByAdmin === true;
    const activeVariant = resolveActiveVariant(record, run.variant !== undefined);

    record.optimized = {
      status: run.plan.skip ? 'SKIPPED' : 'SUCCEEDED',
      pipelineVersion: ASSET_PIPELINE_VERSION,
      manifest,
      activeVariant,
      ...(pinnedByAdmin ? { variantPinnedByAdmin: true } : {}),
      reportKey,
    };
    record.markModified('optimized');
    await record.save();

    log('info', 'Asset optimization complete', {
      jobId: job._id,
      modelId,
      projectId: record.projectId,
      skipped: run.plan.skip,
      activeVariant,
      variantPinnedByAdmin: pinnedByAdmin,
      bytesBefore: manifest.reduction.bytesBefore,
      bytesAfter: manifest.reduction.bytesAfter,
      ratio: Number(manifest.reduction.ratio.toFixed(4)),
      trianglesAfter: manifest.reduction.trianglesAfter,
      durationMs: run.durationsMs.total,
    });

    return {
      modelId,
      pipelineVersion: ASSET_PIPELINE_VERSION,
      skipped: run.plan.skip,
      variants: manifest.variants.map((v) => v.id),
    };
  } catch (err: unknown) {
    await failOptimizationIfTerminal(job, record, err);
    throw err;
  }
};

/**
 * Which rendition owners get after this run.
 *
 * Three states, in precedence order:
 *   1. an admin pinned a choice     → theirs, untouched, in either direction;
 *   2. this run produced a variant  → 'web' (see the serving-policy note above);
 *   3. anything else                → 'original', the safe fallback.
 *
 * Case 3 covers a skipped run and a re-run that produced nothing, and it
 * deliberately does NOT preserve a previous auto-promotion: if this run has no
 * validated 'web' entry, the manifest being written has no 'web' entry either,
 * and pointing at a variant that is not in the manifest is how a client ends up
 * resolving nothing.
 */
function resolveActiveVariant(
  record: IProjectModel,
  producedVariant: boolean
): OptimizedAsset['activeVariant'] {
  if (record.optimized?.variantPinnedByAdmin === true) {
    return record.optimized.activeVariant;
  }
  return producedVariant ? 'web' : 'original';
}

/**
 * Records a terminal optimization failure on the record — WITHOUT touching the
 * model's own status, which stays SUCCEEDED because the original still serves.
 *
 * Mirrors meshyModelProcessor.failRecordIfTerminal: only writes when nothing
 * more will run (terminal error, or the last attempt), and stays silent on
 * cancel/claim-loss because another owner now decides the outcome.
 *
 * A PREVIOUS run's manifest and active variant survive this write. That matters
 * much more now that promotion is automatic: a model already serving a validated
 * 'web' variant must not be knocked back to a 200k original — the exact GLB the
 * WebView cannot load — because a later re-run of the same recipe failed. The
 * failure is recorded; nothing that already worked is retracted.
 */
async function failOptimizationIfTerminal(
  job: WorkerJob,
  record: IProjectModel,
  err: unknown
): Promise<void> {
  const name = (err as { name?: string })?.name;
  if (name === 'JobCanceledError' || name === 'ClaimLostError') return;

  const isTerminal = err instanceof NonRetryableJobError;
  const attemptsSoFar = job.attempts ?? 0;
  const maxAttempts = job.maxAttempts ?? 3;
  if (!isTerminal && attemptsSoFar + 1 < maxAttempts) return;

  const previous = record.optimized;
  record.optimized = {
    status: 'FAILED',
    pipelineVersion: ASSET_PIPELINE_VERSION,
    ...(previous?.manifest ? { manifest: previous.manifest } : {}),
    ...(previous?.reportKey ? { reportKey: previous.reportKey } : {}),
    // Only meaningful when the preserved manifest actually contains it;
    // resolveActiveModelUrl falls back to the original otherwise.
    activeVariant: previous?.manifest ? (previous.activeVariant ?? 'original') : 'original',
    ...(previous?.variantPinnedByAdmin ? { variantPinnedByAdmin: true } : {}),
    error: {
      code: isTerminal
        ? (err as NonRetryableJobError).code
        : AssetOptimizationErrorCode.SOURCE_UNREADABLE,
      message: err instanceof Error ? err.message : 'Asset optimization failed.',
    },
  };
  record.markModified('optimized');
  await record.save();
}

/** Best-effort live status, on the same reasoning as the Meshy progress writes. */
async function setOptimizationStatus(
  record: IProjectModel,
  status: OptimizedAsset['status']
): Promise<void> {
  try {
    await ProjectModel.updateOne(
      { _id: record._id },
      {
        $set: {
          'optimized.status': status,
          'optimized.pipelineVersion': ASSET_PIPELINE_VERSION,
          'optimized.activeVariant': record.optimized?.activeVariant ?? 'original',
        },
      }
    ).exec();
  } catch {
    // Display-only; the terminal write below supersedes it.
  }
}
