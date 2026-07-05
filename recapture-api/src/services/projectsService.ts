// src/services/projectsService.ts
import { Types, type FilterQuery } from 'mongoose';
import {
  Project,
  type IProject,
  type ObjectSize,
  type CaptureMode,
  type ProjectStatus,
} from '@/models/Project';
import { encodeCursor, type ProjectCursor } from '@/utils/cursor';
import { NotFoundError } from '@/utils/errors';
import type { CreateProjectInput } from '@/validation/projectSchemas';

/** Minimal project shape for the Hub list view — no internal-only fields. */
export interface ProjectListItem {
  id: string;
  name: string;
  status: IProject['status'];
  /** ISO instant of the last status transition; null before the first one. */
  statusUpdatedAt: string | null;
  updatedAt: string;
  createdAt: string;
}

export interface ListProjectsResult {
  items: ProjectListItem[];
  nextCursor: string | null;
}

/**
 * Lists the authenticated user's projects, most-recently-updated first.
 *
 * Ownership is enforced here from the token-resolved `userId` only — never from
 * client input. Soft-deleted projects (`deletedAt` set) are excluded. Ordering
 * is deterministic (`updatedAt DESC, _id DESC`) so cursor pages never overlap or
 * skip when `updatedAt` values tie. Fetches `limit + 1` rows to detect a next
 * page without a separate count query.
 */
export async function listProjects(
  userId: string,
  limit: number,
  cursor?: ProjectCursor
): Promise<ListProjectsResult> {
  const filter: FilterQuery<IProject> = {
    userId: new Types.ObjectId(userId),
    deletedAt: null, // matches both unset and explicitly-null → excludes soft-deleted
  };

  // Keyset predicate: everything strictly after the cursor under (updatedAt DESC,
  // _id DESC) — older updatedAt, or same updatedAt with a smaller _id.
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

  return { items: page.map(toListItem), nextCursor };
}

// Client sends lowercase apiValues; the model stores UPPERCASE enums. Explicit
// maps keep the mapping total and type-checked (no string casts).
const SIZE_TO_MODEL: Record<CreateProjectInput['size'], ObjectSize> = {
  small: 'SMALL',
  medium: 'MEDIUM',
  large: 'LARGE',
};
const MODE_TO_MODEL: Record<CreateProjectInput['mode'], CaptureMode> = {
  guided: 'GUIDED',
  manual: 'MANUAL',
};

/**
 * Creates a project owned by `userId` (taken only from the authenticated token,
 * never the body). Mongoose `timestamps` sets `createdAt === updatedAt` on
 * insert, so the new project sorts to the top of {@link listProjects}. Returns
 * the SAME DTO shape as the list endpoint.
 */
export async function createProject(
  userId: string,
  input: CreateProjectInput
): Promise<ProjectListItem> {
  const project = await Project.create({
    userId: new Types.ObjectId(userId),
    name: input.name,
    objectSize: SIZE_TO_MODEL[input.size],
    mode: MODE_TO_MODEL[input.mode],
    ...(input.category ? { category: input.category } : {}),
    // status defaults to 'DRAFT'; stats defaults via the schema.
  });

  return toListItem(project);
}

/**
 * Outcome of a soft-delete attempt. The service never throws for the expected
 * business cases — it returns a discriminated result and the route maps each to
 * a status code (matching how the other endpoints keep HTTP concerns in routes).
 *
 * `NOT_FOUND` covers both "no such project" and "owned by another user" so the
 * two are indistinguishable to the caller (no existence leak → both 404).
 */
export type SoftDeleteProjectResult =
  | { outcome: 'NOT_FOUND' }
  | { outcome: 'CONFIRMATION_MISMATCH' }
  | { outcome: 'DELETED'; id: string; deletedAt: string; wasAlreadyDeleted: boolean };

