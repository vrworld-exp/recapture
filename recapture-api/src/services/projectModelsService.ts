// src/services/projectModelsService.ts
//
// Business logic behind the staff-triggered "Create Model" flow: validate a
// 3–4 photo selection, record the generation request, and enqueue the worker
// job that talks to Meshy (docs/meshy-integration-implementation-prompt.md).
//
// This service is ADDITIVE. It never touches the capture pipeline, finalize, or
// the reconstruction engine — a Meshy generation is a separate, human-triggered
// job type running BESIDE the in-house path, which stays the fallback.
//
// Returns typed result unions the route maps to HTTP (no Express types here),
// per the AGENTS.md routes → services → models layering.
import { Types } from 'mongoose';
import { Project } from '@/models/Project';
import { Job, MESHY_MODEL_GENERATION_JOB_TYPE } from '@/models/Job';
import { ProjectModel, type IProjectModel } from '@/models/ProjectModel';
import type {
  ModelProgressPhase,
  ModelSource,
  ModelStatus,
} from '@/models/types/projectModel.types';
import type { UserRole } from '@/models/User';
import { findExportableJob, isContainedRelativeKey } from '@/services/adminProjectsService';

/**
 * Meshy Multi-Image to 3D accepts 1–4 images. We require a MINIMUM of 3: with
 * fewer views the generative model hallucinates most of the object, and the
 * result is not worth a paid generation. Enforced identically on the client
 * (the Create Model CTA) — this is the authority.
 */
export const MIN_SELECTED_PHOTOS = 3;
export const MAX_SELECTED_PHOTOS = 4;

/** The staff actor requesting or approving a generation. */
export interface ModelActor {
  userId: string;
  role: UserRole;
}

// ── DTOs ─────────────────────────────────────────────────────────────────────

/** Staff-facing model record. Ids are exposed as `id`, never `_id`. */
export interface ProjectModelDto {
  id: string;
  projectId: string;
  jobId: string;
  source: ModelSource;
  status: ModelStatus;
  selectedKeys: string[];
  /**
   * Live worker sub-status for a PROCESSING record — drives the staff progress
   * UI ("Generating 3D model · 45%"). Absent on terminal records and on records
   * written before this field existed, so clients must treat it as optional.
   */
  progress?: { phase: ModelProgressPhase; percent: number };
  artifacts?: { glb: string; usdz?: string; preview?: string };
  approved?: { at: string };
  error?: { code: string; message: string };
  createdAt: string;
  updatedAt: string;
}

/**
 * OWNER-facing model. Deliberately smaller than the staff DTO: the URL, the
 * origin flag that drives the "Created by Meshy AI" badge, and whether it is
 * approved — nothing else. No S3 keys, no selectedKeys, no staff actor ids, no
 * meshyTaskId: an owner must not learn our key layout or who curated their
 * project.
 */
export interface OwnerModelDto {
  id: string;
  source: ModelSource;
  glbUrl: string;
  usdzUrl?: string;
  previewUrl?: string;
  approved: boolean;
  createdAt: string;
}

export function toProjectModelDto(record: IProjectModel): ProjectModelDto {
  return {
    id: record.id as string,
    projectId: record.projectId.toHexString(),
    jobId: record.jobId.toHexString(),
    source: record.source,
    status: record.status,
    selectedKeys: record.selectedKeys,
    // Only meaningful while pending: a terminal record's progress is cleared by
    // the worker, and clients ignore it for terminal statuses regardless.
    ...(record.progress
      ? { progress: { phase: record.progress.phase, percent: record.progress.percent } }
      : {}),
    // Only our CloudFront URLs ever leave this service — never an S3 key and
    // never a (long-expired) Meshy URL.
    ...(record.artifacts
      ? {
          artifacts: {
            glb: record.artifacts.cdnUrls.glb,
            ...(record.artifacts.cdnUrls.usdz ? { usdz: record.artifacts.cdnUrls.usdz } : {}),
            ...(record.artifacts.cdnUrls.preview
              ? { preview: record.artifacts.cdnUrls.preview }
              : {}),
          },
        }
      : {}),
    ...(record.approved ? { approved: { at: record.approved.at.toISOString() } } : {}),
    ...(record.error ? { error: { code: record.error.code, message: record.error.message } } : {}),
    createdAt: record.createdAt.toISOString(),
    updatedAt: record.updatedAt.toISOString(),
  };
}

