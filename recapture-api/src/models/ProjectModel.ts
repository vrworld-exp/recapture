// src/models/ProjectModel.ts
//
// One record per 3D-model GENERATION attempt on a project.
//
// HISTORY, not upsert: every staff "Create Model" tap inserts a new record, so
// an artist can regenerate from different photos, compare the attempts, and
// `approved` the best one. Nothing here is ever overwritten by a later attempt.
//
// This model is ADDITIVE to the capture pipeline: it does not replace
// Job.artifacts (the in-house path's output) and nothing in the capture
// processing pipeline reads or writes it.
import { Schema, model, Document, Types } from 'mongoose';
import { USER_ROLES, type UserRole } from '@/models/User';
import {
  MODEL_SOURCES,
  MODEL_STATUSES,
  type ModelApproval,
  type ModelArtifacts,
  type ModelCdnUrls,
  type ModelError,
  type ModelSource,
  type ModelStatus,
} from '@/models/types/projectModel.types';

export interface IProjectModel extends Document {
  /** The project this model belongs to. */
  projectId: Types.ObjectId;
  /** The CAPTURE job whose photos were used (not the generation queue job). */
  jobId: Types.ObjectId;
  source: ModelSource;
  status: ModelStatus;
  /** The 3–4 RELATIVE export-manifest keys the staff user picked. */
  selectedKeys: string[];
  /**
   * Meshy's task id, persisted the INSTANT the task is created. This single
   * field is what makes a crash/re-claim cost zero extra credits: the processor
   * resumes polling this task instead of submitting a second one. Never a URL.
   */
  meshyTaskId?: string;
  /** Populated on SUCCEEDED — our S3 keys + CloudFront URLs only. */
  artifacts?: ModelArtifacts;
  /** The "we're satisfied, skip manual creation" gate. SUCCEEDED records only. */
  approved?: ModelApproval;
  /** Populated on FAILED. */
  error?: ModelError;
  /** Client-supplied Idempotency-Key — unique per actor when present. */
  idempotencyKey?: string;
  /**
   * Who the generation is attributed to. For a staff "Create Model" tap this is
   * the staff actor; for an AUTOMATIC generation there is no actor, so it is the
   * project OWNER — the person whose capture caused the spend. That keeps the
   * audit trail truthful and gives the per-user daily cap a real subject.
   */
  createdByUserId: Types.ObjectId;
  /** Their role at request time — audit trail (ADMIN vs MODEL_ARTIST). */
  createdByRole: UserRole;
  /**
   * True when the worker started this generation itself after a capture
   * finished, rather than a human requesting it. Drives the owner-facing
   * "AI generated" badge and the regenerate affordance, and distinguishes a
   * system spend from a staff spend in any later cost audit.
   */
  createdBySystem?: boolean;
  createdAt: Date;
  updatedAt: Date;
}

const ModelCdnUrlsSchema = new Schema<ModelCdnUrls>(
  {
    glb: { type: String, required: true },
    usdz: { type: String },
    preview: { type: String },
  },
  { _id: false }
);

const ModelArtifactsSchema = new Schema<ModelArtifacts>(
  {
    glbKey: { type: String, required: true },
    usdzKey: { type: String },
    previewImageKey: { type: String },
    cdnUrls: { type: ModelCdnUrlsSchema, required: true },
  },
  { _id: false }
);

const ModelApprovalSchema = new Schema<ModelApproval>(
  {
    at: { type: Date, required: true },
    byUserId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
  },
  { _id: false }
);

const ModelErrorSchema = new Schema<ModelError>(
  {
    code: { type: String, required: true },
    message: { type: String, required: true },
  },
  { _id: false }
);

const ProjectModelSchema = new Schema<IProjectModel>(
  {
    projectId: { type: Schema.Types.ObjectId, ref: 'Project', required: true },
    jobId: { type: Schema.Types.ObjectId, ref: 'Job', required: true },
    source: { type: String, enum: MODEL_SOURCES, required: true },
    status: { type: String, enum: MODEL_STATUSES, required: true, default: 'QUEUED' },
    selectedKeys: { type: [String], required: true },
    meshyTaskId: { type: String },
    artifacts: { type: ModelArtifactsSchema },
    approved: { type: ModelApprovalSchema },
    error: { type: ModelErrorSchema },
    idempotencyKey: { type: String, maxlength: 128 },
    createdByUserId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    createdByRole: { type: String, enum: USER_ROLES, required: true },
    createdBySystem: { type: Boolean },
  },
  { timestamps: true }
);

// Primary query path: "this project's generation history, newest first" — the
// staff history list AND the owner detail's latest-SUCCEEDED lookup.
ProjectModelSchema.index({ projectId: 1, createdAt: -1 });

// Idempotent create (POST /admin/projects/:id/model): at most ONE record per
// (actor, Idempotency-Key). Partial so the records created WITHOUT a key never
// collide. Mirrors the Job model's create-idempotency index exactly — the unique
// index is the race authority: a concurrent double-tap loses with E11000 and is
// resolved to a replay of the winner rather than a second paid generation.
ProjectModelSchema.index(
  { createdByUserId: 1, idempotencyKey: 1 },
  { unique: true, partialFilterExpression: { idempotencyKey: { $exists: true } } }
);

export const ProjectModel = model<IProjectModel>('ProjectModel', ProjectModelSchema);

export {
  MODEL_SOURCES,
  MODEL_STATUSES,
  type ModelApproval,
  type ModelArtifacts,
  type ModelCdnUrls,
  type ModelError,
  type ModelSource,
  type ModelStatus,
};
