// src/services/adminProjectsService.ts
//
// Cross-user "live projects" reads for staff (min role MODEL_ARTIST) — the
// browse/detail/export surface behind /admin. Read-only by design: nothing in
// here mutates a project or job.
//
// PII stance (v1): staff see an OPAQUE `ownerId` — never the owner's phone or
// email. The DTO is the exact owner-facing Project DTO plus that ownerId, so
// the two lists can never drift in shape.
import { Types, type FilterQuery } from 'mongoose';
import { Project, type IProject, type ProjectStatus } from '@/models/Project';
import { Job, type IJob, type JobState } from '@/models/Job';
import {
  toProjectListItem,
  type ProjectListItem,
} from '@/services/projectsService';
import {
  listObjectsUnderPrefix,
  moveObject,
  presignObjectGetUrl,
} from '@/services/s3ObjectStore';
import { encodeCursor, type ProjectCursor } from '@/utils/cursor';
import { env } from '@/config/env';

/** The owner-facing Project DTO + the opaque owner id (never phone/email). */
export interface AdminProjectListItem extends ProjectListItem {
  ownerId: string;
}

/**
 * "Live" default: uploaded-and-finalized projects. DRAFT/CAPTURING/UPLOADING
 * are still in flight on the owner's device; FAILED is excluded by default
 * (an explicit ?status=FAILED override lists them).
 */
export const LIVE_PROJECT_STATUSES: readonly ProjectStatus[] = ['PROCESSING', 'COMPLETED'];

/**
 * Job states whose upload has passed the finalize gate (the QUEUED flip that
 * verified the S3 objects). Grounded to the actual state machine
 * (models/types/job.types.ts): QUEUED and everything after it — including
 * FAILED/CANCELED, which this pipeline only reaches FROM post-QUEUED
 * processing states, so their raw captures are verified-in-S3 too. UPLOADED
 * is deliberately absent: it never passed verification.
 */
export const UPLOAD_FINALIZED_JOB_STATES: readonly JobState[] = [
  'QUEUED',
  'CLAIMED',
  'PROCESSING',
  'TEXTURING',
  'OPTIMIZING',
  'COMPLETED',
  'FAILED',
  'CANCELED',
];

export interface AdminListProjectsResult {
  items: AdminProjectListItem[];
  nextCursor: string | null;
}

/**
 * Lists captured projects ACROSS users, most-recently-updated first, with the
 * same deterministic keyset pagination as the owner list (updatedAt DESC,
 * _id DESC — backed by the {status, updatedAt, _id} index). Soft-deleted rows
 * are always excluded; `statusOverride` narrows to one explicit status instead
 * of the live default.
 */
export async function listAllCapturedProjects(
  limit: number,
  cursor?: ProjectCursor,
  statusOverride?: ProjectStatus
): Promise<AdminListProjectsResult> {
  const filter: FilterQuery<IProject> = {
    status: statusOverride ? statusOverride : { $in: [...LIVE_PROJECT_STATUSES] },
    deletedAt: null,
  };

  if (cursor) {
    filter.$or = [
      { updatedAt: { $lt: cursor.updatedAt } },
      { updatedAt: cursor.updatedAt, _id: { $lt: new Types.ObjectId(cursor.id) } },
    ];
  }

  const rows = await Project.find(filter)
    .sort({ updatedAt: -1, _id: -1 })
    .limit(limit + 1)
    .exec();

  const hasMore = rows.length > limit;
  const page = hasMore ? rows.slice(0, limit) : rows;
  const last = page[page.length - 1];
  const nextCursor = hasMore && last ? encodeCursor(last.updatedAt, last.id as string) : null;

  return { items: page.map(toAdminItem), nextCursor };
}

/** Compact summary of the exportable job shown on the staff detail view. */
export interface AdminJobSummary {
  id: string;
  state: JobState;
  expectedFilesCount: number;
  /** ISO instant the upload passed the finalize gate; null if unavailable. */
  finalizedAt: string | null;
}

export interface AdminProjectDetail {
  project: AdminProjectListItem;
  /** Null when the project has no upload-finalized job (nothing exportable). */
  job: AdminJobSummary | null;
}