function toOwnerModelDto(record: IProjectModel): OwnerModelDto | null {
  if (!record.artifacts) return null;
  return {
    id: record.id as string,
    source: record.source,
    glbUrl: record.artifacts.cdnUrls.glb,
    ...(record.artifacts.cdnUrls.usdz ? { usdzUrl: record.artifacts.cdnUrls.usdz } : {}),
    ...(record.artifacts.cdnUrls.preview ? { previewUrl: record.artifacts.cdnUrls.preview } : {}),
    approved: record.approved !== undefined,
    createdAt: record.createdAt.toISOString(),
  };
}

// ── Create ───────────────────────────────────────────────────────────────────

export interface CreateMeshyModelRequestInput {
  projectId: string;
  /** RELATIVE export-manifest keys, exactly as the Preview gallery holds them. */
  keys: string[];
  actor: ModelActor;
  /** `Idempotency-Key` header, when the client sent one. */
  idempotencyKey?: string;
}

export type CreateMeshyModelResult =
  | { outcome: 'PROJECT_NOT_FOUND' }
  | { outcome: 'NOT_EXPORTABLE' }
  /** Selection size outside [MIN_SELECTED_PHOTOS, MAX_SELECTED_PHOTOS] AFTER dedupe. */
  | { outcome: 'INVALID_COUNT'; count: number }
  /** A key escapes the job prefix — the whole request is refused. */
  | { outcome: 'INVALID_KEY'; key: string }
  /** A record already existed for this (actor, Idempotency-Key) — NOT re-enqueued. */
  | { outcome: 'REPLAYED'; model: IProjectModel }
  | { outcome: 'CREATED'; model: IProjectModel };

/**
 * Validates a staff photo selection and enqueues one Meshy generation.
 *
 * Order matters for the money contract: the ProjectModel record is inserted
 * FIRST (the unique (actor, Idempotency-Key) index is the race authority — a
 * double-tap loses here with E11000 and replays the winner instead of paying
 * twice), and only then is the worker job enqueued. A crash between the two
 * leaves a QUEUED record with no job — visible and re-requestable — which is
 * strictly better than a job whose record does not exist yet.
 *
 * The keys are resolved against the SAME exportable job the export and
 * soft-delete paths use, and validated with the SAME containment rule, so a
 * caller can only ever select photos it can already see.
 */
export async function createMeshyModelRequest(
  input: CreateMeshyModelRequestInput
): Promise<CreateMeshyModelResult> {
  const { projectId, actor, idempotencyKey } = input;

  const project = await Project.findOne({
    _id: new Types.ObjectId(projectId),
    deletedAt: null,
  }).exec();
  if (!project) return { outcome: 'PROJECT_NOT_FOUND' };

  const job = await findExportableJob(projectId);
  if (!job || !job.upload) return { outcome: 'NOT_EXPORTABLE' };

  // Dedupe before counting: selecting the same photo twice is a 2-photo
  // selection, and sending Meshy a duplicate image wastes a view slot.
  const keys = [...new Set(input.keys)];
  if (keys.length < MIN_SELECTED_PHOTOS || keys.length > MAX_SELECTED_PHOTOS) {
    return { outcome: 'INVALID_COUNT', count: keys.length };
  }
  for (const key of keys) {
    if (!isContainedRelativeKey(key)) return { outcome: 'INVALID_KEY', key };
  }

  let record: IProjectModel;
  try {
    record = await ProjectModel.create({
      projectId: project._id,
      jobId: job._id,
      source: 'meshy' satisfies ModelSource,
      status: 'QUEUED',
      selectedKeys: keys,
      createdByUserId: new Types.ObjectId(actor.userId),
      createdByRole: actor.role,
      ...(idempotencyKey ? { idempotencyKey } : {}),
    });
  } catch (err: unknown) {
    if (isDuplicateKeyError(err) && idempotencyKey) {
      const existing = await ProjectModel.findOne({
        createdByUserId: new Types.ObjectId(actor.userId),
        idempotencyKey,
      }).exec();
      // The index guarantees the winner exists; if it somehow does not, fall
      // through and rethrow rather than silently paying for a second run.
      if (existing) return { outcome: 'REPLAYED', model: existing };
    }
    throw err;
  }

  try {
    await Job.create({
      projectId: project._id,
      userId: job.userId,
      jobType: MESHY_MODEL_GENERATION_JOB_TYPE,
      // The enqueue itself: the worker claims `state: 'QUEUED'` documents.
      state: 'QUEUED',
      payload: { modelId: record.id as string },
    });
  } catch (err: unknown) {
    // No job means nothing will ever run — fail the record now so it does not
    // sit QUEUED forever and the staff user gets a real error to retry from.
    record.status = 'FAILED';
    record.error = { code: 'ENQUEUE_FAILED', message: 'Could not enqueue the generation job.' };
    await record.save();
    throw err;
  }

  return { outcome: 'CREATED', model: record };
}

