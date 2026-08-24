// src/models/Project.ts
import { Schema, model, Document, Types } from 'mongoose';
import { ObjectSize } from './types/capture.types';

/**
 * Summary statistics for a project, aggregated from its jobs.
 * Updated whenever a capture session completes or a job finishes processing.
 */
export interface ProjectStats {
  /** Total photos captured across all levels in the latest/active job */
  totalPhotos: number;

  /** Total quality warnings across all levels */
  warnings: number;

  /** Timestamp of the most recent capture session activity */
  lastCaptureAt?: Date;
}

const ProjectStatsSchema = new Schema<ProjectStats>(
  {
    totalPhotos: { type: Number, default: 0 },
    warnings: { type: Number, default: 0 },
    lastCaptureAt: { type: Date },
  },
  { _id: false } // embedded sub-document — no separate _id needed
);

/** The full status vocabulary as a value — the schema enum, the admin list's
 * `?status=` filter, and analytics all derive from this ONE array. */
export const PROJECT_STATUS_VALUES = [
  'DRAFT',
  'CAPTURING',
  'UPLOADING',
  'PROCESSING',
  'COMPLETED',
  'FAILED',
] as const;

export type ProjectStatus = (typeof PROJECT_STATUS_VALUES)[number];

/**
 * Where a project's photos come from — a property of the PROJECT, deliberately
 * NOT a new ProjectStatus.
 *
 * `capture`  the guided in-app capture flow: rings, a capture manifest, an
 *            object size and a capture mode.
 * `upload`   an artist's hand-picked photo set, uploaded from the gallery over
 *            the same presigned-multipart transport. It has no rings and no
 *            manifest, which is why `objectSize`/`mode` are not required on it
 *            and why server-side photo AUTO-selection cannot run for it (see
 *            onDemandModelGenerationService's AUTO_SELECTION_UNAVAILABLE).
 *
 * The schema default backfills every pre-existing document as `capture` on
 * read, so this field needs NO migration — the same pattern `User.role`,
 * `Job.captureVariant` and `Job.captureMode` already use.
 */
export const PROJECT_SOURCE_VALUES = ['capture', 'upload'] as const;

export type ProjectSource = (typeof PROJECT_SOURCE_VALUES)[number];

/** How the capture session is driven (mirrors the app's CaptureMode). */
export type CaptureMode = 'GUIDED' | 'MANUAL';

/**
 * A user's capture project — the logical container for capturing one
 * physical object across one or more job versions.
 */
export interface IProject extends Document {
  userId: Types.ObjectId;
  name: string;
  /**
   * CONDITIONALLY required: present on a `capture` project, absent on an
   * `upload` one. Both drive camera-distance guidance and a capture flow an
   * uploaded photo set never enters, so writing a placeholder `MEDIUM` would be
   * a lie that later reads act on.
   */
  objectSize?: ObjectSize;
  /** Conditionally required — see {@link IProject.objectSize}. */
  mode?: CaptureMode;
  category?: string;
  /** Photo origin. Defaults to `capture` for every document written before
   * this field existed (schema default — no migration). */
  source: ProjectSource;
  status: ProjectStatus;
  /** When `status` last changed — written on EVERY transition (see
   * projectsService.updateProjectStatus); null until the first transition. */
  statusUpdatedAt?: Date | null;
  activeJobId?: Types.ObjectId;
  latestCompletedJobId?: Types.ObjectId;
  stats?: ProjectStats;
  deletedAt?: Date;
  createdAt: Date;
  updatedAt: Date;
}

const ProjectSchema = new Schema<IProject>(
  {
    userId: {
      type: Schema.Types.ObjectId,
      ref: 'User',
      required: true,
    },
    name: {
      type: String,
      required: true,
      trim: true,
      maxlength: 100,
    },
    // Conditionally required — the exact idiom Job.projectId already uses. An
    // upload project has neither, and `required: true` would make one
    // unwritable without a placeholder value nothing means.
    objectSize: {
      type: String,
      enum: ['SMALL', 'MEDIUM', 'LARGE'],
      required(this: IProject) {
        return this.source !== 'upload';
      },
    },
    mode: {
      type: String,
      enum: ['GUIDED', 'MANUAL'],
      required(this: IProject) {
        return this.source !== 'upload';
      },
    },
    source: {
      type: String,
      enum: PROJECT_SOURCE_VALUES,
      default: 'capture',
      required: true,
    },
    category: {
      type: String,
      trim: true,
      maxlength: 50,
    },
    status: {
      type: String,
      enum: PROJECT_STATUS_VALUES,
      default: 'DRAFT',
      required: true,
    },
    statusUpdatedAt: {
      type: Date,
      default: null,
    },
    activeJobId: {
      type: Schema.Types.ObjectId,
      ref: 'Job',
    },
    latestCompletedJobId: {
      type: Schema.Types.ObjectId,
      ref: 'Job',
    },
    stats: {
      type: ProjectStatsSchema,
      default: () => ({ totalPhotos: 0, warnings: 0 }),
    },
    deletedAt: {
      type: Date,
    },
  },
  {
    timestamps: true, // adds createdAt, updatedAt automatically
  }
);

// ── Indexes ────────────────────────────────────────────────────────────────
// Primary query pattern: "list a user's projects, most recently updated first".
// `_id` is part of the key so the deterministic tie-breaker (updatedAt DESC,
// _id DESC) used by GET /projects cursor pagination is fully index-backed. This
// also covers the shorter `(userId, updatedAt)` prefix query.
ProjectSchema.index({ userId: 1, updatedAt: -1, _id: -1 });

// Secondary query pattern: "filter a user's projects by status"
// (e.g. show only DRAFT/CAPTURING projects on Projects screen "in progress" section)
ProjectSchema.index({ userId: 1, status: 1 });

// Admin/staff query pattern (GET /admin/projects): cross-USER list filtered by
// status, same deterministic (updatedAt DESC, _id DESC) cursor ordering as the
// owner list — `_id` in the key keeps the tie-breaker index-backed.
ProjectSchema.index({ status: 1, updatedAt: -1, _id: -1 });

export const Project = model<IProject>('Project', ProjectSchema);

// Re-export for convenience — services can import from '../models/Project'.
export type { ObjectSize };
// `CaptureMode` and `ProjectStatus` are already exported above.
