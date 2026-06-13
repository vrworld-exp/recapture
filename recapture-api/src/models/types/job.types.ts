// src/models/types/job.types.ts
//
// Shared TypeScript interfaces for Job document nested fields.
// Used by src/models/Job.ts and referenced by upload/processing services
// implemented in P6 and P7.

/**
 * Job processing lifecycle states.
 * Mirrors the state machine described in the ReCapture PRD.
 *
 * Flow: CREATED → UPLOADING → UPLOADED → QUEUED → PROCESSING
 *       → TEXTURING → OPTIMIZING → COMPLETED
 *                                 ↘ FAILED (from any state)
 *                                 ↘ CANCELED (from CREATED/UPLOADING/UPLOADED)
 */
export type JobState =
  | 'CREATED'
  | 'UPLOADING'
  | 'UPLOADED'
  | 'QUEUED'
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
 * Live progress within the current processing stage.
 * Updated by the processing worker (P7) as it advances.
 */
export interface StageProgress {
  stage: ProcessingStage;

  /** Progress within the current stage, 0-100 */
  percent: number;
}

/**
 * Upload tracking metadata for a job's raw capture bundle.
 * Populated when the job is created (P6 Upload Pipeline).
 */
export interface UploadInfo {
  uploadMethod: 'S3_PRESIGNED_MULTIPART';

  /** Total files expected (all images across 3 levels + manifest.json) */
  expectedFilesCount: number;

  /** Files successfully uploaded to S3 so far */
  uploadedFilesCount: number;

  /** Checksum algorithm used for upload integrity verification */
  checksumAlgo: 'md5' | 'none';

  /** S3 bucket name for raw captures — always 'msxr-raw-captures' */
  rawBucket: string;

  /** S3 key prefix for this job's raw files, e.g. 'prod/{userId}/{projectId}/{jobId}/' */
  rawPrefix: string;

  /** S3 key for the capture_manifest.json file */
  manifestKey: string;
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

  /** Optional technical details — stack trace, worker logs excerpt (admin-only) */
  details?: string;
}
