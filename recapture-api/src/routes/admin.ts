// src/routes/admin.ts
//
// Staff-only route group (mounted at /admin): cross-user live-project browse +
// presigned-URL export for model artists. Every route runs requireAuth →
// requireRole('MODEL_ARTIST') — ADMIN passes by role inheritance. Standard
// envelope throughout; read-only.
import { Router } from 'express';
import { asyncHandler } from '@/utils/asyncHandler';
import { requireAuth } from '@/middleware/auth';
import { requireRole } from '@/middleware/requireRole';
import {
  adminListProjectsQuerySchema,
  adminProjectIdParamsSchema,
} from '@/validation/adminSchemas';
import { decodeCursor, type ProjectCursor } from '@/utils/cursor';
import {
  listAllCapturedProjects,
  getAdminProjectDetail,
  buildProjectExport,
} from '@/services/adminProjectsService';
import { consumeRateWindow } from '@/utils/rateLimit';
import { env } from '@/config/env';
import { hashIdentifier } from '@/utils/otp';
import { track, AnalyticsEvent } from '@/utils/analytics';

const router = Router();

router.use(requireAuth);
router.use(requireRole('MODEL_ARTIST'));

/**
 * GET /admin/projects — captured (upload-finalized) projects across ALL users.
 *
 * Defaults to the live set (PROCESSING/COMPLETED, never soft-deleted); an
 * explicit `?status=` narrows to one ProjectStatus. Cursor pagination is the
 * owner list's exact scheme (updatedAt DESC, _id DESC keyset). Items carry an
 * opaque `ownerId` — no owner phone/email anywhere in this payload.
 */
router.get(
  '/projects',
  asyncHandler(async (req, res) => {
    const parsed = adminListProjectsQuerySchema.safeParse(req.query);
    if (!parsed.success) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: parsed.error.issues[0]?.message ?? 'Invalid request',
      });
      return;
    }

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

    const { items, nextCursor } = await listAllCapturedProjects(
      parsed.data.limit,
      cursor,
      parsed.data.status
    );

    track(AnalyticsEvent.ADMIN_PROJECTS_LISTED, {
      // requireRole resolved + attached the role.
      actor_role: req.user!.role ?? 'MODEL_ARTIST',
      status_filter: parsed.data.status ?? 'default',
      page_size: parsed.data.limit,
    });

    res.status(200).json({ status: 'success', items, nextCursor });
  })
);

/**
 * GET /admin/projects/:id — one project (any owner) + a compact summary of its
 * exportable job. Missing and soft-deleted are an identical 404.
 */
router.get(
  '/projects/:id',
  asyncHandler(async (req, res) => {
    const params = adminProjectIdParamsSchema.safeParse(req.params);
    if (!params.success) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: params.error.issues[0]?.message ?? 'Invalid project id',
      });
      return;
    }

    const detail = await getAdminProjectDetail(params.data.id);
    if (!detail) {
      res.status(404).json({
        status: 'error',
        code: 'NOT_FOUND',
        message: 'Project not found.',
      });
      return;
    }

    res.status(200).json({ status: 'success', project: detail.project, job: detail.job });
  })
);

/**
 * GET /admin/projects/:id/export — the presigned-URL export manifest for the
 * project's most recent upload-finalized job.
 *
 * Rate-limited per staff user (the presigned URLs are bearer credentials —
 * generating them should be deliberate, not free). The response's `files[].url`
 * values are the ONLY place a presigned URL may appear: never in logs or
 * analytics (ids there are hashed).
 */
router.get(
  '/projects/:id/export',
  asyncHandler(async (req, res) => {
    const params = adminProjectIdParamsSchema.safeParse(req.params);
    if (!params.success) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: params.error.issues[0]?.message ?? 'Invalid project id',
      });
      return;
    }

    const userId = req.user!.userId;
    const rate = await consumeRateWindow(
      `admin-export:${userId}`,
      env.ADMIN_EXPORT_MAX_PER_WINDOW,
      env.ADMIN_EXPORT_WINDOW_SECONDS
    );
    if (rate.limited) {
      res.status(429).json({
        status: 'error',
        code: 'RATE_LIMITED',
        message: 'Too many export requests. Please try again later.',
        retryAfter: rate.retryAfter,
      });
      return;
    }

    const result = await buildProjectExport(params.data.id);

    if (result.outcome === 'PROJECT_NOT_FOUND') {
      res.status(404).json({
        status: 'error',
        code: 'NOT_FOUND',
        message: 'Project not found.',
      });
      return;
    }

    if (result.outcome === 'NOT_EXPORTABLE') {
      res.status(409).json({
        status: 'error',
        code: 'NOT_EXPORTABLE',
        message: 'This project has no finalized upload to export.',
      });
      return;
    }

    track(AnalyticsEvent.PROJECT_EXPORT_GENERATED, {
      actor_id_hash: hashIdentifier(userId),
      project_id_hash: hashIdentifier(result.export.projectId),
      job_id_hash: hashIdentifier(result.export.jobId),
      file_count: result.export.fileCount,
      ttl_seconds: env.ADMIN_EXPORT_URL_TTL_SECONDS,
    });

    res.status(200).json({ status: 'success', export: result.export });
  })
);

export default router;
