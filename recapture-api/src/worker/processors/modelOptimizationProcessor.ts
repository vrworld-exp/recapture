// src/worker/processors/modelOptimizationProcessor.ts
//
// The MODEL_OPTIMIZATION processor: take a SUCCEEDED model's GLB, run it
// through the glTF-Transform pipeline (services/modelOptimizerService.ts), and
// write the result back as the OPT record's own artifacts.
//
// Shaped closely on meshyModelProcessor — same fenced-stage entry, same
// best-effort progress writes, same terminal-vs-retry error routing — with two
// deliberate differences:
//
//   • NO MONEY CONTRACT. Optimization spends CPU, not Meshy credits, so there
//     is no equivalent of the persisted meshyTaskId. A re-run simply redoes the
//     work; the artifact keys are deterministic per OPT record, so the re-host
//     OVERWRITES rather than duplicating (exactly the guarantee the Meshy
//     re-host relies on).
//   • THE SOURCE RECORD IS READ-ONLY. Everything this processor writes goes on
//     the OPT record. The original model must come out of an optimization
//     byte-for-byte identical, whether the run succeeded or failed.
import { BUCKET_ARTIFACTS, CLOUDFRONT_BASE } from '@/config/s3';
import { env } from '@/config/env';
import { Job } from '@/models/Job';
import { ProjectModel, type IProjectModel } from '@/models/ProjectModel';
import type { ModelArtifacts } from '@/models/types/projectModel.types';
import {
  ModelOptimizeError,
  optimizeGlb,
  type OptimizeGlbResult,
} from '@/services/modelOptimizerService';
import { copyObject, getObjectBytes, putObjectBytes } from '@/services/s3ObjectStore';
import { track, AnalyticsEvent } from '@/utils/analytics';
import { hashIdentifier } from '@/utils/otp';
import {
  clearProgress,
  failRecordIfTerminal,
  reportProgress,
  setStatus,
} from '@/worker/processors/modelRecordState';
import { enterStage } from '@/worker/stageTransitions';
import { log } from '@/worker/workerLog';
import { NonRetryableJobError, type JobProcessor } from '@/worker/workerTypes';

/**
 * The smallest win worth keeping, as a fraction of the source size. An output
 * at 95% of the input is a second row in the model list, a second artifact
 * prefix and a second thing to explain — for a saving nobody can perceive on a
 * download. Below this bar the record fails terminally with a plain reason
 * instead of succeeding into clutter.
 *
 * JUDGMENT CALL, flagged in the PR: if it turns out that even a 5% saving is
 * wanted, deleting this check is a one-line reversal.
 */
const MIN_SAVING_RATIO = 0.95;

/** Stable error codes this processor can put on a record. */
export const ModelOptimizationErrorCode = {
  JOB_MALFORMED: 'OPTIMIZE_JOB_MALFORMED',
  RECORD_MISSING: 'OPTIMIZE_RECORD_MISSING',
  SOURCE_MISSING: 'OPTIMIZE_SOURCE_MISSING',
  INEFFECTIVE: 'OPTIMIZATION_INEFFECTIVE',
} as const;

/** Per-model artifact prefix — the OPT record gets its OWN, so the source's
 * artifacts are never in the blast radius of a re-host. */
function modelArtifactPrefix(rawPrefix: string, modelId: string): string {
  return `${rawPrefix}models/${modelId}/`;
}

