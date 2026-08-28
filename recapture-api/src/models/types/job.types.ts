// src/models/types/job.types.ts
//
// Shared TypeScript interfaces for Job document nested fields.
// Used by src/models/Job.ts and referenced by upload/processing services
// implemented in P6 and P7.

/**
 * jobType discriminators — the worker's processor registry dispatches on these,
 * and any query that means "the capture job" must filter by CAPTURE_PROCESSING
 * (a project can now own jobs of more than one type).
 *
 * They live here, beside the Job document's other field vocabularies, rather
 * than in src/worker/: services (which must not import from the worker) need
 * them too. src/worker/workerTypes.ts re-exports DEFAULT_JOB_TYPE for the
 * worker's own call sites.
 */
export const CAPTURE_PROCESSING_JOB_TYPE = 'CAPTURE_PROCESSING';
/** Staff-triggered Meshy AI generation — carries `payload.modelId`, no upload. */
export const MESHY_MODEL_GENERATION_JOB_TYPE = 'MESHY_MODEL_GENERATION';
/**
 * Shrinking an already-generated model's GLB through glTF-Transform. Carries
 * `payload.modelId` (the OPT record), no upload. A peer of the two above —
 * it costs CPU rather than Meshy credits and never touches the capture
 * pipeline.
 */
export const MODEL_OPTIMIZATION_JOB_TYPE = 'MODEL_OPTIMIZATION';
/**
 * An artist's UPLOADED photo set. Holds objects; is never processed.
 *
 * State path: CREATED → UPLOADING (flipped by the existing per-file
 * `/jobs/:jobId/uploads/initiate`) → UPLOADED. It stops there, and in
 * particular it NEVER enters QUEUED — `claimNextJob` only ever matches
 * queued (or lease-expired) rows, so a job that never queues is invisible to the
 * worker. It is doubly invisible now that the claim also filters on jobType,
 * but the state alone is what guarantees it.
 *
 * DELIBERATELY NO PROCESSOR IS REGISTERED FOR THIS TYPE, and a no-op one must
 * not be added: there is nothing to process here, only photos to hold until a
 * human hand-picks 3–4 of them and asks for a Meshy generation. The missing
 * registration is the design, not an oversight.
 *
 * It carries an ordinary `upload` block, which is what makes the admin
 * hard-delete's prefix sweep purge its objects from both buckets for free.
 */
export const PHOTO_UPLOAD_JOB_TYPE = 'PHOTO_UPLOAD';
/**
 * Projecting one catalog onto Mirage. Carries
 * `payload.{catalogId, publishRunId, mode, productIds?}` — no upload, no
 * project. Unlike the three above it does not act on a ProjectModel at all: its
 * unit of work is a CatalogPublishRun, and the run document (not the job) is
 * what the publish screen reads.
 */
export const MIRAGE_CATALOG_PUBLISH_JOB_TYPE = 'MIRAGE_CATALOG_PUBLISH';

/**
 * Job processing lifecycle states.
 * Mirrors the state machine described in the ReCapture PRD, plus the
 * queue-internal CLAIMED state the background worker uses between winning the
 * atomic claim and starting processing (worker-only; never surfaced to the
 * client, which sees QUEUED/PROCESSING around it).
 *
 * Flow: CREATED → UPLOADING → UPLOADED → QUEUED → CLAIMED → PROCESSING
 *       → TEXTURING → OPTIMIZING → COMPLETED
 *                                 ↘ FAILED (from any state)
 *                                 ↘ CANCELED (from CREATED/UPLOADING/UPLOADED)
 *
 * Retry loop (worker): PROCESSING → QUEUED (attempts < maxAttempts, delayed
 * via nextRetryAt) or → FAILED (attempts exhausted).
 */
export type JobState =
  | 'CREATED'
  | 'UPLOADING'
  | 'UPLOADED'
  | 'QUEUED'
  | 'CLAIMED'
  | 'PROCESSING'
  | 'TEXTURING'
  | 'OPTIMIZING'
  | 'COMPLETED'
  | 'FAILED'
  | 'CANCELED';

/**
 * Backend processing pipeline stages — subset of JobState relevant to the
 * processing worker's stageProgress field.
 */
export type ProcessingStage =
  | 'QUEUED'
  | 'PROCESSING'
  | 'TEXTURING'
  | 'OPTIMIZING'
  | 'COMPLETED';

/**
 * The stages that RUN engine work (QUEUED and COMPLETED are rest states).
 * PROCESSING = reconstruction, TEXTURING = texturing, OPTIMIZING = optimization
 * — each delegated to the reconstruction-engine adapter (src/worker/engine/).
 */
