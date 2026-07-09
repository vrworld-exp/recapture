// src/models/Job.ts
import { Schema, model, Document, Types } from 'mongoose';
import {
  CaptureSummary,
  CaptureLevels,
  LevelSummary,
  ObjectSize,
} from './types/capture.types';
import {
  JobState,
  StageProgress,
  ProcessingStage,
  UploadInfo,
  ArtifactsInfo,
  ArtifactCdnUrls,
  DeviceInfo,
  JobError,
} from './types/job.types';
import {
  CAPTURE_FLOW_VARIANTS,
  DEFAULT_CAPTURE_FLOW_VARIANT,
  type CaptureFlowVariant,
} from './types/captureVariants';

// ── Sub-schemas ──────────────────────────────────────────────────────────────

const LevelSummarySchema = new Schema<LevelSummary>(
  {
    photos: { type: Number, required: true, default: 0 },
    coverage: { type: Number, required: true, default: 0, min: 0, max: 100 },
    segmentCount: { type: Number, required: true },
    warnings: { type: Number, required: true, default: 0 },
  },
  { _id: false }
);

const CaptureLevelsSchema = new Schema<CaptureLevels>(
  {
    EYE: { type: LevelSummarySchema, required: true },
    TOP: { type: LevelSummarySchema, required: true },
    LOW: { type: LevelSummarySchema, required: true },
  },
  { _id: false }
);

const CaptureSummarySchema = new Schema<CaptureSummary>(
  {
    levels: { type: CaptureLevelsSchema, required: true },
    totalPhotos: { type: Number, required: true, default: 0 },
    warningsCount: { type: Number, required: true, default: 0 },
  },
  { _id: false }
);

const StageProgressSchema = new Schema<StageProgress>(
  {
    stage: {
      type: String,
      enum: ['QUEUED', 'PROCESSING', 'TEXTURING', 'OPTIMIZING', 'COMPLETED'],
      required: true,
    },
    percent: { type: Number, required: true, min: 0, max: 100, default: 0 },
  },
  { _id: false }
);

const UploadInfoSchema = new Schema<UploadInfo>(
  {
    uploadMethod: {
      type: String,
      enum: ['S3_PRESIGNED_MULTIPART'],
      required: true,
      default: 'S3_PRESIGNED_MULTIPART',
    },
    expectedFilesCount: { type: Number, required: true, default: 0 },
    uploadedFilesCount: { type: Number, required: true, default: 0 },
    checksumAlgo: {
      type: String,
      enum: ['md5', 'none'],
      required: true,
      default: 'md5',
    },
    rawBucket: { type: String, required: true },
    rawPrefix: { type: String, required: true },
    manifestKey: { type: String, required: true },
  },
  { _id: false }
);

const ArtifactCdnUrlsSchema = new Schema<ArtifactCdnUrls>(
  {
    glb: { type: String },
    usdz: { type: String },
    preview: { type: String },
  },
  { _id: false }
);

const ArtifactsInfoSchema = new Schema<ArtifactsInfo>(
  {
    glbKey: { type: String },
    usdzKey: { type: String },
    reportKey: { type: String },
    previewImageKey: { type: String },
    cdnUrls: { type: ArtifactCdnUrlsSchema },
  },
  { _id: false }
);

const DeviceInfoSchema = new Schema<DeviceInfo>(
  {
    platform: {
      type: String,
      enum: ['android', 'ios'],
      required: true,
    },
    model: { type: String, required: true },
    osVersion: { type: String, required: true },
    appVersion: { type: String, required: true },
  },
  { _id: false }
);

const JobErrorSchema = new Schema<JobError>(
  {
    code: { type: String, required: true },
    message: { type: String, required: true },
    details: { type: String },
  },
  { _id: false }
);

// ── Main Job schema ───────────────────────────────────────────────────────────

/**
 * A processing job — one attempt (version) at generating a 3D model
 * for a project. A project can have multiple jobs over time (re-captures).
 */
export interface IJob extends Document {
  projectId: Types.ObjectId;
  userId: Types.ObjectId;

  /** Manifest/protocol version — used to handle schema evolution gracefully */
  protocolVersion: string;

  /**
   * Object size preset the capture used — snapshotted from the project at job
   * creation (POST /jobs cross-checks the client's value against the project)
   * so later file-count/coverage validation reads the job, not a project that
   * may have changed.
   */
  objectSize?: ObjectSize;

  /**
   * Capture flow variant the session used (with_bottom → EYE/TOP/LOW,
   * without_bottom → EYE/TOP) — set at job creation from the client's request
   * (defaulted for pre-variant clients) and consulted by the upload-urls key
   * containment and finalize's manifest validation. Jobs predating the field
   * read as the default via the schema default.
   */
  captureVariant: CaptureFlowVariant;

  /**
   * Client-supplied idempotency key (`Idempotency-Key` header on POST /jobs),
   * unique per user when present — a retried create resolves to this job
   * instead of inserting a duplicate.
   */
  idempotencyKey?: string;

  state: JobState;

  // ── Worker queue fields (P7 background worker — src/worker/) ───────────────
  // The Job document IS the queue entry: finalize's QUEUED flip is the enqueue,
  // and the worker claims work with an atomic conditional findOneAndUpdate.

  /** Discriminator the worker's processor registry dispatches on. */
  jobType: string;

  /** Claim ordering — higher is picked first (FIFO within a priority). */
  priority: number;

  /** Processing attempts consumed so far (incremented on each failure). */
  attempts: number;