export const modelOptimizationProcessor: JobProcessor = async (job) => {
  const claimedBy = job.claimedBy;
  const modelId = (job.payload as { modelId?: unknown } | undefined)?.modelId;
  if (!claimedBy || typeof modelId !== 'string') {
    // Malformed by construction — requestModelOptimization always writes
    // payload.modelId and the loop always stamps claimedBy. Retrying can fix
    // neither.
    throw new NonRetryableJobError(
      ModelOptimizationErrorCode.JOB_MALFORMED,
      'Optimization job is missing its claim or payload.modelId.'
    );
  }

  const record = await ProjectModel.findById(modelId).exec();
  if (!record) {
    throw new NonRetryableJobError(
      ModelOptimizationErrorCode.RECORD_MISSING,
      'The model record this job was enqueued for no longer exists.'
    );
  }

  // EVERYTHING from here on runs inside the try, so that every terminal error
  // reaches failRecordIfTerminal. A record left QUEUED after a terminal failure
  // is not merely untidy: `optimizedSourceIdsFor` counts QUEUED as a live
  // child, so it would permanently remove the Optimize button from the source
  // model with no way back.
  try {
    const source = record.optimizedFrom
      ? await ProjectModel.findById(record.optimizedFrom).exec()
      : null;
    if (!source?.artifacts?.glbKey) {
      // The source was hard-deleted, or the record was written without one.
      // Neither heals with time.
      throw new NonRetryableJobError(
        ModelOptimizationErrorCode.SOURCE_MISSING,
        'The model this optimization was based on is no longer available.'
      );
    }

    // The capture job only for its rawPrefix — the artifact key space is
    // anchored to it (see meshyModelProcessor.rehostArtifacts), so the OPT
    // record's output lands beside the generation it came from rather than in a
    // namespace of its own invention.
    const captureJob = await Job.findById(record.jobId).exec();
    if (!captureJob?.upload) {
      throw new NonRetryableJobError(
        ModelOptimizationErrorCode.SOURCE_MISSING,
        'The model this optimization was based on is no longer available.'
      );
    }
    const { rawPrefix } = captureJob.upload;

    // Renews the lease and gives the record a stage to be fenced against.
    // PROCESSING is the only stage this job type uses — optimization is one
    // synchronous unit of work, not a pipeline.
    await enterStage(job._id, claimedBy, 'PROCESSING');
    await setStatus(record, 'PROCESSING');
    await reportProgress(record, 'PREPARING', 0);

    const fetched = await getObjectBytes(BUCKET_ARTIFACTS, source.artifacts.glbKey);
    if (fetched.outcome === 'absent') {
      throw new NonRetryableJobError(
        ModelOptimizationErrorCode.SOURCE_MISSING,
        'The model this optimization was based on is no longer available.'
      );
    }
    const sourceBytes = fetched.body.byteLength;

    // Reusing the EXISTING MODEL_PROGRESS_PHASES rather than inventing
    // optimization-specific ones: the client's ModelProgressPhase enum maps
    // exactly these three, and an unknown phase falls back to generic copy —
    // so a new vocabulary would buy nothing and lose the phase-specific line.
    await reportProgress(record, 'GENERATING', 50);
    const result = await runOptimizer(fetched.body);

    if (result.outputBytes >= sourceBytes * MIN_SAVING_RATIO) {
      throw new NonRetryableJobError(
        ModelOptimizationErrorCode.INEFFECTIVE,
        'This model is already close to its smallest size.'
      );
    }

    await reportProgress(record, 'FINALIZING', 100);
    const artifacts = await storeArtifacts(record, source, rawPrefix, result.bytes);

    record.status = 'SUCCEEDED';
    record.artifacts = artifacts;
    record.optimization = {
      sourceBytes,
      outputBytes: result.outputBytes,
      at: new Date(),
    };
    record.error = undefined;
    await record.save();
    await clearProgress(record);

    log('info', 'Model optimized', {
      jobId: job._id,
      modelId,
      sourceModelId: source.id,
      projectId: record.projectId,
      sourceBytes,
      outputBytes: result.outputBytes,
      // A texture pass that could not run is the difference between a 5× and a
      // 1.3× win, so it belongs in the record of what happened.
      degraded: result.degraded,
      overBudget: result.overBudget,
    });
    track(AnalyticsEvent.MODEL_OPTIMIZE_COMPLETED, {
      project_id_hash: hashIdentifier(record.projectId.toHexString()),
      model_id_hash: hashIdentifier(modelId),
      source_bytes: sourceBytes,
      output_bytes: result.outputBytes,
      ...(result.degraded.length > 0 ? { degraded: [...result.degraded] } : {}),
    });
    // Only OUR keys/URLs, same rule as every other artifact writer.
    return { source: 'optimized', modelId, artifacts: artifacts.cdnUrls };
  } catch (err: unknown) {
    await failRecordIfTerminal(
      job,
      record,
      err,
      'OPTIMIZATION_FAILED',
      'Optimizing this model failed.'
    );
    throw err;
  }
};

