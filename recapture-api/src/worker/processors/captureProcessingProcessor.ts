// src/worker/processors/captureProcessingProcessor.ts
//
// The CAPTURE_PROCESSING processor: validate the uploaded bundle, then hand
// off to the processing pipeline (captureProcessingPipeline.ts).
//
// The worker loop has already won the atomic QUEUED→CLAIMED claim and flipped
// the job PROCESSING before this runs — that claim is the idempotency /
// concurrency gate (duplicate discovery or a second worker instance can never
// get here for the same job). This processor's own job is DEFENSE-IN-DEPTH:
// finalize verified the same bundle at enqueue time, but S3 is re-checked here
// because objects can change/vanish between enqueue and processing.
//
// Failure semantics:
//   • transient S3/DB errors THROW as-is → worker retry/backoff path;
//   • unfixable bundle problems throw NonRetryableJobError with a stable
//     JobError code → terminal FAILED + error sub-doc, never retried.
import {
  DEFAULT_CAPTURE_FLOW_VARIANT,
  DEFAULT_CAPTURE_MODE,
  photosByRing,
  ringsForVariant,
} from '@/models/types/captureVariants';
import {
  maybeAutoGenerateModel,
  type AutoGenerationOutcome,
} from '@/services/autoModelGenerationService';
import { validateCaptureManifest } from '@/services/manifestValidationService';
import { MODEL_INPUT_KEY_PREFIX } from '@/services/adminProjectsService';
import { getObjectText, listObjectsUnderPrefix } from '@/services/s3ObjectStore';
import { runCaptureProcessing } from '@/worker/processors/captureProcessingPipeline';
import { log } from '@/worker/workerLog';
import { NonRetryableJobError, type JobProcessor } from '@/worker/workerTypes';

export const captureProcessingProcessor: JobProcessor = async (job) => {
  const upload = job.upload;
  if (!upload) {
    // A CAPTURE_PROCESSING job without an upload block can't locate its
    // bundle — malformed by construction (create-job always writes it).
    throw new NonRetryableJobError(
      'MANIFEST_MISSING',
      'Job has no upload block — the bundle location is unknown.'
    );
  }

  // ── Validate 1: the manifest object still exists. getObjectText returns
  // `absent` only on a true 404; transient S3 failures rethrow → retry path.
  const manifestObject = await getObjectText(upload.rawBucket, upload.manifestKey);
  if (manifestObject.outcome === 'absent') {
    throw new NonRetryableJobError(
      'MANIFEST_MISSING',
      'The capture manifest is no longer present in S3.'
    );
  }

  // ── Validate 2: the S3-listed object count under the job's prefix still
  // matches expectedFilesCount exactly (manifest included, same semantics as
  // finalize) — an object deleted since enqueue must not reach the pipeline.
  // The reserved `model-input/` namespace (staff-edited Meshy input copies,
  // written AFTER finalize verified the count) is excluded from the count:
  // those objects are additive session artifacts and must not fail a
  // re-claimed capture job.
  const modelInputPrefix = `${upload.rawPrefix}${MODEL_INPUT_KEY_PREFIX}`;
  const bundleObjects = (
    await listObjectsUnderPrefix(upload.rawBucket, upload.rawPrefix)
  ).filter((object) => !object.key.startsWith(modelInputPrefix));
  const filesVerified = bundleObjects.length;
  // The SAME listing, re-expressed as keys RELATIVE to rawPrefix
  // (`images/EYE/eye_0001.jpg`) — the shape the auto-selection compares its
  // manifest-derived keys against. Absolute bucket keys here would match
  // nothing and silently drop every candidate.
  const availableKeys = bundleObjects
    .filter((object) => object.key.startsWith(upload.rawPrefix))
    .map((object) => object.key.slice(upload.rawPrefix.length));
  if (filesVerified !== upload.expectedFilesCount) {
    throw new NonRetryableJobError(
      'FILE_COUNT_MISMATCH',
      `Expected ${upload.expectedFilesCount} objects under the job prefix but found ${filesVerified}.`
    );
  }

  // ── Validate 3: manifest content rules — the same pure collect-all
  // validator finalize ran, with SERVER-derived expectations from the job's
  // captureVariant (a client-authored manifest never attests its own
  // minimums). Unparseable JSON funnels into MANIFEST_UNREADABLE.
  let parsedManifest: unknown;
  try {
    parsedManifest = JSON.parse(manifestObject.body);
  } catch {
    parsedManifest = undefined; // → MANIFEST_UNREADABLE from the validator
  }
  // Same bounds as finalize: the coverage floor below (a ring completed at
  // MIN_RING_COVERAGE_PCT is a valid capture), the full per-ring count above —
  // both legacy-compatible (compat*) so jobs captured under an older per-ring
  // count revision still process.
  const variant = job.captureVariant ?? DEFAULT_CAPTURE_FLOW_VARIANT;
  const mode = job.captureMode ?? DEFAULT_CAPTURE_MODE;
  const variantRings = [...ringsForVariant(variant, mode)];
  const perRing = photosByRing(variant, mode);
  const validation = validateCaptureManifest(parsedManifest, {
    requiredLevels: variantRings,
    allowedLevels: variantRings,
    minPhotosPerLevel: Math.min(...Object.values(perRing).map((b) => b.min)),
    maxPhotosPerLevel: Math.max(...Object.values(perRing).map((b) => b.max)),
    photosByLevel: perRing,
    expectedFlowVariant: variant,
    expectedCaptureMode: mode,
  });
  if (!validation.valid) {
    throw new NonRetryableJobError(
      'MANIFEST_INVALID',
      `Manifest failed validation: ${validation.errors.map((e) => e.rule).join(', ')}.`,
      JSON.stringify(validation.errors)
    );
  }

  log('info', 'Bundle validated', {
    jobId: job._id,
    projectId: job.projectId,
    filesVerified,
    captureVariant: variant,
  });

  // ── Hand off to the stage pipeline. It owns every stage transition from
  // here (fenced atomic writes via stageTransitions.ts), including the resume
  // entry point for re-claimed/retried jobs; startedAt/claimedBy were stamped
  // by the loop.
  const pipelineResult = await runCaptureProcessing(job, {
    manifest: parsedManifest,
    filesVerified,
  });

  // ── Automatic model generation. STRICTLY LAST, and strictly best-effort.
  //
  // The capture has succeeded and its artifacts are durable by this point. A
  // generation that could not be selected or enqueued is a retryable
  // inconvenience — never a reason to fail a good capture and make the user
  // re-shoot 48 photos. So every error here is swallowed after logging, and the
  // outcome rides along in the job result for observability.
  //
  // Placed here rather than at finalize because the manifest is ALREADY parsed
  // and validated and the object count already verified; selecting at finalize
  // would re-fetch and re-validate the same document purely to pick photos.
  let autoGeneration: AutoGenerationOutcome | undefined;
  try {
    // availableKeys is what stops a manifest entry whose object never landed
    // from becoming a presigned URL that 404s — and burning a paid generation.
    autoGeneration = await maybeAutoGenerateModel({
      job,
      manifest: parsedManifest,
      availableKeys,
    });
    log('info', 'Auto model generation decision', {
      jobId: job._id,
      projectId: job.projectId,
      ...autoGeneration,
    });
  } catch (err: unknown) {
    log('error', 'Auto model generation threw — capture job is unaffected', {
      jobId: job._id,
      error: err instanceof Error ? err.message : String(err),
    });
  }

  return {
    validated: true,
    filesVerified,
    ...pipelineResult,
    ...(autoGeneration ? { autoGeneration } : {}),
  };
};