  /** Attempts allowed before the job goes terminally FAILED. */
  maxAttempts: number;

  /** Message of the most recent processing failure (also on retried jobs). */
  lastError?: string | null;

  /** Lease start of the current claim — stale-claim recovery compares this. */
  claimedAt?: Date | null;

  /** Worker instance id (`worker-{host}-{pid}`) holding the current claim. */
  claimedBy?: string | null;

  /** Earliest instant a failed-and-requeued job may be claimed again. */
  nextRetryAt?: Date | null;

  /** When processing of the current/most recent attempt began. */
  startedAt?: Date | null;

  /** When the job reached COMPLETED. */
  completedAt?: Date | null;

  /** Processor return value — stub/diagnostic output (real artifacts go in `artifacts`). */
  result?: Record<string, unknown> | null;

  /** Live progress within the current processing stage (P7 worker updates this) */
  stageProgress?: StageProgress;

  /** Summary extracted from the manifest after upload finalization */
  captureSummary?: CaptureSummary;

  /** Upload tracking — populated at job creation, updated during upload */
  upload?: UploadInfo;

  /** Processed artifact pointers — populated on COMPLETED */
  artifacts?: ArtifactsInfo;

  /** Structured error info — populated on FAILED */
  error?: JobError;

  /** When the job entered the processing queue (set by POST /jobs/:id/finalize) */
  queuedAt?: Date;

  /** Device that created this job — for debugging capture quality issues */
  deviceInfo?: DeviceInfo;

  createdAt: Date;
  updatedAt: Date;
}

const JobSchema = new Schema<IJob>(
  {
    projectId: {
      type: Schema.Types.ObjectId,
      ref: 'Project',
      required: true,
    },
    userId: {
      type: Schema.Types.ObjectId,
      ref: 'User',
      required: true,
    },
    protocolVersion: {
      type: String,
      required: true,
      default: 'v1.0',
    },
    objectSize: {
      type: String,
      enum: ['SMALL', 'MEDIUM', 'LARGE'],
    },
    captureVariant: {
      type: String,
      enum: CAPTURE_FLOW_VARIANTS,
      required: true,
      default: DEFAULT_CAPTURE_FLOW_VARIANT,
    },
    idempotencyKey: {
      type: String,
      maxlength: 128,
    },
    state: {
      type: String,
      enum: [
        'CREATED',
        'UPLOADING',
        'UPLOADED',
        'QUEUED',
        'CLAIMED',
        'PROCESSING',
        'TEXTURING',
        'OPTIMIZING',
        'COMPLETED',
        'FAILED',
        'CANCELED',
      ],
      default: 'CREATED',
      required: true,
    },
    jobType: { type: String, required: true, default: 'CAPTURE_PROCESSING' },
    priority: { type: Number, required: true, default: 0 },
    attempts: { type: Number, required: true, default: 0 },
    maxAttempts: { type: Number, required: true, default: 3 },
    lastError: { type: String, default: null },
    claimedAt: { type: Date, default: null },
    claimedBy: { type: String, default: null },
    nextRetryAt: { type: Date, default: null },
    startedAt: { type: Date, default: null },
    completedAt: { type: Date, default: null },
    result: { type: Schema.Types.Mixed, default: null },
    stageProgress: { type: StageProgressSchema },
    captureSummary: { type: CaptureSummarySchema },
    queuedAt: { type: Date },
    upload: { type: UploadInfoSchema },
    artifacts: { type: ArtifactsInfoSchema },
    error: { type: JobErrorSchema },
    deviceInfo: { type: DeviceInfoSchema },
  },
  {
    timestamps: true, // adds createdAt, updatedAt automatically
  }
);

// ── Indexes ────────────────────────────────────────────────────────────────
// Primary query pattern: "list all jobs (versions) for a project, newest first"
JobSchema.index({ projectId: 1, createdAt: -1 });

// Secondary query pattern: "list all jobs created by a user" (admin/debugging)
JobSchema.index({ userId: 1, createdAt: -1 });

// Ops monitoring query pattern: "find all jobs in a given state, oldest first"
// (admin dashboard: stuck/FAILED jobs)
JobSchema.index({ state: 1, updatedAt: -1 });

// Worker claim query (src/worker/jobQueue.ts claimNextJob): covers the exact
// filter+sort shape of the atomic claim — state match, retry-window check,
// priority-then-FIFO ordering — so every poll is an index walk, never a
// collection scan.
JobSchema.index({ state: 1, priority: -1, nextRetryAt: 1, createdAt: 1 });

// Idempotent create (POST /jobs): at most ONE job per (user, Idempotency-Key).
// Partial so the many jobs created WITHOUT a key never collide — uniqueness
// applies only where the key exists. The unique index is the race authority: a
// concurrent duplicate create loses with E11000 and is resolved to a replay.
JobSchema.index(
  { userId: 1, idempotencyKey: 1 },
  { unique: true, partialFilterExpression: { idempotencyKey: { $exists: true } } }
);

export const Job = model<IJob>('Job', JobSchema);

// Re-export shared types for convenience — controllers/services can import
// from '../models/Job' instead of reaching into models/types/ directly.
export type {
  JobState,
  StageProgress,
  ProcessingStage,
  UploadInfo,
  ArtifactsInfo,
  ArtifactCdnUrls,
  DeviceInfo,
  JobError,
  CaptureSummary,
  CaptureLevels,
  LevelSummary,
};