/**
 * Soft-deletes a project owned by `userId`. Ownership is enforced here from the
 * token-resolved id only — the caller cannot target another user's project.
 *
 * The lookup intentionally includes already-soft-deleted rows (no `deletedAt`
 * filter) so a repeat delete is idempotent and still confirmation-checked.
 * `confirmName` must equal the stored `name` or the call is rejected without any
 * mutation. The actual flip is a conditional update on `deletedAt: null`, so a
 * concurrent double-delete is race-safe: exactly one request performs the change
 * and the original `deletedAt` is never overwritten.
 */
export async function softDeleteProject(
  userId: string,
  projectId: string,
  confirmName: string
): Promise<SoftDeleteProjectResult> {
  const ownerId = new Types.ObjectId(userId);
  const id = new Types.ObjectId(projectId);

  const project = await Project.findOne({ _id: id, userId: ownerId }).exec();
  if (!project) {
    return { outcome: 'NOT_FOUND' };
  }

  // Server-side confirmation guard — never mutate on a mismatch.
  if (confirmName !== project.name) {
    return { outcome: 'CONFIRMATION_MISMATCH' };
  }

  // Already soft-deleted → idempotent no-op; preserve the original deletedAt.
  if (project.deletedAt) {
    return {
      outcome: 'DELETED',
      id: project.id as string,
      deletedAt: project.deletedAt.toISOString(),
      wasAlreadyDeleted: true,
    };
  }

  // Conditional update: only a not-yet-deleted row matches. Under a concurrent
  // double-delete exactly one update wins; the loser gets null and re-reads.
  const now = new Date();
  const updated = await Project.findOneAndUpdate(
    { _id: id, userId: ownerId, deletedAt: null },
    { $set: { deletedAt: now } },
    { new: true }
  ).exec();

  if (updated?.deletedAt) {
    return {
      outcome: 'DELETED',
      id: updated.id as string,
      deletedAt: updated.deletedAt.toISOString(),
      wasAlreadyDeleted: false,
    };
  }

  // Lost the race: another request deleted it between our read and update.
  // Re-read the winner's deletedAt and report an idempotent success.
  const current = await Project.findOne({ _id: id, userId: ownerId }).exec();
  return {
    outcome: 'DELETED',
    id: project.id as string,
    deletedAt: (current?.deletedAt ?? now).toISOString(),
    wasAlreadyDeleted: true,
  };
}

/**
 * Outcome of a rename attempt. As with {@link softDeleteProject}, the service
 * returns a discriminated result and the route maps it to a status code.
 * `NOT_FOUND` covers missing, not-owned, AND soft-deleted (all → 404).
 */
export type RenameProjectResult =
  | { outcome: 'NOT_FOUND' }
  | { outcome: 'RENAMED'; project: ProjectListItem; wasChanged: boolean };

/**
 * Renames a project owned by `userId` (token-resolved only). Scoped to the owner
 * AND `deletedAt: null`, so a soft-deleted project is not renameable and a
 * concurrent soft-delete cannot be clobbered.
 *
 * Renaming to the identical current name is a no-op: returns the unchanged
 * project WITHOUT bumping `updatedAt` (so it does not pointlessly re-sort to the
 * top of the list). A real change updates `name` and lets mongoose `timestamps`
 * bump `updatedAt`, surfacing the project at the top of GET /projects.
 */
export async function renameProject(
  userId: string,
  projectId: string,
  name: string
): Promise<RenameProjectResult> {
  const ownerId = new Types.ObjectId(userId);
  const id = new Types.ObjectId(projectId);

  const project = await Project.findOne({ _id: id, userId: ownerId, deletedAt: null }).exec();
  if (!project) {
    return { outcome: 'NOT_FOUND' };
  }

  // No-op: identical name → don't touch updatedAt.
  if (project.name === name) {
    return { outcome: 'RENAMED', project: toListItem(project), wasChanged: false };
  }

  // Re-scope the update on owner + not-deleted so a soft-delete that landed
  // between the read and the write wins (returns null → NOT_FOUND). `timestamps`
  // bumps updatedAt automatically on this update.
  const updated = await Project.findOneAndUpdate(
    { _id: id, userId: ownerId, deletedAt: null },
    { $set: { name } },
    { new: true }
  ).exec();

  if (!updated) {
    return { outcome: 'NOT_FOUND' };
  }

  return { outcome: 'RENAMED', project: toListItem(updated), wasChanged: true };
}

