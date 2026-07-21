// src/routes/admin.ts
//
// Staff-only route group (mounted at /admin): cross-user live-project browse,
// presigned-URL export, Meshy model generation, and ADMIN-only curation
// (photo soft-delete, project soft/hard delete). Every route runs requireAuth →
// requireRole('MODEL_ARTIST') — ADMIN passes by role inheritance; destructive
// routes add their own requireRole('ADMIN'). Standard envelope throughout.
import { Router } from 'express';
import { asyncHandler } from '@/utils/asyncHandler';
import { requireAuth } from '@/middleware/auth';
import { requireRole } from '@/middleware/requireRole';
import {
  adminListProjectsQuerySchema,
  adminProjectIdParamsSchema,
  adminDeletePhotosBodySchema,
  adminDeleteProjectBodySchema,
  adminCreateModelBodySchema,
  adminAutoModelBodySchema,
  adminModelIdParamsSchema,
  adminModelImageUploadsBodySchema,
} from '@/validation/adminSchemas';
import { decodeCursor, type ProjectCursor } from '@/utils/cursor';
import {
  listAllCapturedProjects,
  getAdminProjectDetail,
  buildProjectExport,
  softDeleteProjectPhotos,
  adminDeleteProject,
} from '@/services/adminProjectsService';
import {
  approveModel,
  createMeshyModelRequest,
  createModelImageUploadUrls,
  findProjectModelById,
  latestSucceededModel,
  listProjectModels,
  toProjectModelDto,
  MAX_SELECTED_PHOTOS,
  MIN_SELECTED_PHOTOS,
} from '@/services/projectModelsService';
import {
  generateModelOnDemand,
  GenerationInfrastructureError,
} from '@/services/onDemandModelGenerationService';
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
 * exportable job + the latest SUCCEEDED model, if any. Missing and soft-deleted
 * are an identical 404.
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

    // The latest SUCCEEDED generation, so the staff detail can link straight to
    // the viewer. Full history stays behind GET /admin/projects/:id/models.
    const latestModel = await latestSucceededModel(params.data.id);
    const model = latestModel ? toProjectModelDto(latestModel) : null;

    res.status(200).json({
      status: 'success',
      project: detail.project,
      job: detail.job,
      model,
    });
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

/**
 * DELETE /admin/projects/:id/photos — SOFT-delete captured photos from a
 * project's exportable job (staff curation).
 *
 * ADMIN-ONLY (a stricter gate than the browse/export routes' MODEL_ARTIST):
 * deleting a user's raw capture is destructive, so the route adds its own
 * requireRole('ADMIN') on top of the router-level MODEL_ARTIST gate. Body carries
 * the RELATIVE keys to remove (exactly as the export manifest emits them).
 *
 * "Delete" here MOVES each object to the job's reserved `deleted/` namespace
 * (recoverable, out of the export set) rather than destroying it. Any key that
 * escapes the job prefix is refused before anything is touched (containment).
 * Analytics carries HASHED ids + counts only — never a key or presigned URL.
 */
router.delete(
  '/projects/:id/photos',
  requireRole('ADMIN'),
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
    const body = adminDeletePhotosBodySchema.safeParse(req.body);
    if (!body.success) {
      const issue = body.error.issues[0];
      const field = issue?.path.join('.') || 'body';
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: issue?.message ?? 'Invalid request',
        fields: { [field]: issue?.message ?? 'invalid value' },
      });
      return;
    }

    const result = await softDeleteProjectPhotos(params.data.id, body.data.keys);

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
        message: 'This project has no finalized upload to modify.',
      });
      return;
    }

    if (result.outcome === 'INVALID_KEY') {
      // Never echo the offending key back verbatim — it is caller-controlled and
      // would let an attacker probe the message. Mirrors upload-urls' 400.
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: "Each key must live under the job's file set.",
        fields: { keys: "must be an export-manifest key (no '..' or absolute path)" },
      });
      return;
    }

    track(AnalyticsEvent.PROJECT_PHOTOS_DELETED, {
      actor_id_hash: hashIdentifier(req.user!.userId),
      project_id_hash: hashIdentifier(result.projectId),
      job_id_hash: hashIdentifier(result.jobId),
      deleted_count: result.deleted.length,
      missing_count: result.missing.length,
    });

    res.status(200).json({
      status: 'success',
      deleted: result.deleted,
      missing: result.missing,
    });
  })
);

/**
 * DELETE /admin/projects/:id — delete a live project (staff curation of bad
 * captures). ADMIN-ONLY, like the photo soft-delete above.
 *
 * Body: `{ mode: 'SOFT' | 'HARD', confirmName }`. SOFT flags `deletedAt`
 * (hidden everywhere, recoverable); HARD permanently erases the project, its
 * jobs, model records, and every S3 object under them. `confirmName` must echo
 * the project's exact name for BOTH modes — enforced server-side with the same
 * 422 CONFIRMATION_REQUIRED contract as the owner delete route, so the client
 * dialog can share copy. Analytics carries hashed ids + the mode only.
 */
