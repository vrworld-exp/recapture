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
 *
 * `optimized` is the odd one out and deliberately so: it is not an ORIGIN but a
 * DERIVATIVE — a record produced by re-processing another record's GLB through
 * the glTF-Transform pipeline (services/modelOptimizerService.ts). It costs no
 * Meshy credits, is never a paid generation, and always carries
 * {@link IProjectModel.optimizedFrom}. Anything that means "a generation" must
 * therefore exclude it explicitly — see `pendingOwnerGenerationFor`.
 */
export const MODEL_SOURCES = ['meshy', 'manual', 'optimized'] as const;
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

/**
 * What the worker is doing RIGHT NOW inside a PROCESSING record — the staff
 * screen's live "what is going on" line. Purely informational: no processor
 * logic ever branches on it, and a missing/stale value must never be treated
 * as an error (progress writes are best-effort).
 *   PREPARING  — presigning source photos / submitting the Meshy task;
 *   GENERATING — Meshy is building the model (percent = Meshy's own 0–100);
 *   FINALIZING — downloading results and re-hosting them on our S3.
 */
export const MODEL_PROGRESS_PHASES = ['PREPARING', 'GENERATING', 'FINALIZING'] as const;
export type ModelProgressPhase = (typeof MODEL_PROGRESS_PHASES)[number];

/** Live sub-status of a PROCESSING generation. Cleared on terminal states. */
export interface ModelProgress {
  phase: ModelProgressPhase;
  /** 0–100 within the current phase (Meshy's own number while GENERATING). */
  percent: number;
}

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
  /**
   * Byte length of the GLB in S3. Written when the artifact is stored; the ONLY
   * input to the "is this worth optimizing?" rule (MODEL_OPTIMIZE_THRESHOLD_BYTES).
   *
   * Optional because every record written before this field existed has none —
   * and ABSENT MEANS UNKNOWN, NOT SMALL. Treating a missing size as 0 would
   * silently hide the Optimize button on exactly the large legacy models the
   * feature exists for, so every reader must branch on `undefined` explicitly
   * rather than defaulting it. `listProjectModels` backfills it best-effort.
   */
  glbBytes?: number;
}

/**
 * What one optimization pass achieved, for the UI's "OPT · 4.2 MB (−68%)" label.
 * Present only on a record whose `source` is `optimized`.
 */
export interface ModelOptimization {
  /** GLB size of the SOURCE record at the time the pass ran. */
  sourceBytes: number;
  /** GLB size this record's optimized artifact was written at. */
  outputBytes: number;
  at: Date;
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

// ── Generation trace ─────────────────────────────────────────────────────────
// The record of how a generation was DECIDED — everything that happened inside
// the request, before the worker ever ran. Distinct from `progress`, which is
// the worker's live sub-status: these steps are all over in well under a second
// and are never watched, only read back afterwards.

/**
 * The synchronous steps between "someone asked for a model" and "a job is
 * queued". Ordered as they run.
 */
export const GENERATION_STEP_NAMES = [
  /** Find the newest exportable CAPTURE job for the project. */
  'RESOLVE_JOB',
  /** Fetch + parse capture_manifest.json from S3. */
  'LOAD_MANIFEST',
  /** List the keys actually present under the job prefix. */
  'LIST_OBJECTS',
  /** Run the photo selector — quadrant spread, blur floor, backfill. */
  'SELECT_PHOTOS',
  /** Kill switch, per-job dedupe, rolling 24h ceiling. */
  'GUARDS',
  /** Insert the ProjectModel record and enqueue the worker job. */
  'ENQUEUE',
] as const;
export type GenerationStepName = (typeof GENERATION_STEP_NAMES)[number];

export const GENERATION_STEP_STATUSES = ['OK', 'SKIPPED', 'FAILED'] as const;
export type GenerationStepStatus = (typeof GENERATION_STEP_STATUSES)[number];

/** One decided step. STAFF-SAFE only — see `detail`. */
export interface GenerationStep {
  step: GenerationStepName;
  status: GenerationStepStatus;
  /**
   * One-liner for the staff/dev trace. MAY carry relative keys and counts.
   * NEVER a presigned URL — a presigned URL is a bearer credential and this
   * string is persisted, logged, and rendered.
   */
  detail?: string;
  /** ISO timestamp the step completed. */
  at: string;
  durationMs: number;
}

/** Who asked for the generation — the button, or the capture pipeline. */
export const GENERATION_REQUESTED_BY = ['AUTO', 'MANUAL'] as const;
export type GenerationRequestedBy = (typeof GENERATION_REQUESTED_BY)[number];

/**
 * PERSISTED on the model record rather than returned only in the response.
 *
 * The failure most worth explaining is the one reported an hour later, from a
 * screen that has long since closed; a response-only trace is gone by then. It
 * also lets the progress screen recover the "why these photos" answer after an
 * app restart.
 *
 * STAFF-ONLY. It names our S3 key layout and our pipeline's internals — never
 * serialize it into an owner-facing payload.
 */
export interface ModelGenerationTrace {
  steps: GenerationStep[];
  /**
   * The selector's structured counters (AutoSelectionTrace). Stored loosely
   * because it is a DEBUG artifact whose fields change as the thresholds are
   * tuned — a strict sub-schema would silently strip any field added later,
   * destroying exactly the diagnostic the trace exists to preserve.
   */
  selection?: Record<string, unknown>;
  requestedBy: GenerationRequestedBy;
}