/**
 * One project (any owner) + the compact summary of its exportable job. Null
 * when missing or soft-deleted — the route maps that to the standard 404.
 */
export async function getAdminProjectDetail(
  projectId: string
): Promise<AdminProjectDetail | null> {
  const project = await Project.findOne({
    _id: new Types.ObjectId(projectId),
    deletedAt: null,
  }).exec();
  if (!project) return null;

  const job = await findExportableJob(projectId);
  return {
    project: toAdminItem(project),
    job: job
      ? {
          id: job.id as string,
          state: job.state,
          expectedFilesCount: job.upload?.expectedFilesCount ?? 0,
          finalizedAt: job.queuedAt ? job.queuedAt.toISOString() : null,
        }
      : null,
  };
}

/** One presigned file entry of an export manifest. */
export interface ExportFileEntry {
  /** Path RELATIVE to the job root (e.g. `images/EYE/eye_0001.jpg`) — the
   * consumer mirrors the folder layout without learning the {env}/{userId}/…
   * key internals. */
  key: string;
  /** Presigned GET URL — a bearer credential until expiresAt. NEVER logged. */
  url: string;
  size: number;
}

export interface ExportManifest {
  projectId: string;
  jobId: string;
  generatedAt: string;
  expiresAt: string;
  fileCount: number;
  expectedFileCount: number;
  files: ExportFileEntry[];
}

export type BuildExportResult =
  | { outcome: 'PROJECT_NOT_FOUND' }
  | { outcome: 'NOT_EXPORTABLE' }
  | { outcome: 'EXPORTED'; export: ExportManifest };

/**
 * The reserved sub-prefix under a job root where soft-deleted objects are
 * parked (`{rawPrefix}deleted/{relativeKey}`). Kept UNDER the job root so:
 *   • the export can hide them with one relative-key prefix test, and
 *   • the total object count under rawPrefix is unchanged by a soft delete, so
 *     a finalize replay (which counts objects under rawPrefix) still matches
 *     expectedFilesCount.
 * A caller can never target this namespace for deletion (containment rejects a
 * key starting with it), so `deleted/deleted/…` nesting cannot occur.
 */
export const DELETED_KEY_PREFIX = 'deleted/';

/** A job-root object key stripped to its export-relative form. */
function toRelativeKey(absoluteKey: string, rawPrefix: string): string {
  return absoluteKey.startsWith(rawPrefix) ? absoluteKey.slice(rawPrefix.length) : absoluteKey;
}

/**
 * Builds the presigned-URL export manifest for a project's most recent
 * upload-finalized job. Lists the ACTUAL objects under the job's stored
 * `rawPrefix` (the canonical builder's output persisted at create time — the
 * exact prefix finalize verified; deliberately not recomputed, same reasoning
 * as finalize) and presigns a GET per key in parallel (local signing — cheap).
 *
 * `fileCount` is the listed truth and `expectedFileCount` the job's verified
 * expectation; both ship in the manifest so a drift (e.g. an object deleted
 * since finalize) is visible to the consumer rather than silently masked.
 */
export async function buildProjectExport(projectId: string): Promise<BuildExportResult> {
  const project = await Project.findOne({
    _id: new Types.ObjectId(projectId),
    deletedAt: null,
  }).exec();
  if (!project) return { outcome: 'PROJECT_NOT_FOUND' };

  const job = await findExportableJob(projectId);
  if (!job || !job.upload) return { outcome: 'NOT_EXPORTABLE' };

  const { rawBucket, rawPrefix } = job.upload;
  // Soft-deleted objects live under `{rawPrefix}deleted/` — list everything,
  // then drop that namespace so a curated-away photo never reappears in the
  // export (and `fileCount` reflects the post-curation truth vs expectedFileCount).
  const objects = (await listObjectsUnderPrefix(rawBucket, rawPrefix)).filter(
    (object) => !toRelativeKey(object.key, rawPrefix).startsWith(DELETED_KEY_PREFIX)
  );

  const ttlSeconds = env.ADMIN_EXPORT_URL_TTL_SECONDS;
  const generatedAt = new Date();
  const files = await Promise.all(
    objects.map(async (object) => ({
      key: toRelativeKey(object.key, rawPrefix),
      url: await presignObjectGetUrl(rawBucket, object.key, ttlSeconds),
      size: object.size,
    }))
  );

  return {
    outcome: 'EXPORTED',
    export: {
      projectId: project.id as string,
      jobId: job.id as string,
      generatedAt: generatedAt.toISOString(),
      expiresAt: new Date(generatedAt.getTime() + ttlSeconds * 1000).toISOString(),
      fileCount: files.length,
      expectedFileCount: job.upload.expectedFilesCount,
      files,
    },
  };
}

