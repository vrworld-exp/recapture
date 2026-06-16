// src/routes/projects.ts
import { Router } from 'express';
import { asyncHandler } from '@/utils/asyncHandler';
import { requireAuth } from '@/middleware/auth';
import {
  listProjectsQuerySchema,
  createProjectSchema,
  projectIdParamsSchema,
  deleteProjectBodySchema,
  renameProjectSchema,
} from '@/validation/projectSchemas';
import { decodeCursor, type ProjectCursor } from '@/utils/cursor';
import {
  listProjects,
  createProject,
  softDeleteProject,
  renameProject,
  getProject,
} from '@/services/projectsService';
import { hashIdentifier } from '@/utils/otp';
import { track, AnalyticsEvent } from '@/utils/analytics';
import { RESUME_SOURCES } from '@/validation/analyticsSchemas';

const router = Router();

// Every route in this router requires a valid access token. `requireAuth`
// rejects missing/invalid tokens with 401 before any handler runs and attaches
// `req.user = { userId, authUid }`.
router.use(requireAuth);

/**
 * GET /projects — the authenticated user's projects, most-recently-updated
 * first, with cursor pagination.
 *
 * Ownership comes ONLY from the token (`req.user.userId`); any `userId` in the
 * query/body is ignored. Read-only.
 */
router.get(
  '/',
  asyncHandler(async (req, res) => {
    const parsed = listProjectsQuerySchema.safeParse(req.query);
    if (!parsed.success) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: parsed.error.issues[0]?.message ?? 'Invalid request',
      });
      return;
    }

    // Decode the opaque cursor defensively — a tampered cursor is a 400, not 500.
    let cursor: ProjectCursor | undefined;
    if (parsed.data.cursor !== undefined) {
      const decoded = decodeCursor(parsed.data.cursor);
      if (!decoded) {
        res.status(400).json({
          status: 'error',
          code: 'INVALID_REQUEST',
          message: 'Invalid cursor',
        });
        return;
      }
      cursor = decoded;
    }

    // `requireAuth` guarantees req.user is set.
    const userId = req.user!.userId;
    const { items, nextCursor } = await listProjects(userId, parsed.data.limit, cursor);

    track(AnalyticsEvent.PROJECTS_LISTED, {
      user_id_hash: hashIdentifier(userId),
      result_count: items.length,
      is_empty: items.length === 0,
    });

    res.status(200).json({ status: 'success', items, nextCursor });
  })
);

/**
 * GET /projects/:id — open/resume a single project owned by the caller.
 *
 * Returns the same project DTO as the list endpoint. Missing, not-owned, and
 * soft-deleted all return an identical 404 (no existence leak). On a successful,
 * authorized, non-deleted open it emits `project_resumed` — once per open; the
 * backend has no session state, so per-session debounce is the client's job.
 */
router.get(
  '/:id',
  asyncHandler(async (req, res) => {
    const params = projectIdParamsSchema.safeParse(req.params);
    if (!params.success) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: params.error.issues[0]?.message ?? 'Invalid project id',
      });
      return;
    }

    const userId = req.user!.userId;
    const project = await getProject(userId, params.data.id);

    if (!project) {
      res.status(404).json({
        status: 'error',
        code: 'NOT_FOUND',
        message: 'Project not found.',
      });
      return;
    }

    // Optional context. Source is lenient — an unrecognized value is omitted,
    // never an error. seconds_since_last_update is derived from the DTO.
    const source = RESUME_SOURCES.find((s) => s === req.query.source);
    const secondsSinceLastUpdate = Math.max(
      0,
      Math.floor((Date.now() - Date.parse(project.updatedAt)) / 1000)
    );

    track(AnalyticsEvent.PROJECT_RESUMED, {
      user_id_hash: hashIdentifier(userId),
      project_id: project.id,
      ...(source ? { source } : {}),
      seconds_since_last_update: secondsSinceLastUpdate,
    });

    res.status(200).json({ status: 'success', project });
  })
);

/**
 * POST /projects — create a project owned by the authenticated user.
 *
 * Ownership comes ONLY from the token; an `ownerId`/`userId` in the body is
 * rejected by the schema's `.strict()`. Returns the same project DTO as the
 * list endpoint with a 201. Create-only — no update/delete here.
 */