/**
 * Runs the pipeline, translating its own error type into the worker's.
 *
 * A {@link ModelOptimizeError} is always terminal: an oversized input, an
 * unreadable GLB and a transform that rejects the geometry are all facts about
 * the bytes, and the bytes will be identical on the next attempt. Anything else
 * (an out-of-memory kill, a native crash) escapes as a plain Error and takes
 * the retry path.
 */
async function runOptimizer(bytes: Uint8Array): Promise<OptimizeGlbResult> {
  try {
    return await optimizeGlb(bytes, {
      maxInputBytes: env.MODEL_OPTIMIZE_MAX_INPUT_BYTES,
      budgetBytes: env.MODEL_OPTIMIZE_THRESHOLD_BYTES,
    });
  } catch (err: unknown) {
    if (err instanceof ModelOptimizeError) {
      // The message is one of ours, written to be shown — see ModelOptimizeError.
      throw new NonRetryableJobError(err.code, err.message);
    }
    throw err;
  }
}

/**
 * Writes the OPT record's artifacts under its OWN prefix.
 *
 * The preview and the USDZ are SERVER-SIDE COPIES of the source's, not new
 * files:
 *   • the preview, so the OPT row shows the same thumbnail as the model it came
 *     from instead of a grey placeholder;
 *   • the USDZ, because it is a different format that AR Quick Look consumes
 *     directly and this pipeline does not touch — and because
 *     `latestSucceededModel` now returns THIS record, so without the copy the
 *     iOS AR path would silently go dead the moment a model was optimized.
 *
 * Every key is deterministic per record, so a retried run overwrites rather
 * than accumulating.
 */
async function storeArtifacts(
  record: IProjectModel,
  source: IProjectModel,
  rawPrefix: string,
  bytes: Uint8Array
): Promise<ModelArtifacts> {
  const prefix = modelArtifactPrefix(rawPrefix, record.id as string);

  await putObjectBytes(BUCKET_ARTIFACTS, `${prefix}model.glb`, bytes, 'model/gltf-binary');

  const hasPreview = await copyIfPresent(
    source.artifacts?.previewImageKey,
    `${prefix}preview.jpg`
  );
  const hasUsdz = await copyIfPresent(source.artifacts?.usdzKey, `${prefix}model.usdz`);

  return {
    glbKey: `${prefix}model.glb`,
    glbBytes: bytes.byteLength,
    ...(hasUsdz ? { usdzKey: `${prefix}model.usdz` } : {}),
    ...(hasPreview ? { previewImageKey: `${prefix}preview.jpg` } : {}),
    cdnUrls: {
      glb: `${CLOUDFRONT_BASE}/${prefix}model.glb`,
      ...(hasUsdz ? { usdz: `${CLOUDFRONT_BASE}/${prefix}model.usdz` } : {}),
      ...(hasPreview ? { preview: `${CLOUDFRONT_BASE}/${prefix}preview.jpg` } : {}),
    },
  };
}

/**
 * Copies one optional source artifact, reporting whether it landed.
 *
 * A missing/failed copy is NOT an error: the thumbnail and the USDZ are both
 * enhancements, and losing them must never fail an optimization whose actual
 * product — a much smaller GLB — is already written. The record simply omits
 * the key, which every reader already treats as "this model has none".
 */
async function copyIfPresent(sourceKey: string | undefined, destKey: string): Promise<boolean> {
  if (!sourceKey) return false;
  try {
    await copyObject(BUCKET_ARTIFACTS, sourceKey, destKey);
    return true;
  } catch {
    return false;
  }
}
