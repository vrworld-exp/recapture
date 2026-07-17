// src/models/types/projectModel.types.ts
//
// Shared types for the ProjectModel document (models/ProjectModel.ts) — one
// record per 3D-model GENERATION attempt on a project.

/**
 * Where a model came from. `meshy` = the staff-triggered Meshy AI generation
 * (docs/meshy-integration-implementation-prompt.md); `manual` is RESERVED for
 * the in-house capture/reconstruction pipeline so both origins can coexist
 * under one shape without a later schema change. This flag is what drives the
 * client's "Created by Meshy AI" badge — never infer origin from anything else.
 */
export const MODEL_SOURCES = ['meshy', 'manual'] as const;
export type ModelSource = (typeof MODEL_SOURCES)[number];

/**
 * Generation lifecycle. Deliberately NOT the Job state machine: a model record
 * tracks the human-visible outcome (is there a model yet?), while the Job
 * document behind it tracks queue mechanics (claims, attempts, backoff). A job
 * that retries bounces QUEUED↔PROCESSING many times; the record stays
 * PROCESSING throughout and only moves on a real outcome.
 */
export const MODEL_STATUSES = ['QUEUED', 'PROCESSING', 'SUCCEEDED', 'FAILED'] as const;
export type ModelStatus = (typeof MODEL_STATUSES)[number];

/** CDN URLs for a generated model. Always OUR CloudFront — never Meshy's. */
export interface ModelCdnUrls {
  glb: string;
  usdz?: string;
  preview?: string;
}

/**
 * The re-hosted result. Meshy's own URLs expire, so the bytes are downloaded
 * and re-uploaded to BUCKET_ARTIFACTS; only our keys/URLs are ever persisted.
 */
export interface ModelArtifacts {
  glbKey: string;
  usdzKey?: string;
  previewImageKey?: string;
  cdnUrls: ModelCdnUrls;
}

/** Who signed off on a generated model, and when. */
export interface ModelApproval {
  at: Date;
  byUserId: import('mongoose').Types.ObjectId;
}

/** Terminal failure detail, mirroring the Job `error` sub-doc's shape. */
export interface ModelError {
  /** Stable code — e.g. MeshyErrorCode.QUOTA_EXHAUSTED. */
  code: string;
  message: string;
}