router.post(
  '/',
  asyncHandler(async (req, res) => {
    const parsed = createProjectSchema.safeParse(req.body);
    if (!parsed.success) {
      const issue = parsed.error.issues[0];
      const field = issue?.path.join('.') || 'body';
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: issue?.message ?? 'Invalid request',
        fields: { [field]: issue?.message ?? 'invalid value' },
      });
      return;
    }

    const userId = req.user!.userId;
    const project = await createProject(userId, parsed.data);

    track(AnalyticsEvent.PROJECT_CREATED, {
      user_id_hash: hashIdentifier(userId),
      project_id: project.id,
      object_size: parsed.data.size,
      mode: parsed.data.mode,
      category: parsed.data.category ?? null,
    });

    res.status(201).json({ status: 'success', project });
  })
);

/**
 * PATCH /projects/:id — rename a project owned by the authenticated user.
 *
 * Rename-only: the body accepts ONLY `name` (same bounds as POST /projects);
 * `.strict()` rejects every other field so objectSize/category/mode/owner cannot
 * be changed here. Ownership comes only from the token; missing, not-owned, and
 * soft-deleted all return an identical 404. A real change bumps `updatedAt`
 * (re-sorting to the top of the list); renaming to the same name is a no-op.
 */
router.patch(
  '/:id',
  asyncHandler(async (req, res) => {
    // Malformed id → 400 without touching the DB.
    const params = projectIdParamsSchema.safeParse(req.params);
    if (!params.success) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: params.error.issues[0]?.message ?? 'Invalid project id',
      });
      return;
    }

    // Strict body: missing/empty/over-long name, or any extra field → 400.
    const body = renameProjectSchema.safeParse(req.body);
    if (!body.success) {
      const issue = body.error.issues[0];
      const field = issue?.path.join('.') || 'name';
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: issue?.message ?? 'Invalid request',
        fields: { [field]: issue?.message ?? 'invalid value' },
      });
      return;
    }

    const userId = req.user!.userId;
    const result = await renameProject(userId, params.data.id, body.data.name);

    if (result.outcome === 'NOT_FOUND') {
      res.status(404).json({
        status: 'error',
        code: 'NOT_FOUND',
        message: 'Project not found.',
      });
      return;
    }

    track(AnalyticsEvent.PROJECT_RENAMED, {
      user_id_hash: hashIdentifier(userId),
      project_id: result.project.id,
      was_changed: result.wasChanged,
    });

    res.status(200).json({ status: 'success', project: result.project });
  })
);

/**
 * DELETE /projects/:id — soft-delete a project owned by the authenticated user.
 *
 * The row is flagged (`deletedAt`), never removed, so it stays consistent with
 * GET /projects which excludes soft-deleted projects. The client must echo the
 * project's exact `name` as `confirmName` — the backend independently enforces
 * confirmation, so a request without it never mutates state. Not-found and
 * not-owned both return 404 (no existence leak); repeats are idempotent.
 */
router.delete(
  '/:id',
  asyncHandler(async (req, res) => {
    // Malformed id → 400 without touching the DB.
    const params = projectIdParamsSchema.safeParse(req.params);
    if (!params.success) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: params.error.issues[0]?.message ?? 'Invalid project id',
      });
      return;
    }

    // Missing/unknown confirmation field → 422, no delete. (Mismatch against the
    // stored name is decided in the service, also a 422.)
    const body = deleteProjectBodySchema.safeParse(req.body);
    if (!body.success) {
      res.status(422).json({
        status: 'error',
        code: 'CONFIRMATION_REQUIRED',
        message: 'Confirmation does not match the project name.',
      });
      return;
    }

    const userId = req.user!.userId;
    const result = await softDeleteProject(userId, params.data.id, body.data.confirmName);

    if (result.outcome === 'NOT_FOUND') {
      res.status(404).json({
        status: 'error',
        code: 'NOT_FOUND',
        message: 'Project not found.',
      });
      return;
    }

    if (result.outcome === 'CONFIRMATION_MISMATCH') {
      res.status(422).json({
        status: 'error',
        code: 'CONFIRMATION_REQUIRED',
        message: 'Confirmation does not match the project name.',
      });
      return;
    }

    track(AnalyticsEvent.PROJECT_DELETED, {
      user_id_hash: hashIdentifier(userId),
      project_id: result.id,
      was_already_deleted: result.wasAlreadyDeleted,
    });

    res.status(200).json({
      status: 'success',
      id: result.id,
      deletedAt: result.deletedAt,
    });
  })
);

export default router;