router.delete(
  '/projects/:id',
  requireRole('ADMIN'),
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
    const body = adminDeleteProjectBodySchema.safeParse(req.body);
    if (!body.success) {
      res.status(422).json({
        status: 'error',
        code: 'CONFIRMATION_REQUIRED',
        message: 'Confirmation does not match the project name.',
      });
      return;
    }

    const result = await adminDeleteProject(params.data.id, body.data.mode, body.data.confirmName);

    if (result.outcome === 'PROJECT_NOT_FOUND') {
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

    track(AnalyticsEvent.ADMIN_PROJECT_DELETED, {
      actor_id_hash: hashIdentifier(req.user!.userId),
      project_id_hash: hashIdentifier(result.projectId),
      owner_id_hash: hashIdentifier(result.ownerId),
      mode: body.data.mode,
      ...(result.outcome === 'SOFT_DELETED'
        ? { was_already_deleted: result.wasAlreadyDeleted }
        : { objects_deleted: result.objectsDeleted }),
    });

    res.status(200).json({
      status: 'success',
      mode: body.data.mode,
      projectId: result.projectId,
      ...(result.outcome === 'SOFT_DELETED'
        ? { wasAlreadyDeleted: result.wasAlreadyDeleted }
        : {
            objectsDeleted: result.objectsDeleted,
            jobsDeleted: result.jobsDeleted,
            modelsDeleted: result.modelsDeleted,
          }),
    });
  })
);

/**
 * POST /admin/projects/:id/model — request a Meshy AI 3D model from 3–4 photos
 * the staff user picked in the Preview gallery.
 *
 * MODEL_ARTIST+ (the router-level gate): generating a model is the artist's job,
 * unlike the ADMIN-only destructive photo delete above.
 *
 * Each call SPENDS CREDITS, so it is guarded three ways: a per-user rate window,
 * an `Idempotency-Key` replay (a double-tap resolves to the first record instead
 * of a second paid generation), and — in the worker — a persisted meshyTaskId.
 * The request only ENQUEUES: Meshy takes minutes, and the API must not block on
 * it. Analytics carries hashed ids + a count; never a key or a presigned URL.
 */
router.post(
  '/projects/:id/model',
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
    const body = adminCreateModelBodySchema.safeParse(req.body);
    if (!body.success) {
      const issue = body.error.issues[0];
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
    const rate = await consumeRateWindow(
      `meshy-create:${userId}`,
      env.MESHY_CREATE_MAX_PER_WINDOW,
      env.MESHY_CREATE_WINDOW_SECONDS
    );
    if (rate.limited) {
      res.status(429).json({
        status: 'error',
        code: 'RATE_LIMITED',
        message: 'Too many model generation requests. Please try again later.',
        retryAfter: rate.retryAfter,
      });
      return;
    }

    const idempotencyKey = req.get('Idempotency-Key');
    const result = await createMeshyModelRequest({
      projectId: params.data.id,
      keys: body.data.keys,
      actor: { userId, role: req.user!.role ?? 'MODEL_ARTIST' },
      ...(idempotencyKey ? { idempotencyKey } : {}),
    });

    if (result.outcome === 'PROJECT_NOT_FOUND') {
      res.status(404).json({ status: 'error', code: 'NOT_FOUND', message: 'Project not found.' });
      return;
    }
    if (result.outcome === 'NOT_EXPORTABLE') {
      res.status(409).json({
        status: 'error',
        code: 'NOT_EXPORTABLE',
        message: 'This project has no finalized upload to generate a model from.',
      });
      return;
    }
    if (result.outcome === 'INVALID_COUNT') {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: `Select between ${MIN_SELECTED_PHOTOS} and ${MAX_SELECTED_PHOTOS} distinct photos.`,
        fields: { keys: `must be ${MIN_SELECTED_PHOTOS}–${MAX_SELECTED_PHOTOS} distinct keys` },
      });
      return;
    }
    if (result.outcome === 'INVALID_KEY') {
      // Never echo the offending key — it is caller-controlled and would let an
      // attacker probe the message. Same stance as the soft-delete route's 400.
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: "Each key must live under the job's file set.",
        fields: { keys: "must be an export-manifest key (no '..' or absolute path)" },
      });
      return;
    }

    const model = toProjectModelDto(result.model);
    track(AnalyticsEvent.MODEL_GENERATION_REQUESTED, {
      actor_id_hash: hashIdentifier(userId),
      project_id_hash: hashIdentifier(model.projectId),
      job_id_hash: hashIdentifier(model.jobId),
      model_id_hash: hashIdentifier(model.id),
      source: model.source,
      key_count: model.selectedKeys.length,
      was_replay: result.outcome === 'REPLAYED',
    });

    // A replay is not a new creation — 200 distinguishes it from the 201 that
    // actually enqueued a generation.
    res.status(result.outcome === 'REPLAYED' ? 200 : 201).json({ status: 'success', model });
  })
);

