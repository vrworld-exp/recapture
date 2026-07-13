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
  compatMaximumPerRing,
  compatMinimumPerRing,
  DEFAULT_CAPTURE_FLOW_VARIANT,
  ringsForVariant,
} from '@/models/types/captureVariants';
import { validateCaptureManifest } from '@/services/manifestValidationService';
import { countObjectsUnderPrefix, getObjectText } from '@/services/s3ObjectStore';
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
  const filesVerified = await countObjectsUnderPrefix(upload.rawBucket, upload.rawPrefix);
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
  const variantRings = [...ringsForVariant(variant)];
  const validation = validateCaptureManifest(parsedManifest, {
    requiredLevels: variantRings,
    allowedLevels: variantRings,
    minPhotosPerLevel: compatMinimumPerRing(variant),
    maxPhotosPerLevel: compatMaximumPerRing(variant),
    expectedFlowVariant: variant,
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
  return { validated: true, filesVerified, ...pipelineResult };
};