export type ExecutableStage = 'PROCESSING' | 'TEXTURING' | 'OPTIMIZING';

/**
 * Live progress within the current processing stage.
 * Updated by the processing worker (P7) as it advances.
 *
 * `stage` is the pipeline's DURABLE stage pointer — unlike the Job's `state`
 * (which the queue mechanics bounce through CLAIMED/PROCESSING on every
 * claim), stageProgress survives claim/re-claim/re-queue untouched, so a
 * resumed or retried job re-enters exactly the stage that was running when it
 * crashed or failed.
 */
export interface StageProgress {
  stage: ProcessingStage;

  /** Progress within the current stage, 0-100 */
  percent: number;
}

/** Start/end instants of one executable stage's most recent run. */
export interface StageWindow {
  startedAt?: Date;
  completedAt?: Date;
}

/**
 * Per-stage timing, written atomically with each stage transition.
 * A stage that was re-run (crash resume / retry) keeps the LATEST window.
 */
export type StageTimestamps = Partial<Record<ExecutableStage, StageWindow>>;

/**
 * Upload tracking metadata for a job's raw capture bundle.
 * Populated when the job is created (P6 Upload Pipeline).
 */
export interface UploadInfo {
  uploadMethod: 'S3_PRESIGNED_MULTIPART';

  /** Total files expected (all images across the job's capture-variant rings
   * + manifest.json) */
  expectedFilesCount: number;

  /** Files successfully uploaded to S3 so far */
  uploadedFilesCount: number;

  /** Checksum algorithm used for upload integrity verification */
  checksumAlgo: 'md5' | 'none';

  /** S3 bucket name for raw captures — always 'msxr-raw-captures' */
  rawBucket: string;

  /**
   * S3 key prefix for this job's raw files, e.g.
   * 'prod/{projectSlug}_{projectId}/{jobId}/'. Written ONCE at job creation from
   * the canonical builder and read back everywhere after — never rebuilt, so a
   * change to the key scheme leaves existing jobs pointing at their own objects.
   */
  rawPrefix: string;

  /**
   * S3 key for the capture_manifest.json file.
   *
   * OPTIONAL because a PHOTO_UPLOAD job has no manifest — an uploaded photo set
   * carries no rings, no blur/yaw scores and nothing to validate ring-by-ring.
   * Every CAPTURE job still gets one at creation (jobsService.createJob), and
   * the readers that need it (finalize, the capture processor, the auto-photo
   * selector) treat its absence as `manifest_missing` rather than assuming a
   * placeholder key that points at no object.
   */
  manifestKey?: string;
}

/**
 * CDN-served URLs for processed artifacts.
 * Always CloudFront URLs — never raw S3 URLs (security requirement).
 */
export interface ArtifactCdnUrls {
  glb?: string;
  usdz?: string;
  preview?: string;
}

/**
 * Processed artifact S3 keys and CDN URLs.
 * Populated by the processing worker (P7) on job completion.
 */
export interface ArtifactsInfo {
  /** S3 key for the GLB model file (mandatory output format) */
  glbKey?: string;

  /** S3 key for the USDZ model file (iOS only, optional) */
  usdzKey?: string;

  /** S3 key for the quality_report.json diagnostics file */
  reportKey?: string;

  /** S3 key for the preview thumbnail image */
  previewImageKey?: string;

  /** CDN URLs derived from the keys above — convenience for API responses */
  cdnUrls?: ArtifactCdnUrls;
}

/**
 * Device information captured by the mobile app at job creation time.
 * Used for debugging device-specific capture quality issues.
 */
export interface DeviceInfo {
  platform: 'android' | 'ios';

  /** Device model identifier, e.g. 'iPhone15,2' or 'SM-A536E' */
  model: string;

  /** OS version string, e.g. '17.2' or '13' */
  osVersion: string;

  /** ReCapture app version, e.g. '1.0.3' */
  appVersion: string;
}

/**
 * Structured error information for FAILED jobs.
 * code is a stable identifier for categorizing failures (used in analytics
 * and admin dashboard filtering).
 */
export interface JobError {
  /**
   * Stable error code. Examples:
   *   'MANIFEST_INVALID' | 'MANIFEST_MISSING' | 'FILE_COUNT_MISMATCH'
   *   'PROCESSING_TIMEOUT' | 'PROCESSING_FAILED' | 'INSUFFICIENT_COVERAGE'
   */
  code: string;

  /** Human-readable message shown to the user (via app's Processing Failed screen) */
  message: string;

  /** Pipeline stage the failure happened in (when it happened inside one). */
  stage?: ExecutableStage;

  /** Optional technical details — stack trace, worker logs excerpt (admin-only) */
  details?: string;
}