/**
 * POST /admin/projects/:id/model/auto — the "Generate 3D model" button: run the
 * SERVER-side photo selection for this project and enqueue the generation.
 *
 * Same pipeline as automatic generation, triggered by a person. It is
 * deliberately a SEPARATE route from the explicit-keys POST /model above rather
 * than a mode flag on it: that route's contract is used by Prepare-Images and
 * is covered by tests, and coupling two independent flows through one body
 * shape helps nobody.
 *
 * Shares the `meshy-create:{userId}` rate window with the explicit-keys route —
 * one ceiling on "generations this staff user can start", however they start
 * them. Beyond that the ceilings are the service's: idempotent repeat presses,
 * and a rolling 24h cap shared with automatic generations.
 *
 * Responds with the full step trace. Steps 1–6 all happen INSIDE this request,
 * in well under a second, so there is nothing to stream: the client renders an
 * already-ticked checklist and then polls for the slow (worker) half.
 */
router.post(
  '/projects/:id/model/auto',
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
    const body = adminAutoModelBodySchema.safeParse(req.body ?? {});
    if (!body.success) {
      const issue = body.error.issues[0];
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
    const actorRole = req.user!.role ?? 'MODEL_ARTIST';
    const rate = await consumeRateWindow(
      `meshy-create:${userId}`,
      env.MESHY_CREATE_MAX_PER_WINDOW,
      env.MESHY_CREATE_WINDOW_SECONDS
    );
    if (rate.limited) {
      res.status(429).json({
        status: 'error',
        code: 'RATE_LIMITED',
        message: 'Too many model generation requests. Please try again later.',
        retryAfter: rate.retryAfter,
      });
      return;
    }

    const forced = body.data.force === true;
    let result;
    try {
      result = await generateModelOnDemand({
        projectId: params.data.id,
        actor: { userId, role: actorRole },
        force: forced,
      });
    } catch (err: unknown) {
      // Infrastructure, not a business refusal — and the steps decided so far
      // are the diagnosis ("which step were we on when S3 stopped answering").
      if (err instanceof GenerationInfrastructureError) {
        res.status(502).json({
          status: 'error',
          code: 'GENERATION_UNAVAILABLE',
          message: 'Could not read this capture right now. Please try again.',
          steps: err.steps,
        });
        return;
      }
      throw err;
    }

    if (result.outcome === 'BLOCKED') {
      if (result.reason === 'PROJECT_NOT_FOUND') {
        res.status(404).json({
          status: 'error',
          code: 'NOT_FOUND',
          message: 'Project not found.',
          steps: result.steps,
        });
        return;
      }
      if (result.reason === 'NOT_EXPORTABLE') {
        res.status(422).json({
          status: 'error',
          code: 'NOT_EXPORTABLE',
          message: 'This project has no finalized capture to generate a model from.',
          steps: result.steps,
        });
        return;
      }
      res.status(409).json({
        status: 'error',
        code: result.reason,
        message:
          result.reason === 'DISABLED'
            ? 'On-demand model generation is switched off.'
            : 'Daily model generation limit reached. Try again tomorrow.',
        steps: result.steps,
      });
      return;
    }

    if (result.outcome === 'DECLINED') {
      // The counters behind the refusal — the payload that says whether a
      // real-world decline is a bad capture or a threshold that needs moving.
      track(AnalyticsEvent.MODEL_GENERATION_DECLINED, {
        actor_id_hash: hashIdentifier(userId),
        project_id_hash: hashIdentifier(params.data.id),
        trigger: 'manual_button',
        reason: result.reason,
        pool_size: result.trace.poolSize,
        dropped_no_blur: result.trace.droppedNoBlurScore,
        quadrants_filled: result.trace.quadrantHistogram.filter((n) => n > 0).length,
      });
      res.status(422).json({
        status: 'error',
        code: 'NOT_SELECTABLE',
        message: 'These photos cannot support a 3D model.',
        reason: result.reason,
        steps: result.steps,
        trace: result.trace,
      });
      return;
    }

    const record = await findProjectModelById(result.modelId);
    const model = record ? toProjectModelDto(record) : null;
    track(AnalyticsEvent.MODEL_GENERATION_REQUESTED, {
      actor_id_hash: hashIdentifier(userId),
      project_id_hash: hashIdentifier(params.data.id),
      job_id_hash: hashIdentifier(model?.jobId ?? 'unknown'),
      model_id_hash: hashIdentifier(result.modelId),
      source: 'meshy',
      key_count: model?.selectedKeys.length ?? MIN_SELECTED_PHOTOS,
      was_replay: result.outcome === 'REPLAYED',
      trigger: 'manual_button',
      actor_role: actorRole,
      forced,
    });

    // A replay is not a new creation — 200 distinguishes it from the 201 that
    // actually enqueued (and paid for) a generation.
    res.status(result.outcome === 'REPLAYED' ? 200 : 201).json({
      status: 'success',
      model,
      steps: result.steps,
      ...(result.outcome === 'ENQUEUED' ? { trace: result.trace } : {}),
    });
  })
);