export type SoftDeletePhotosResult =
  | { outcome: 'PROJECT_NOT_FOUND' }
  | { outcome: 'NOT_EXPORTABLE' }
  /** A requested key escapes the job prefix (or targets the deleted/ namespace)
   * — the WHOLE request is refused, nothing is touched. */
  | { outcome: 'INVALID_KEY'; key: string }
  | {
      outcome: 'DELETED';
      projectId: string;
      jobId: string;
      /** Relative keys that existed and were moved to the deleted/ namespace. */
      deleted: string[];
      /** Relative keys that were already absent (idempotent no-op). */
      missing: string[];
    };

/**
 * A relative key is safe to soft-delete iff it stays strictly INSIDE the job
 * root: non-empty, not absolute, no `.`/`..`/empty segment (traversal), and not
 * already under the reserved deleted/ namespace. Mirrors the upload-urls
 * "key must live under the job's keyPrefix" containment rule.
 */
function isContainedRelativeKey(relativeKey: string): boolean {
  if (typeof relativeKey !== 'string' || relativeKey.length === 0) return false;
  if (relativeKey.startsWith('/')) return false;
  if (relativeKey.startsWith(DELETED_KEY_PREFIX)) return false;
  return relativeKey.split('/').every((seg) => seg !== '' && seg !== '.' && seg !== '..');
}

/**
 * SOFT-deletes captured objects for a project's exportable job: each RELATIVE
 * key (exactly as the export manifest emits it) is moved from
 * `{rawPrefix}{key}` to `{rawPrefix}deleted/{key}` — recoverable, and out of the
 * export set. The exportable job + rawPrefix are resolved the SAME way
 * buildProjectExport does (never recomputed), so a caller can only ever affect
 * the objects it can already see.
 *
 * Fail-closed on containment: if ANY key escapes the job prefix the whole
 * request is refused and nothing is moved. Missing keys are reported (not an
 * error) so a double-tap / stale manifest is idempotent.
 */
export async function softDeleteProjectPhotos(
  projectId: string,
  relativeKeys: string[]
): Promise<SoftDeletePhotosResult> {
  const project = await Project.findOne({
    _id: new Types.ObjectId(projectId),
    deletedAt: null,
  }).exec();
  if (!project) return { outcome: 'PROJECT_NOT_FOUND' };

  const job = await findExportableJob(projectId);
  if (!job || !job.upload) return { outcome: 'NOT_EXPORTABLE' };

  // Dedupe while preserving order; validate containment on ALL keys first.
  const keys = [...new Set(relativeKeys)];
  for (const key of keys) {
    if (!isContainedRelativeKey(key)) return { outcome: 'INVALID_KEY', key };
  }

  const { rawBucket, rawPrefix } = job.upload;
  const deleted: string[] = [];
  const missing: string[] = [];
  for (const key of keys) {
    const result = await moveObject(rawBucket, `${rawPrefix}${key}`, `${rawPrefix}${DELETED_KEY_PREFIX}${key}`);
    (result === 'moved' ? deleted : missing).push(key);
  }

  return { outcome: 'DELETED', projectId: project.id as string, jobId: job.id as string, deleted, missing };
}

/** The project's most recent job whose upload passed the finalize gate. */
async function findExportableJob(projectId: string): Promise<IJob | null> {
  return Job.findOne({
    projectId: new Types.ObjectId(projectId),
    state: { $in: [...UPLOAD_FINALIZED_JOB_STATES] },
  })
    .sort({ createdAt: -1 })
    .exec();
}

function toAdminItem(p: IProject): AdminProjectListItem {
  return { ...toProjectListItem(p), ownerId: p.userId.toHexString() };
}
