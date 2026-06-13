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

export type ProjectStatus =
  | 'DRAFT'
  | 'CAPTURING'
  | 'UPLOADING'
  | 'PROCESSING'
  | 'COMPLETED'
  | 'FAILED';

/**
 * A user's capture project — the logical container for capturing one
 * physical object across one or more job versions.
 */
export interface IProject extends Document {
  userId: Types.ObjectId;
  name: string;
  objectSize: ObjectSize;
  category?: string;
  status: ProjectStatus;
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
    objectSize: {
      type: String,
      enum: ['SMALL', 'MEDIUM', 'LARGE'],
      required: true,
    },
    category: {
      type: String,
      trim: true,
      maxlength: 50,
    },
    status: {
      type: String,
      enum: ['DRAFT', 'CAPTURING', 'UPLOADING', 'PROCESSING', 'COMPLETED', 'FAILED'],
      default: 'DRAFT',
      required: true,
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
// Primary query pattern: "list a user's projects, most recently updated first"
ProjectSchema.index({ userId: 1, updatedAt: -1 });

// Secondary query pattern: "filter a user's projects by status"
// (e.g. show only DRAFT/CAPTURING projects on Projects screen "in progress" section)
ProjectSchema.index({ userId: 1, status: 1 });

export const Project = model<IProject>('Project', ProjectSchema);

// Re-export for convenience — services can import from '../models/Project'.
export type { ObjectSize };
