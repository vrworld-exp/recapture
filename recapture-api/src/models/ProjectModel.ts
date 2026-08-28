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
  GENERATION_REQUESTED_BY,
  GENERATION_STEP_NAMES,
  GENERATION_STEP_STATUSES,
  MODEL_PROGRESS_PHASES,
  MODEL_SOURCES,
  MODEL_STATUSES,
  type GenerationRequestedBy,
  type GenerationStep,
  type GenerationStepName,
  type GenerationStepStatus,
  type ModelApproval,
  type ModelArtifacts,
  type ModelCdnUrls,
  type ModelError,
  type ModelGenerationTrace,
  type ModelOptimization,
  type ModelProgress,
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
  /**
   * Live sub-status while PROCESSING — what the worker is doing right now, for
   * the staff progress UI. Best-effort (a missed write never fails the job)
   * and cleared when the record reaches a terminal status.
   */
  progress?: ModelProgress;
  /** Populated on SUCCEEDED — our S3 keys + CloudFront URLs only. */
  artifacts?: ModelArtifacts;
  /** The "we're satisfied, skip manual creation" gate. SUCCEEDED records only. */
  approved?: ModelApproval;
  /** Populated on FAILED. */
  error?: ModelError;
  /** Client-supplied Idempotency-Key — unique per actor when present. */
  idempotencyKey?: string;
  /**
   * Set on an OPTIMIZED record: the id of the model it was derived from. A
   * record carrying this is a DERIVATIVE, never a paid generation — it costs no
   * Meshy credits and must be excluded from anything that counts or waits on
   * generations.
   *
   * The UNIQUE PARTIAL INDEX below is what makes "a model is optimized at most
   * once" true: a concurrent double-tap loses with E11000 and is resolved to a
   * replay of the winner, exactly like the Idempotency-Key path.
   */
  optimizedFrom?: Types.ObjectId;
  /** Byte savings of the pass, for the UI's "OPT · 4.2 MB (−68%)" label. */
  optimization?: ModelOptimization;
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
  /**
   * True when a person pressed "Generate 3D model" and the SERVER picked the
   * photos — as opposed to a staff selection made by hand in the gallery.
   *
   * Separate from `createdBySystem` because the two answer different questions:
   * that one is "was a human involved at all" (it drives the owner-facing
   * preview badge), this one is "did the automatic selector choose the input".
   * The 24h ceiling counts BOTH — it is the same money either way.
   */
  createdByManualButton?: boolean;
  /**
   * How this generation was decided: the synchronous steps and the selector's
   * counters. Optional on purpose — every record predates it, so readers must
   * treat it as absent by default. STAFF-ONLY (see ModelGenerationTrace).
   */
  generationTrace?: ModelGenerationTrace;
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
    // Optional: pre-existing records have none, and absent means UNKNOWN size,
    // never "small" — see ModelArtifacts.glbBytes.
    glbBytes: { type: Number, min: 0 },
  },
  { _id: false }
);

const ModelOptimizationSchema = new Schema<ModelOptimization>(
  {
    sourceBytes: { type: Number, required: true, min: 0 },
    outputBytes: { type: Number, required: true, min: 0 },
    at: { type: Date, required: true },
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

const ModelProgressSchema = new Schema<ModelProgress>(
  {
    phase: { type: String, enum: MODEL_PROGRESS_PHASES, required: true },
    percent: { type: Number, required: true, min: 0, max: 100 },
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

const GenerationStepSchema = new Schema<GenerationStep>(
  {
    step: { type: String, enum: GENERATION_STEP_NAMES, required: true },
    status: { type: String, enum: GENERATION_STEP_STATUSES, required: true },
    detail: { type: String },
    at: { type: String, required: true },
    durationMs: { type: Number, required: true },
  },
  { _id: false }
);

const ModelGenerationTraceSchema = new Schema<ModelGenerationTrace>(
  {
    steps: { type: [GenerationStepSchema], required: true },
    // Mixed, NOT a sub-schema: the selector's counters are a debug artifact that
    // gains fields as the thresholds are tuned, and a strict sub-schema would
    // silently drop each new one. See ModelGenerationTrace.selection.
    selection: { type: Schema.Types.Mixed },
    requestedBy: { type: String, enum: GENERATION_REQUESTED_BY, required: true },
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
    progress: { type: ModelProgressSchema },
    artifacts: { type: ModelArtifactsSchema },
    approved: { type: ModelApprovalSchema },
    error: { type: ModelErrorSchema },
    idempotencyKey: { type: String, maxlength: 128 },
    optimizedFrom: { type: Schema.Types.ObjectId, ref: 'ProjectModel' },
    optimization: { type: ModelOptimizationSchema },
    createdByUserId: { type: Schema.Types.ObjectId, ref: 'User', required: true },
    createdByRole: { type: String, enum: USER_ROLES, required: true },
    createdBySystem: { type: Boolean },
    createdByManualButton: { type: Boolean },
    generationTrace: { type: ModelGenerationTraceSchema },
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

// The spend ceiling: "this actor's server-selected generations in the last 24h",
// counted before every automatic AND button-triggered generation.
ProjectModelSchema.index({ createdByUserId: 1, createdAt: -1 });

// "A model is optimized at most once." Partial so the overwhelming majority of
// records — which have no optimizedFrom — never collide. This index is the RACE
// AUTHORITY for the Optimize button exactly as the Idempotency-Key index is for
// Create-Model: two simultaneous taps both try to insert, one wins, and the
// loser's E11000 is resolved to a REPLAY of the winner rather than a second
// (CPU-expensive, duplicate-row-producing) optimization.
ProjectModelSchema.index(
  { optimizedFrom: 1 },
  { unique: true, partialFilterExpression: { optimizedFrom: { $exists: true } } }
);

export const ProjectModel = model<IProjectModel>('ProjectModel', ProjectModelSchema);

export {
  GENERATION_REQUESTED_BY,
  GENERATION_STEP_NAMES,
  GENERATION_STEP_STATUSES,
  MODEL_PROGRESS_PHASES,
  MODEL_SOURCES,
  MODEL_STATUSES,
  type GenerationRequestedBy,
  type GenerationStep,
  type GenerationStepName,
  type GenerationStepStatus,
  type ModelGenerationTrace,
  type ModelApproval,
  type ModelArtifacts,
  type ModelCdnUrls,
  type ModelError,
  type ModelOptimization,
  type ModelProgress,
  type ModelSource,
  type ModelStatus,
};