/**
 * POST /admin/projects/:id/model-images/upload-urls — presigned PUT slots for
 * EDITED copies of selected photos (the Prepare-Images screen: polygon crop /
 * background removal / lighting), uploaded before Create-Model so a generation
 * runs on cleaned-up inputs while the original captures stay untouched.
 *
 * MODEL_ARTIST+ like Create-Model itself. Stateless and cheap (local presigns,
 * no credits, no DB writes) — so the rate window is its own generous cap, and
 * the credit guards remain on POST /model. The response's `uploads[].url`
 * values are WRITE bearer credentials: the ONLY place they may appear — never
 * in logs or analytics.
 */
router.post(
  '/projects/:id/model-images/upload-urls',
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
    const body = adminModelImageUploadsBodySchema.safeParse(req.body);
    if (!body.success) {
      const issue = body.error.issues[0];
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
    const rate = await consumeRateWindow(
      `model-image-uploads:${userId}`,
      env.MODEL_IMAGE_UPLOAD_MAX_PER_WINDOW,
      env.MODEL_IMAGE_UPLOAD_WINDOW_SECONDS
    );
    if (rate.limited) {
      res.status(429).json({
        status: 'error',
        code: 'RATE_LIMITED',
        message: 'Too many upload requests. Please try again later.',
        retryAfter: rate.retryAfter,
      });
      return;
    }

    const result = await createModelImageUploadUrls(params.data.id, body.data.count);

    if (result.outcome === 'PROJECT_NOT_FOUND') {
      res.status(404).json({ status: 'error', code: 'NOT_FOUND', message: 'Project not found.' });
      return;
    }
    if (result.outcome === 'NOT_EXPORTABLE') {
      res.status(409).json({
        status: 'error',
        code: 'NOT_EXPORTABLE',
        message: 'This project has no finalized upload to generate a model from.',
      });
      return;
    }

    track(AnalyticsEvent.MODEL_IMAGE_UPLOADS_GENERATED, {
      actor_id_hash: hashIdentifier(userId),
      project_id_hash: hashIdentifier(result.projectId),
      job_id_hash: hashIdentifier(result.jobId),
      file_count: result.uploads.length,
      ttl_seconds: env.MODEL_IMAGE_UPLOAD_URL_TTL_SECONDS,
    });

    res.status(200).json({
      status: 'success',
      uploads: result.uploads,
      expiresAt: result.expiresAt,
    });
  })
);

/**
 * GET /admin/projects/:id/models — the project's full generation history,
 * newest first. History (not just the latest) is the point: an artist compares
 * attempts from different photo selections and approves the best one.
 */
router.get(
  '/projects/:id/models',
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

    const models = await listProjectModels(params.data.id);
    res.status(200).json({ status: 'success', models: models.map(toProjectModelDto) });
  })
);

/**
 * POST /admin/projects/:id/models/:modelId/approve — the "we're satisfied with
 * the Meshy result, no manual creation needed" gate. SUCCEEDED records only.
 */
router.post(
  '/projects/:id/models/:modelId/approve',
  asyncHandler(async (req, res) => {
    const params = adminModelIdParamsSchema.safeParse(req.params);
    if (!params.success) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: params.error.issues[0]?.message ?? 'Invalid request',
      });
      return;
    }

    const userId = req.user!.userId;
    const result = await approveModel(params.data.id, params.data.modelId, {
      userId,
      role: req.user!.role ?? 'MODEL_ARTIST',
    });

    if (result.outcome === 'MODEL_NOT_FOUND') {
      res.status(404).json({ status: 'error', code: 'NOT_FOUND', message: 'Model not found.' });
      return;
    }
    if (result.outcome === 'NOT_APPROVABLE') {
      res.status(409).json({
        status: 'error',
        code: 'NOT_APPROVABLE',
        message: 'Only a successfully generated model can be approved.',
      });
      return;
    }

    const model = toProjectModelDto(result.model);
    track(AnalyticsEvent.MODEL_APPROVED, {
      actor_id_hash: hashIdentifier(userId),
      project_id_hash: hashIdentifier(model.projectId),
      model_id_hash: hashIdentifier(model.id),
      source: model.source,
    });

    res.status(200).json({ status: 'success', model });
  })
);

export default router;