/**
 * Fetches a single project owned by `userId` for "open/resume". Scoped to the
 * owner AND `deletedAt: null`, so a missing, not-owned, or soft-deleted project
 * is indistinguishably absent (→ null → 404 at the route, matching delete/rename).
 * Returns the same DTO shape as list/create.
 */
export async function getProject(
  userId: string,
  projectId: string
): Promise<ProjectListItem | null> {
  const project = await Project.findOne({
    _id: new Types.ObjectId(projectId),
    userId: new Types.ObjectId(userId),
    deletedAt: null,
  }).exec();

  return project ? toListItem(project) : null;
}

function toListItem(p: IProject): ProjectListItem {
  return {
    id: p.id as string,
    name: p.name,
    status: p.status,
    statusUpdatedAt: p.statusUpdatedAt ? p.statusUpdatedAt.toISOString() : null,
    updatedAt: p.updatedAt.toISOString(),
    createdAt: p.createdAt.toISOString(),
  };
}

// ── Project status lifecycle ──────────────────────────────────────────────────

/**
 * Expected status transitions, SOFT-enforced (warn, never block — see
 * updateProjectStatus). Grounded to this codebase's full status set: the app
 * flow is DRAFT → CAPTURING → UPLOADING → PROCESSING → COMPLETED/FAILED, a
 * job may be created straight from DRAFT (tests/dev tools do), and a
 * COMPLETED/FAILED project can start a new job version (re-capture/retry).
 * Self-transitions (duplicate create/finalize) intentionally warn.
 */
const VALID_TRANSITIONS: Partial<Record<ProjectStatus, ProjectStatus[]>> = {
  DRAFT: ['CAPTURING', 'UPLOADING'],
  CAPTURING: ['UPLOADING'],
  UPLOADING: ['PROCESSING'],
  PROCESSING: ['COMPLETED', 'FAILED'],
  COMPLETED: ['UPLOADING'],
  FAILED: ['UPLOADING'],
};

/**
 * Sets a project's status and ALWAYS stamps `statusUpdatedAt` — the timestamp
 * is enforced here, never left to call sites. Both job-pipeline transition
 * sites (createJob → UPLOADING, finalizeJob → PROCESSING) go through this
 * helper; raw status writes elsewhere are a bug.
 *
 * Unexpected transitions are logged as warnings, NOT rejected (MVP soft
 * guard): the read-before-write costs one extra query per transition, which
 * is fine at MVP scale — if it ever matters, drop the read or move it to an
 * async audit path. `runValidators: true` makes the schema's status enum fire
 * even if a bad string bypasses TypeScript at runtime (which also means the
 * schema enum must contain a status before code starts writing it —
 * deployment-order dependency).
 *
 * Throws {@link NotFoundError} (→ 500) when the project doesn't exist: a job
 * referencing a vanished project is a data-integrity bug that must surface,
 * not be swallowed. Intentionally NOT scoped to deletedAt — ownership and
 * liveness were already checked by the calling job operation.
 */
export async function updateProjectStatus(
  projectId: string,
  status: ProjectStatus
): Promise<void> {
  const current = await Project.findById(projectId).select('status').exec();
  if (current) {
    const allowed = VALID_TRANSITIONS[current.status] ?? [];
    if (!allowed.includes(status)) {
      console.warn(
        `[ProjectStatus] Unexpected transition: ${current.status} → ${status} for project ${projectId}`
      );
    }
  }

  // $set only — never document replacement, so unrelated fields are safe.
  const result = await Project.findByIdAndUpdate(
    projectId,
    { $set: { status, statusUpdatedAt: new Date() } },
    { new: false, runValidators: true }
  ).exec();

  if (!result) {
    throw new NotFoundError(`Project ${projectId} not found — cannot set status to ${status}`);
  }
}
