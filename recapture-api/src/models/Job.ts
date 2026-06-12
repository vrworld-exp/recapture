// src/models/Job.ts
import { Schema, model, Document, Types } from 'mongoose';
import { CaptureSummary, CaptureLevels, LevelSummary } from './types/capture.types';
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

  state: JobState;

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
    state: {
      type: String,
      enum: [
        'CREATED',
        'UPLOADING',
        'UPLOADED',
        'QUEUED',
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
    stageProgress: { type: StageProgressSchema },
    captureSummary: { type: CaptureSummarySchema },
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
// (used by the P7 processing worker to find QUEUED jobs, and by admin dashboard
// to find stuck/FAILED jobs)
JobSchema.index({ state: 1, updatedAt: -1 });

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
