// src/services/projectsService.ts
import { Types, type FilterQuery } from 'mongoose';
import { Project, type IProject, type ObjectSize, type CaptureMode } from '@/models/Project';
import { encodeCursor, type ProjectCursor } from '@/utils/cursor';
import type { CreateProjectInput } from '@/validation/projectSchemas';

/** Minimal project shape for the Hub list view — no internal-only fields. */
export interface ProjectListItem {
  id: string;
  name: string;
  status: IProject['status'];
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

function toListItem(p: IProject): ProjectListItem {
  return {
    id: p.id as string,
    name: p.name,
    status: p.status,
    updatedAt: p.updatedAt.toISOString(),
    createdAt: p.createdAt.toISOString(),
  };
}
