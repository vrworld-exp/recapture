// src/routes/projects.ts
import { Router } from 'express';
import { asyncHandler } from '@/utils/asyncHandler';
import { requireAuth } from '@/middleware/auth';
import { listProjectsQuerySchema, createProjectSchema } from '@/validation/projectSchemas';
import { decodeCursor, type ProjectCursor } from '@/utils/cursor';
import { listProjects, createProject } from '@/services/projectsService';
import { hashIdentifier } from '@/utils/otp';
import { trackEvent } from '@/utils/analytics';

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

    trackEvent('projects_listed', {
      user_id_hash: hashIdentifier(userId),
      result_count: items.length,
      is_empty: items.length === 0,
    });

    res.status(200).json({ status: 'success', items, nextCursor });
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

    trackEvent('project_created', {
      user_id_hash: hashIdentifier(userId),
      project_id: project.id,
      object_size: parsed.data.size,
      mode: parsed.data.mode,
      category: parsed.data.category ?? null,
    });

    res.status(201).json({ status: 'success', project });
  })
);

export default router;