function isDuplicateKeyError(err: unknown): boolean {
  return typeof err === 'object' && err !== null && (err as { code?: number }).code === 11000;
}

// ── Read ─────────────────────────────────────────────────────────────────────

/** A project's full generation history, newest first (the staff compare view). */
export async function listProjectModels(projectId: string): Promise<IProjectModel[]> {
  return ProjectModel.find({ projectId: new Types.ObjectId(projectId) })
    .sort({ createdAt: -1 })
    .exec();
}

/**
 * The newest SUCCEEDED model for a project, or null.
 *
 * Filtered in the QUERY, not picked off the history list: a fresh regenerate
 * sits at the head of the history as QUEUED/PROCESSING, and "latest overall,
 * if it happens to be SUCCEEDED" would hide the good model the project already
 * has for the whole duration of the new run.
 */
export async function latestSucceededModel(projectId: string): Promise<IProjectModel | null> {
  return ProjectModel.findOne({
    projectId: new Types.ObjectId(projectId),
    status: 'SUCCEEDED',
  })
    .sort({ createdAt: -1 })
    .exec();
}

/**
 * The newest SUCCEEDED model as the OWNER may see it — the only generation
 * surface the owner-facing project detail exposes.
 */
export async function latestOwnerModelFor(projectId: string): Promise<OwnerModelDto | null> {
  const record = await latestSucceededModel(projectId);
  return record ? toOwnerModelDto(record) : null;
}

// ── Approve ──────────────────────────────────────────────────────────────────

export type ApproveModelResult =
  | { outcome: 'MODEL_NOT_FOUND' }
  /** Only a SUCCEEDED record can be approved — there is nothing else to sign off. */
  | { outcome: 'NOT_APPROVABLE'; status: ModelStatus }
  | { outcome: 'APPROVED'; model: IProjectModel };

/**
 * The "we're satisfied with the Meshy result — no manual creation needed" gate.
 *
 * One conditional findOneAndUpdate fenced on status SUCCEEDED (the codebase's
 * no-transactions atomicity pattern), so it can never approve a record that
 * failed. Re-approving is idempotent: it re-stamps `approved` with the latest
 * actor rather than erroring, matching the rest of the admin surface's
 * double-tap tolerance.
 */
export async function approveModel(
  projectId: string,
  modelId: string,
  actor: ModelActor
): Promise<ApproveModelResult> {
  const updated = await ProjectModel.findOneAndUpdate(
    {
      _id: new Types.ObjectId(modelId),
      projectId: new Types.ObjectId(projectId),
      status: 'SUCCEEDED',
    },
    { $set: { approved: { at: new Date(), byUserId: new Types.ObjectId(actor.userId) } } },
    { new: true }
  ).exec();
  if (updated) return { outcome: 'APPROVED', model: updated };

  // The fenced write lost — distinguish "no such record" from "wrong status"
  // so the route can answer 404 vs 409. (Both are staff-only surfaces, so the
  // enumeration-safety rule that collapses these on owner routes doesn't apply.)
  const existing = await ProjectModel.findOne({
    _id: new Types.ObjectId(modelId),
    projectId: new Types.ObjectId(projectId),
  }).exec();
  if (!existing) return { outcome: 'MODEL_NOT_FOUND' };
  return { outcome: 'NOT_APPROVABLE', status: existing.status };
}
