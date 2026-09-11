// src/routes/admin.ts
//
// Staff-only route group (mounted at /admin): cross-user live-project browse,
// presigned-URL export, Meshy model generation, and ADMIN-only curation
// (photo soft-delete, project soft/hard delete). Every route runs requireAuth →
// requireRole('MODEL_ARTIST') — ADMIN passes by role inheritance; destructive
// routes add their own requireRole('ADMIN'). Standard envelope throughout.
import { Router } from 'express';
import { Types } from 'mongoose';
import { asyncHandler } from '@/utils/asyncHandler';
import { requireAuth } from '@/middleware/auth';
import { requireRole } from '@/middleware/requireRole';
import { hasRoleAtLeast } from '@/models/User';
import { validateBody } from '@/middleware/validate';
import {
  adminListProjectsQuerySchema,
  adminProjectIdParamsSchema,
  adminUserIdParamsSchema,
  adminDeletePhotosBodySchema,
  adminDeleteProjectBodySchema,
  adminCreateModelBodySchema,
  adminAutoModelBodySchema,
  adminModelIdParamsSchema,
  adminModelImageUploadsBodySchema,
  adminPhotoBytesQuerySchema,
  adminSubmitModelBodySchema,
  type AdminSubmitModelBody,
} from '@/validation/adminSchemas';
import { decodeCursor, type ProjectCursor } from '@/utils/cursor';
import {
  getAdminUserDetail,
  readUserAvatarBytes,
} from '@/services/adminUsersService';
import {
  listAllCapturedProjects,
  getAdminProjectDetail,
  buildProjectExport,
  listProjectPhotos,
  softDeleteProjectPhotos,
  adminDeleteProject,
} from '@/services/adminProjectsService';
import {
  approveModel,
  createMeshyModelRequest,
  createModelImageUploadUrls,
  createModelUploadUrl,
  submitUploadedModel,
  readProjectPhotoBytes,
  findProjectModelById,
  latestSucceededModel,
  listProjectModels,
  optimizedSourceIdsFor,
  requestModelOptimization,
  toProjectModelDto,
  MAX_SELECTED_PHOTOS,
  MIN_SELECTED_PHOTOS,
  NOT_OPTIMIZABLE_CODES,
  NOT_OPTIMIZABLE_MESSAGES,
} from '@/services/projectModelsService';
import {
  generateModelOnDemand,
  GenerationInfrastructureError,
} from '@/services/onDemandModelGenerationService';
import { consumeRateWindow } from '@/utils/rateLimit';
import { env } from '@/config/env';
import { hashIdentifier } from '@/utils/otp';
import { track, AnalyticsEvent } from '@/utils/analytics';
import { QrBatch } from '@/models/QrBatch';
import {
  exportBatchCsv,
  findByCode,
  listBatchCodes,
  listBatches,
  loadBatchSheet,
  mintBatch,
  slugifyBatchLabel,
  QrBatchTooLargeError,
  QrResolverNotConfiguredError,
} from '@/services/qrCodeService';
import {
  adminBatchCodesQuerySchema,
  assignStandeeSchema,
  mintQrBatchSchema,
  qrCodeParam,
  standeeQrQuerySchema,
  type AssignStandeeInput,
  type MintQrBatchInput,
} from '@/validation/qrSchemas';
import {
  renderBatchStandeeSheet,
  renderStandeeSheet,
  STANDEE_ARTWORK_VERSION,
} from '@/services/standeeSheetService';
import { StandeeSheetLayoutError } from '@/services/standeeSheetPdf';
import {
  assignBatchCodes,
  unassignBatchCodes,
  assignCode,
  findAssignableRep,
  listAssignableReps,
  unassignCode,
} from '@/services/standeeAssignmentService';
import { ifNoneMatchSatisfied, strongETag } from '@/utils/etag';

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
 *
 * FOR AN ADMIN each item also carries a compact `owner` (display name + "has a
 * picture") so the Live-projects list can label who captured it. That is the
 * whole widening: still no identifier of any kind here, masked or otherwise —
 * contact details are a separate, audited call (GET /admin/users/:id). A
 * MODEL_ARTIST sees the field absent and the opaque `ownerId` it always saw.
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

    // requireRole resolved the role from a FRESH DB read, so a revoked admin
    // stops receiving owner names on their very next page — no token lag.
    const isAdmin = hasRoleAtLeast(req.user!.role ?? 'MODEL_ARTIST', 'ADMIN');

    const { items, nextCursor } = await listAllCapturedProjects(
      parsed.data.limit,
      cursor,
      parsed.data.status,
      isAdmin
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
    const model = latestModel
      ? toProjectModelDto(latestModel, await optimizedSourceIdsFor(params.data.id))
      : null;

    res.status(200).json({
      status: 'success',
      project: detail.project,
      job: detail.job,
      model,
    });
  })
);

/** Which KINDS of contact an account carried, for the owner-view audit event.
 * Deliberately not a pair of booleans — see the event's schema note. */
function contactChannelsOf(user: { email: string | null; phone: string | null }):
  | 'none'
  | 'sms'
  | 'mail'
  | 'both' {
  if (user.phone !== null && user.email !== null) return 'both';
  if (user.phone !== null) return 'sms';
  if (user.email !== null) return 'mail';
  return 'none';
}

/**
 * GET /admin/users/:id — the identity behind a live project: name, role, and
 * the RAW email/phone.
 *
 * ADMIN-ONLY, with its own requireRole('ADMIN') above the router's
 * MODEL_ARTIST gate — the same shape as the destructive curation routes, and
 * for a comparable reason: this is one of only TWO routes in the API that answer
 * with an unmasked contact identifier — the other is the rep's delegated
 * restaurant profile, bounded by the activation that typed the number (see
 * AGENTS.md §PII and the account block in routes/rep.ts). Everything else ships
 * a mask (utils/maskIdentifier.ts). The exception exists because an admin looking at a
 * bad capture needs to CONTACT the person who made it, and a mask cannot be
 * dialled; the reasoning and its bounds live in services/adminUsersService.ts.
 *
 * Metered per admin (a scraping bound — see env.ADMIN_USER_LOOKUP_*) and
 * AUDITED: the analytics event carries HASHED ids and booleans only, never the
 * identifier and never the name.
 *
 * A project's `ownerId` is the id to call this with; anything unresolvable is a
 * plain 404, so a row that outlived its account reads as "no longer exists".
 */
router.get(
  '/users/:id',
  requireRole('ADMIN'),
  asyncHandler(async (req, res) => {
    const params = adminUserIdParamsSchema.safeParse(req.params);
    if (!params.success) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: params.error.issues[0]?.message ?? 'Invalid user id',
      });
      return;
    }

    const rate = await consumeRateWindow(
      `admin-user-lookup:${req.user!.userId}`,
      env.ADMIN_USER_LOOKUP_MAX_PER_WINDOW,
      env.ADMIN_USER_LOOKUP_WINDOW_SECONDS
    );
    if (rate.limited) {
      res.status(429).json({
        status: 'error',
        code: 'RATE_LIMITED',
        message: 'Too many lookups. Please try again later.',
        retryAfter: rate.retryAfter,
      });
      return;
    }

    const user = await getAdminUserDetail(params.data.id);
    if (!user) {
      res.status(404).json({
        status: 'error',
        code: 'NOT_FOUND',
        message: 'This account no longer exists.',
      });
      return;
    }

    track(AnalyticsEvent.ADMIN_PROJECT_OWNER_VIEWED, {
      actor_id_hash: hashIdentifier(req.user!.userId),
      subject_id_hash: hashIdentifier(user.id),
      subject_role: user.role,
      // WHICH KINDS of identifier existed, never the values — and note the prop
      // name: `has_phone`/`has_email` would be stripped by the emit layer and
      // take the whole audit event down with them. See the event's schema note.
      contact_channels: contactChannelsOf(user),
    });

    // Private and uncacheable: this body carries an unmasked identifier, so no
    // shared cache and no browser disk copy may hold it.
    res.setHeader('Cache-Control', 'no-store');
    res.status(200).json({ status: 'success', user });
  })
);

/**
 * GET /admin/users/:id/avatar/bytes — that person's profile picture, proxied.
 *
 * BYTES rather than the presigned `avatarUrl` the account snapshot uses, for
 * the reason already documented on GET /auth/me/avatar/bytes and the admin
 * photo-bytes proxy: the raw bucket serves no CORS, so the Flutter WEB build
 * cannot render a presigned URL as an image at all. One route therefore serves
 * the apk and the web build alike.
 *
 * The key is read from the USER DOCUMENT, never from the caller — there is no
 * `?key=` here, and adding one would turn this into an arbitrary-object reader
 * for the private bucket.
 *
 * "No picture" and "the pointer outlived the object" are the same 404: the
 * client falls back to initials for both, and a face photo is not worth a
 * distinguishing error code.
 */
router.get(
  '/users/:id/avatar/bytes',
  requireRole('ADMIN'),
  asyncHandler(async (req, res) => {
    const params = adminUserIdParamsSchema.safeParse(req.params);
    if (!params.success) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: params.error.issues[0]?.message ?? 'Invalid user id',
      });
      return;
    }

    const avatar = await readUserAvatarBytes(params.data.id);
    if (avatar.outcome === 'absent') {
      res.status(404).json({
        status: 'error',
        code: 'NOT_FOUND',
        message: 'No profile picture set.',
      });
      return;
    }

    // Private: authenticated, personal imagery — never a shared cache. The
    // short max-age is what keeps a scrolled list from re-fetching the same
    // face on every rebuild.
    res.setHeader('Cache-Control', 'private, max-age=300');
    res.setHeader('Content-Type', avatar.contentType);
    res.status(200).send(avatar.body);
  })
);

/**
 * GET /admin/projects/:id/photos — the capture set of the project's most recent
 * upload-finalized job, as bare keys + sizes.
 *
 * Deliberately NOT rate-limited, and that is the whole point of it existing:
 * it mints no credentials, so browsing costs nothing from the export budget.
 * The Preview gallery lists from here and renders each key through
 * `/photo-bytes`; it asks for `/export` only when a downloadable URL is
 * actually needed. Before this route the gallery reused the export manifest to
 * draw thumbnails, so ten opens exhausted a cap meant for ten real exports.
 */
router.get(
  '/projects/:id/photos',
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

    const result = await listProjectPhotos(params.data.id);

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
        message: 'This project has no finalized upload to preview.',
      });
      return;
    }

    res.status(200).json({ status: 'success', photos: result.photos });
  })
);

/**
 * GET /admin/projects/:id/export — the presigned-URL export manifest for the
 * project's most recent upload-finalized job.
 *
 * NOT rate-limited by default. The Preview gallery's Download and the Live
 * tab's Export both mint through here, and the old per-user cap (10/hour)
 * reached staff as "Preview limit reached" after ten downloads — a limit on
 * looking at photos was never the intent. The window survives only as an
 * opt-in meter (`ADMIN_EXPORT_MAX_PER_WINDOW` > 0); at the default of 0 it
 * is skipped entirely. The presigned URLs are still bearer credentials: the
 * response's `files[].url` values are the ONLY place one may appear — never in
 * logs or analytics (ids there are hashed). Callers that only need to LOOK at
 * the photos still want `/photos` + `/photo-bytes`; this one hands out
 * downloadable URLs.
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
    // Opt-in only: 0 (the default) means unlimited — see the route note.
    if (env.ADMIN_EXPORT_MAX_PER_WINDOW > 0) {
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
          message: 'This project has no finalized capture or photo set to generate a model from.',
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
 * POST /admin/projects/:id/model/upload-url — a presigned PUT slot for a GLB
 * the staff user built themselves ("Submit model" on the Live projects list).
 *
 * MODEL_ARTIST+ like the rest of this group. Costs no credits and writes
 * nothing — the record is created by the commit route below — so the guard here
 * is only its own rate window. The response's `upload.url` is a WRITE bearer
 * credential: route response only, never a log or an analytics property.
 */
router.post(
  '/projects/:id/model/upload-url',
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
      `model-upload:${userId}`,
      env.MODEL_UPLOAD_MAX_PER_WINDOW,
      env.MODEL_UPLOAD_WINDOW_SECONDS
    );
    if (rate.limited) {
      res.status(429).json({
        status: 'error',
        code: 'RATE_LIMITED',
        message: 'Too many model submissions. Please try again later.',
        retryAfter: rate.retryAfter,
      });
      return;
    }

    const result = await createModelUploadUrl(params.data.id);
    if (result.outcome === 'PROJECT_NOT_FOUND') {
      res.status(404).json({ status: 'error', code: 'NOT_FOUND', message: 'Project not found.' });
      return;
    }
    if (result.outcome === 'NOT_EXPORTABLE') {
      res.status(409).json({
        status: 'error',
        code: 'NOT_EXPORTABLE',
        message: 'This project has no finalized upload to attach a model to.',
      });
      return;
    }

    track(AnalyticsEvent.MODEL_UPLOAD_URL_GENERATED, {
      actor_id_hash: hashIdentifier(userId),
      project_id_hash: hashIdentifier(result.projectId),
      job_id_hash: hashIdentifier(result.jobId),
      ttl_seconds: env.MODEL_UPLOAD_URL_TTL_SECONDS,
    });

    res.status(200).json({ status: 'success', upload: result.upload });
  })
);

/**
 * POST /admin/projects/:id/model/upload — commit the staged GLB as a model on
 * this project.
 *
 * The bytes are already in S3 (the client PUT them to the slot above); this
 * validates what landed and promotes it, so the response is the finished model
 * record and NOT a queued job. That is the whole difference from Create-Model:
 * there is nothing to generate and nothing to wait for, which is why the client
 * can show a plain success message and the owner sees the model immediately.
 */
router.post(
  '/projects/:id/model/upload',
  validateBody(adminSubmitModelBodySchema),
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

    const body = req.body as AdminSubmitModelBody;
    const result = await submitUploadedModel({
      projectId: params.data.id,
      key: body.key,
      // The router already gated on MODEL_ARTIST, so the fallback is the
      // narrowest role that could have reached here — same shape as
      // Create-Model above, never a widening default.
      actor: { userId: req.user!.userId, role: req.user!.role ?? 'MODEL_ARTIST' },
    });

    switch (result.outcome) {
      case 'PROJECT_NOT_FOUND':
        res.status(404).json({ status: 'error', code: 'NOT_FOUND', message: 'Project not found.' });
        return;
      case 'NOT_EXPORTABLE':
        res.status(409).json({
          status: 'error',
          code: 'NOT_EXPORTABLE',
          message: 'This project has no finalized upload to attach a model to.',
        });
        return;
      case 'INVALID_KEY':
        res.status(422).json({
          status: 'error',
          code: 'INVALID_KEY',
          message: 'That upload does not belong to this project.',
        });
        return;
      case 'UPLOAD_MISSING':
        res.status(409).json({
          status: 'error',
          code: 'UPLOAD_MISSING',
          message: 'That upload is no longer available. Please choose the file again.',
        });
        return;
      case 'TOO_LARGE':
        res.status(413).json({
          status: 'error',
          code: 'PAYLOAD_TOO_LARGE',
          message: 'That model is too large. Please submit a smaller file.',
        });
        return;
      case 'NOT_A_GLB':
        res.status(415).json({
          status: 'error',
          code: 'UNSUPPORTED_MEDIA_TYPE',
          message: 'That file is not a .glb model.',
        });
        return;
      case 'STORE_FAILED':
        res.status(502).json({
          status: 'error',
          code: 'STORE_FAILED',
          message: 'The model could not be stored. Please try submitting it again.',
        });
        return;
      case 'CREATED':
        break;
    }

    track(AnalyticsEvent.MODEL_UPLOAD_SUBMITTED, {
      actor_id_hash: hashIdentifier(req.user!.userId),
      project_id_hash: hashIdentifier(params.data.id),
      model_id_hash: hashIdentifier(result.model.id as string),
      size_bytes: result.model.artifacts?.glbBytes ?? 0,
    });

    res.status(201).json({
      status: 'success',
      model: toProjectModelDto(result.model, new Set<string>()),
    });
  })
);

/**
 * GET /admin/projects/:id/photo-bytes?key=… — read-through proxy for ONE
 * capture photo, for the Prepare-Images screen.
 *
 * Exists because a presigned S3 GET is not always usable by the client: the
 * browser build cannot read the raw bucket (no CORS on it), and a long prep
 * session outlives the ~1h presign. The client tries the presigned URL first
 * and only falls back here, so this is not the hot path.
 *
 * MODEL_ARTIST+ like the rest of the prep flow. The `key` is caller-supplied,
 * so the service applies the SAME containment guard as Create-Model before
 * touching S3 — without it this would be an arbitrary-object reader.
 */
router.get(
  '/projects/:id/photo-bytes',
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
    const query = adminPhotoBytesQuerySchema.safeParse(req.query);
    if (!query.success) {
      const issue = query.error.issues[0];
      const field = issue?.path.join('.') || 'query';
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: issue?.message ?? 'Invalid request',
        fields: { [field]: issue?.message ?? 'invalid value' },
      });
      return;
    }

    const result = await readProjectPhotoBytes(params.data.id, query.data.key, query.data.w);

    if (result.outcome === 'PROJECT_NOT_FOUND') {
      res.status(404).json({ status: 'error', code: 'NOT_FOUND', message: 'Project not found.' });
      return;
    }
    if (result.outcome === 'NOT_EXPORTABLE') {
      res.status(409).json({
        status: 'error',
        code: 'NOT_EXPORTABLE',
        message: 'This project has no finalized upload to read photos from.',
      });
      return;
    }
    if (result.outcome === 'INVALID_KEY') {
      res.status(422).json({
        status: 'error',
        code: 'INVALID_KEY',
        message: 'That photo does not belong to this project.',
      });
      return;
    }
    if (result.outcome === 'OBJECT_NOT_FOUND') {
      res.status(404).json({ status: 'error', code: 'NOT_FOUND', message: 'Photo not found.' });
      return;
    }

    // Private: this is authenticated staff-only imagery — never let a shared
    // cache hold it.
    res.setHeader('Cache-Control', 'private, max-age=300');
    res.setHeader('Content-Type', result.contentType);
    res.status(200).send(result.body);
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
    // ONE lookup of "which models already have an optimized derivative" for the
    // whole page — the per-row `canOptimize` verdict is derived from it, never
    // from a query per row.
    const optimizedSourceIds = await optimizedSourceIdsFor(params.data.id);
    res.status(200).json({
      status: 'success',
      models: models.map((m) => toProjectModelDto(m, optimizedSourceIds)),
    });
  })
);

/**
 * POST /admin/projects/:id/models/:modelId/optimize — shrink a generated model
 * and add the result to this project's model list as its own OPT record.
 *
 * MODEL_ARTIST+ (the router-level gate), beside `…/approve`. Costs CPU, never
 * Meshy credits, so it carries none of Create-Model's spend guards; what it
 * does carry is the unique `optimizedFrom` index, which is why a double-tap
 * REPLAYS (200) instead of creating a second record.
 */
router.post(
  '/projects/:id/models/:modelId/optimize',
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
    const result = await requestModelOptimization({
      projectId: params.data.id,
      modelId: params.data.modelId,
      actor: { userId, role: req.user!.role ?? 'MODEL_ARTIST' },
    });

    if (result.outcome === 'PROJECT_NOT_FOUND' || result.outcome === 'MODEL_NOT_FOUND') {
      res.status(404).json({
        status: 'error',
        code: 'NOT_FOUND',
        message: result.outcome === 'PROJECT_NOT_FOUND' ? 'Project not found.' : 'Model not found.',
      });
      return;
    }
    if (result.outcome === 'NOT_OPTIMIZABLE') {
      res.status(409).json({
        status: 'error',
        code: NOT_OPTIMIZABLE_CODES[result.reason],
        message: NOT_OPTIMIZABLE_MESSAGES[result.reason],
      });
      return;
    }

    // The response describes the OPT record, whose own canOptimize is false by
    // definition — the set is passed for consistency, not because it can matter.
    const optimizedSourceIds = await optimizedSourceIdsFor(params.data.id);
    const model = toProjectModelDto(result.model, optimizedSourceIds);
    track(AnalyticsEvent.MODEL_OPTIMIZE_REQUESTED, {
      actor_id_hash: hashIdentifier(userId),
      project_id_hash: hashIdentifier(model.projectId),
      model_id_hash: hashIdentifier(params.data.modelId),
      optimized_model_id_hash: hashIdentifier(model.id),
      source_bytes: result.sourceBytes,
      was_replay: result.outcome === 'REPLAYED',
      surface: 'staff',
    });

    // 200 for a replay, 201 for a record that actually enqueued work — the same
    // distinction Create-Model draws.
    res.status(result.outcome === 'REPLAYED' ? 200 : 201).json({ status: 'success', model });
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

    // The client swaps this row in without re-fetching, so `canOptimize` has to
    // be right here — a fail-closed `false` would make the Optimize button
    // vanish the moment a model was approved.
    const model = toProjectModelDto(result.model, await optimizedSourceIdsFor(params.data.id));
    track(AnalyticsEvent.MODEL_APPROVED, {
      actor_id_hash: hashIdentifier(userId),
      project_id_hash: hashIdentifier(model.projectId),
      model_id_hash: hashIdentifier(model.id),
      source: model.source,
    });

    res.status(200).json({ status: 'success', model });
  })
);
// ── Pre-printed standee inventory (stage 2) ─────────────────────────────────

/**
 * POST /admin/qr-batches — mint a run of blank standee codes.
 *
 * ADMIN-ONLY, a stricter gate than the router-level MODEL_ARTIST: a mint commits
 * the business to a physical print run, and the codes it produces are the thing
 * every future activation hands out. Body `{count, label}`; `count` is bounded
 * by QR_BATCH_MAX_SIZE in the schema, not here.
 *
 * The codes come back UNASSIGNED unless `assignToUserId` names a staff member,
 * in which case the whole run is handed to them in one write — see below.
 * Analytics carries the hashed actor and the batch SIZE only — never a code,
 * which is a public identifier for one restaurant's menu.
 *
 * ⚠ THE REP IS RESOLVED BEFORE ANYTHING IS MINTED, and that ordering is the
 * whole safety argument for doing this in one endpoint. A picker left open while
 * a role was revoked hands us a stale id; if that were discovered AFTER the
 * mint, the admin would be looking at an error over a batch that does exist,
 * and the obvious reaction — press Mint again — commits a second physical print
 * run. Nothing is created until the holder is known to be real.
 */
router.post(
  '/qr-batches',
  requireRole('ADMIN'),
  validateBody(mintQrBatchSchema),
  asyncHandler(async (req, res) => {
    const { count, label, assignToUserId } = req.body as MintQrBatchInput;
    const userId = req.user!.userId;

    // ── 1) Prove the holder exists, while nothing has been committed ─────────
    let rep = null;
    if (assignToUserId) {
      rep = await findAssignableRep(new Types.ObjectId(assignToUserId));
      if (!rep) {
        // The same 404 shape the single-code assignment uses. Not a 400: the id
        // was well-formed, it just does not name someone who can hold a standee.
        res.status(404).json({
          status: 'error',
          code: 'REP_NOT_FOUND',
          message: 'That staff member was not found, or cannot hold standees.',
        });
        return;
      }
    }

    // ── 2) The print run ────────────────────────────────────────────────────
    const { batchId, minted } = await mintBatch({
      count,
      label,
      createdByUserId: new Types.ObjectId(userId),
    });

    // ── 3) The holder, which must never cost us the batch ───────────────────
    // Assignment is ADVISORY (see standeeAssignmentService's header): it changes
    // what each side can SEE and gates nothing. So a failure here is not worth
    // failing a mint over — the codes exist, they are correct, and they can be
    // handed out afterwards. Propagating it would give the admin a 500 over a
    // batch that was created, which is the one outcome that leads to a duplicate
    // print run.
    let assignedTo = null;
    if (rep) {
      try {
        await assignBatchCodes({
          batchId,
          repUserId: new Types.ObjectId(rep.id),
          actorUserId: new Types.ObjectId(userId),
        });
        assignedTo = rep;
      } catch (err) {
        console.warn('[qr-batches] minted but could not assign; codes are unaffected', err);
      }
    }

    track(AnalyticsEvent.QR_BATCH_MINTED, {
      actor_id_hash: hashIdentifier(userId),
      batch_size: minted,
      assigned_on_mint: assignedTo !== null,
    });

    res.status(201).json({
      status: 'success',
      batchId: batchId.toString(),
      minted,
      // Echoed back so the screen can confirm WHO got them, rather than the
      // admin having to open the batch to find out whether it worked.
      assignedTo,
    });
  })
);

/**
 * GET /admin/qr-batches/:batchId/export — the print vendor's CSV.
 *
 * One `code,url` line per standee, no header, so the line count IS the batch
 * count and a short run is visible at a glance. ADMIN-ONLY for the same reason
 * the mint is.
 *
 * Answers 409 when PUBLIC_RESOLVER_BASE_URL is unset rather than emitting URLs
 * against a guessed host — those would be printed onto thousands of physical
 * standees before anyone noticed. `Content-Disposition` is already in the CORS
 * exposedHeaders allowlist (app.ts), so the web client can read the filename.
 */
router.get(
  '/qr-batches/:batchId/export',
  requireRole('ADMIN'),
  asyncHandler(async (req, res) => {
    const { batchId } = req.params;
    if (!Types.ObjectId.isValid(batchId)) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: 'Invalid batch id',
      });
      return;
    }

    let csv: string | null;
    try {
      csv = await exportBatchCsv(new Types.ObjectId(batchId));
    } catch (err) {
      if (err instanceof QrResolverNotConfiguredError) {
        res.status(409).json({
          status: 'error',
          code: 'RESOLVER_NOT_CONFIGURED',
          message: 'PUBLIC_RESOLVER_BASE_URL is not configured on this deployment',
        });
        return;
      }
      throw err;
    }

    if (csv === null) {
      res.status(404).json({
        status: 'error',
        code: 'NOT_FOUND',
        message: 'Batch not found',
      });
      return;
    }

    const batch = await QrBatch.findById(batchId).lean().exec();
    const filename = `qr-batch-${slugifyBatchLabel(batch?.label ?? '')}.csv`;
    res.setHeader('Content-Type', 'text/csv; charset=utf-8');
    res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
    res.status(200).send(csv);
  })
);

/**
 * GET /admin/qr-batches/:batchId/sheet — the whole batch, ready to print.
 *
 * THE OTHER HALF OF THE PILOT PATH. `GET /admin/qr-codes/:code/qr` renders ONE
 * standee, which is right for sending a rep a single code and absurd for a run
 * of fifty: fifty presses, fifty near-identical files, fifty sheets of paper for
 * fifty squares. This is one file — nine standees to an A4 page by default, with
 * cut guides — that an admin sends straight to a printer.
 *
 * ⚠ The squares are a FIXED PHYSICAL SIZE (STANDEE_SHEET_QR_INCHES, 1.67in) and
 * are never scaled to fit more on a page. See `services/standeeSheetPdf.ts` for
 * why that is the one thing the layout will not trade.
 *
 * ADMIN-ONLY, matching the CSV export beside it rather than the router-level
 * MODEL_ARTIST: this is the full list of a run's public identifiers, same as the
 * CSV, just rendered.
 *
 * RETIRED CODES ARE SKIPPED, not refused. The single-code endpoint answers 409
 * for a retired code because rendering it hands somebody one dead sheet; a batch
 * cannot be refused over one dead code, so they come off the sheet and the count
 * is reported in `X-Standee-Sheet-Skipped-Retired` — a batch of 50 that prints
 * 48 reads as a bug unless something says why, and the PDF cannot say it.
 *
 * NOT TRACKED, for the same reason the single-code render is not: a few events a
 * year from a handful of staff, whose only interesting property (the codes) is
 * barred from analytics.
 */
router.get(
  '/qr-batches/:batchId/sheet',
  requireRole('ADMIN'),
  asyncHandler(async (req, res) => {
    const { batchId } = req.params;
    if (!Types.ObjectId.isValid(batchId)) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: 'Invalid batch id',
      });
      return;
    }

    let source;
    try {
      source = await loadBatchSheet(new Types.ObjectId(batchId));
    } catch (err) {
      if (err instanceof QrResolverNotConfiguredError) {
        res.status(409).json({
          status: 'error',
          code: 'RESOLVER_NOT_CONFIGURED',
          message: 'PUBLIC_RESOLVER_BASE_URL is not configured on this deployment',
        });
        return;
      }
      if (err instanceof QrBatchTooLargeError) {
        res.status(409).json({
          status: 'error',
          code: 'BATCH_TOO_LARGE',
          message:
            `This batch has ${err.printable} codes. A printable sheet covers up to ` +
            `${err.limit} at a time — use the vendor CSV for a run this size.`,
        });
        return;
      }
      throw err;
    }

    if (source === null) {
      res.status(404).json({
        status: 'error',
        code: 'NOT_FOUND',
        message: 'Batch not found',
      });
      return;
    }

    // A batch whose every code is retired would render blank paper. Refused
    // rather than delivered, for the same reason one retired code is.
    if (source.items.length === 0) {
      res.status(409).json({
        status: 'error',
        code: 'NOTHING_TO_PRINT',
        message: 'Every code in this batch is retired. Mint replacements instead.',
      });
      return;
    }

    // ── The conditional check happens BEFORE any rendering ──────────────────
    // Unlike the single-code sheet, where rendering first and comparing after
    // costs one small square, this endpoint's work scales with the batch: five
    // hundred encodes and five hundred deflates, thrown away to answer 304. The
    // ETag is a function of the source, so it can be computed without it.
    //
    // Keyed on everything that changes the bytes: which codes are on the sheet,
    // in order, and the geometry they are laid out with. STATE and HOLDER are
    // deliberately absent for the same reason as the single-code sheet —
    // activating or reassigning a standee does not alter one pixel. A
    // RETIREMENT does, by taking a card off, and the code list already carries
    // that.
    const etag = strongETag({
      codes: source.items.map((item) => item.code),
      urls: source.items.map((item) => item.url),
      layout: [
        env.STANDEE_SHEET_QR_INCHES,
        env.STANDEE_SHEET_QR_DPI,
        env.STANDEE_SHEET_COLUMNS,
        env.STANDEE_SHEET_ROWS,
      ],
      label: source.label,
      // And what a card LOOKS like — the one input the others cannot express.
      artwork: STANDEE_ARTWORK_VERSION,
    });
    res.setHeader('ETag', etag);
    res.setHeader('Cache-Control', 'private, max-age=3600');
    if (ifNoneMatchSatisfied(req.header('If-None-Match'), etag)) {
      res.status(304).end();
      return;
    }

    let sheet;
    try {
      sheet = await renderBatchStandeeSheet(source);
    } catch (err) {
      if (err instanceof StandeeSheetLayoutError) {
        res.status(409).json({
          status: 'error',
          code: 'SHEET_LAYOUT_INVALID',
          message: err.message,
        });
        return;
      }
      throw err;
    }

    // What the client says out loud after the download: "48 standees over 8
    // pages, 2 retired and skipped". None of it is in the PDF, and none of it
    // fits in a body that is already the file.
    res.setHeader('X-Standee-Sheet-Standees', String(sheet.standees));
    res.setHeader('X-Standee-Sheet-Pages', String(sheet.pages));
    res.setHeader('X-Standee-Sheet-Skipped-Retired', String(sheet.skippedRetired));
    res.setHeader('Content-Type', sheet.contentType);
    res.setHeader('Content-Disposition', `attachment; filename="${sheet.filename}"`);
    res.status(200).send(sheet.body);
  })
);

/**
 * GET /admin/qr-batches — the inventory listing behind the admin standee screen.
 *
 * ADMIN-only, matching the mint and the export rather than the router-level
 * MODEL_ARTIST: a batch label and its remaining stock say how many restaurants
 * the business is about to be able to onboard, which is not a model artist's
 * business.
 *
 * READ-ONLY and unrated. It carries no code values, so unlike the export it is
 * not a list of public identifiers, and an admin refreshing a screen is not a
 * threat model worth a rate window.
 */
router.get(
  '/qr-batches',
  requireRole('ADMIN'),
  asyncHandler(async (_req, res) => {
    const batches = await listBatches();
    res.status(200).json({ status: 'success', batches });
  })
);

/**
 * GET /admin/qr-batches/:batchId/codes?limit=&after= — one page of a batch.
 *
 * Keyset paging: `nextAfter` is the last code of this page, or null when the
 * page came back short. A short page is the ONLY end-of-list signal — asking for
 * a total would cost a countDocuments per request to tell the screen something
 * it learns for free one request later.
 *
 * Answers 409 when PUBLIC_RESOLVER_BASE_URL is unset, for the same reason the
 * export does: every row carries the URL the standee encodes, and a URL against
 * a guessed host is the one output here that can be printed onto something
 * physical.
 */
router.get(
  '/qr-batches/:batchId/codes',
  requireRole('ADMIN'),
  asyncHandler(async (req, res) => {
    const { batchId } = req.params;
    if (!Types.ObjectId.isValid(batchId)) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: 'Invalid batch id',
      });
      return;
    }

    const parsed = adminBatchCodesQuerySchema.safeParse(req.query);
    if (!parsed.success) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: parsed.error.issues[0]?.message ?? 'Invalid request',
      });
      return;
    }

    let codes;
    try {
      codes = await listBatchCodes(new Types.ObjectId(batchId), parsed.data);
    } catch (err) {
      if (err instanceof QrResolverNotConfiguredError) {
        res.status(409).json({
          status: 'error',
          code: 'RESOLVER_NOT_CONFIGURED',
          message: 'PUBLIC_RESOLVER_BASE_URL is not configured on this deployment',
        });
        return;
      }
      throw err;
    }

    if (codes === null) {
      res.status(404).json({
        status: 'error',
        code: 'NOT_FOUND',
        message: 'Batch not found',
      });
      return;
    }

    const nextAfter =
      codes.length === parsed.data.limit ? (codes[codes.length - 1]?.code ?? null) : null;

    res.status(200).json({ status: 'success', codes, nextAfter });
  })
);

/**
 * GET /admin/qr-codes/:code/qr?format=png|pdf&size=<px> — the standee itself.
 *
 * THE PILOT PATH. Before a print vendor is engaged, this is how a code reaches a
 * rep: an admin renders the PDF and sends it, the rep prints one sheet and puts
 * it on the table. The bytes are rendered from `resolverUrlFor(code)`, the SAME
 * composer the vendor CSV uses, so a standee printed from this endpoint and one
 * printed from the CSV are the same physical object.
 *
 * Rendered through `renderCatalogQr` unchanged — it takes the URL verbatim and
 * has never known what a catalog is. `catalogName` becomes the PDF title and the
 * filename stem, so it carries the code: an admin with eight of these in a
 * downloads folder can tell them apart without opening them.
 *
 * NOT TRACKED. `CATALOG_QR_RENDERED` answers "do restaurants use their QR"; the
 * equivalent here would be a few events a year from a handful of staff, and the
 * only property worth having — the code — is a public identifier for one
 * restaurant's menu and is barred from analytics by the same house rule that
 * keeps it out of the mint event.
 *
 * A RETIRED code is REFUSED. Retirement means a standee was replaced; rendering
 * one would hand somebody a sheet that resolves to the fallback page, and the
 * whole cost of this feature lands after it has been printed and put on a table.
 */
router.get(
  '/qr-codes/:code/qr',
  requireRole('ADMIN'),
  asyncHandler(async (req, res) => {
    const code = qrCodeParam.safeParse(req.params.code);
    if (!code.success) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: 'Invalid QR code',
      });
      return;
    }

    const parsed = standeeQrQuerySchema.safeParse(req.query);
    if (!parsed.success) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: parsed.error.issues[0]?.message ?? 'Invalid request',
      });
      return;
    }

    const record = await findByCode(code.data);
    if (!record) {
      res.status(404).json({
        status: 'error',
        code: 'NOT_FOUND',
        message: 'No such code',
      });
      return;
    }

    const { format, size } = parsed.data;

    let rendered;
    try {
      rendered = await renderStandeeSheet({ record, format, size });
    } catch (err) {
      if (err instanceof QrResolverNotConfiguredError) {
        res.status(409).json({
          status: 'error',
          code: 'RESOLVER_NOT_CONFIGURED',
          message: 'PUBLIC_RESOLVER_BASE_URL is not configured on this deployment',
        });
        return;
      }
      throw err;
    }

    if (rendered.outcome === 'CODE_RETIRED') {
      res.status(409).json({
        status: 'error',
        code: 'CODE_RETIRED',
        message: 'This standee was retired. Mint a replacement rather than reprinting it.',
      });
      return;
    }

    // Keyed on everything that changes the bytes and nothing that does not. The
    // code's STATE is deliberately absent: activating a standee does not change
    // what it encodes, which is the entire premise of the resolver. Nor is the
    // HOLDER — assigning a standee does not alter one pixel of the sheet, so a
    // reassignment must not invalidate a cached copy. The ARTWORK version is,
    // because a change to the drawing is invisible to every other key.
    const etag = strongETag({
      url: rendered.url,
      format,
      size: rendered.size,
      artwork: STANDEE_ARTWORK_VERSION,
    });
    res.setHeader('ETag', etag);
    res.setHeader('Cache-Control', 'private, max-age=3600');
    if (ifNoneMatchSatisfied(req.header('If-None-Match'), etag)) {
      res.status(304).end();
      return;
    }

    res.setHeader('Content-Type', rendered.contentType);
    res.setHeader('Content-Disposition', `attachment; filename="${rendered.filename}"`);
    res.status(200).send(rendered.body);
  })
);

/**
 * GET /admin/sales-reps — the staff an admin may hand a standee to.
 *
 * NOT a user directory, and it must not grow into one. It lists accounts that
 * already hold a script-granted staff role — the people who can open `/rep` at
 * all — so it exposes no account an admin could not already reach through the
 * role script. The in-app user-management surface, which WOULD need search,
 * paging and a grant path, remains deliberately unbuilt; this is a picker for
 * one action, not the first half of that feature.
 *
 * Rows carry a display name and a MASKED contact. An admin has to be able to
 * tell two reps apart to hand a standee to the right one, and the masked form
 * is what `GET /auth/me` already ships for exactly that purpose — raw phone and
 * email stay inside the API, as everywhere else.
 */
router.get(
  '/sales-reps',
  requireRole('ADMIN'),
  asyncHandler(async (_req, res) => {
    const reps = await listAssignableReps();
    res.status(200).json({ status: 'success', reps });
  })
);

/**
 * POST /admin/qr-codes/:code/assignment — hand this standee to that rep.
 *
 * IDEMPOTENT AND OVERWRITING. Assigning a code that is already assigned — to
 * the same rep or a different one — succeeds and leaves the named rep holding
 * it. A standee is a physical object that moves between people; refusing the
 * second assignment would mean an admin correcting a mistake has to unassign
 * first, for no gain, since the correction is the whole point.
 *
 * ADVISORY. This does not reserve the code: any rep may still activate any
 * UNASSIGNED standee, and `activationService` never reads the field. See the
 * header of standeeAssignmentService for why that was chosen over a lock.
 */
router.post(
  '/qr-codes/:code/assignment',
  requireRole('ADMIN'),
  validateBody(assignStandeeSchema),
  asyncHandler(async (req, res) => {
    const code = qrCodeParam.safeParse(req.params.code);
    if (!code.success) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: 'Invalid QR code',
      });
      return;
    }

    const { repUserId } = req.body as AssignStandeeInput;
    const result = await assignCode({
      code: code.data,
      repUserId: new Types.ObjectId(repUserId),
      actorUserId: new Types.ObjectId(req.user!.userId),
    });

    switch (result.outcome) {
      case 'CODE_NOT_FOUND':
        res.status(404).json({
          status: 'error',
          code: 'NOT_FOUND',
          message: 'No such code',
        });
        return;
      case 'CODE_RETIRED':
        res.status(409).json({
          status: 'error',
          code: 'CODE_RETIRED',
          message: 'This standee was retired. Assign a replacement instead.',
        });
        return;
      case 'REP_NOT_FOUND':
        // Covers both "no such account" and "that account is not staff". One
        // answer for both, matching the house enumeration rule: an admin needs
        // to know the assignment did not happen, not which of the two it was.
        res.status(404).json({
          status: 'error',
          code: 'REP_NOT_FOUND',
          message: 'That account cannot hold a standee.',
        });
        return;
      case 'ASSIGNED':
        break;
    }

    track(AnalyticsEvent.QR_CODE_ASSIGNED, {
      actor_id_hash: hashIdentifier(req.user!.userId),
      rep_id_hash: hashIdentifier(result.rep.id),
      outcome: 'ASSIGNED',
    });

    res.status(200).json({ status: 'success', code: result.code, assignedTo: result.rep });
  })
);

/**
 * DELETE /admin/qr-codes/:code/assignment — take the standee back.
 *
 * Succeeds on a code nobody holds (see `unassignCode`): the admin asked for it
 * to be on no one's list, and it is.
 */
router.delete(
  '/qr-codes/:code/assignment',
  requireRole('ADMIN'),
  asyncHandler(async (req, res) => {
    const code = qrCodeParam.safeParse(req.params.code);
    if (!code.success) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: 'Invalid QR code',
      });
      return;
    }

    const result = await unassignCode(code.data);
    if (result.outcome === 'CODE_NOT_FOUND') {
      res.status(404).json({
        status: 'error',
        code: 'NOT_FOUND',
        message: 'No such code',
      });
      return;
    }

    // No `rep_id_hash`: the standee is on nobody's list now, and naming who it
    // used to be with would be the one property this event does not need.
    track(AnalyticsEvent.QR_CODE_ASSIGNED, {
      actor_id_hash: hashIdentifier(req.user!.userId),
      outcome: 'UNASSIGNED',
    });

    res.status(200).json({ status: 'success', code: result.code, assignedTo: null });
  })
);

/**
 * POST /admin/qr-batches/:batchId/assignment — hand a WHOLE batch to one rep.
 *
 * THE OTHER HALF OF BULK. Assigning at mint time covers a run created for a
 * known rep; this covers every case where that is not how it went — a batch
 * minted before anyone knew who was carrying it, a rep who left, a territory
 * that moved. Without it an admin is back to one row at a time, which is the
 * problem the bulk path exists to remove.
 *
 * Same ordering rule as the mint: the rep is resolved before anything is
 * written. There is no print run at stake here, but a partial assignment is
 * still worse than none — an admin who saw an error would not know how much of
 * the batch had moved.
 *
 * Overwrites existing holders, matching every other assignment path: a batch
 * handed to somebody new is a batch that moved.
 */
router.post(
  '/qr-batches/:batchId/assignment',
  requireRole('ADMIN'),
  validateBody(assignStandeeSchema),
  asyncHandler(async (req, res) => {
    const { batchId } = req.params;
    if (!Types.ObjectId.isValid(batchId)) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: 'Invalid batch id',
      });
      return;
    }

    const batch = await QrBatch.findById(batchId).select('_id').lean().exec();
    if (!batch) {
      res.status(404).json({ status: 'error', code: 'NOT_FOUND', message: 'Batch not found' });
      return;
    }

    const { repUserId } = req.body as AssignStandeeInput;
    const rep = await findAssignableRep(new Types.ObjectId(repUserId));
    if (!rep) {
      res.status(404).json({
        status: 'error',
        code: 'REP_NOT_FOUND',
        message: 'That staff member was not found, or cannot hold standees.',
      });
      return;
    }

    const { assigned, skippedRetired } = await assignBatchCodes({
      batchId: new Types.ObjectId(batchId),
      repUserId: new Types.ObjectId(rep.id),
      actorUserId: new Types.ObjectId(req.user!.userId),
    });

    // `skippedRetired` is REPORTED, not hidden. "Assigned 18" against a batch of
    // 20 looks like a bug unless the screen can say why the other two were left.
    res.status(200).json({ status: 'success', assigned, skippedRetired, assignedTo: rep });
  })
);

/**
 * DELETE /admin/qr-batches/:batchId/assignment — empty a batch back into stock.
 *
 * Idempotent, like the single-code version: a batch nobody holds answers 200
 * with zero. The admin's intent is satisfied either way, and a 409 would only
 * ever be shown to someone who already has what they asked for.
 */
router.delete(
  '/qr-batches/:batchId/assignment',
  requireRole('ADMIN'),
  asyncHandler(async (req, res) => {
    const { batchId } = req.params;
    if (!Types.ObjectId.isValid(batchId)) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: 'Invalid batch id',
      });
      return;
    }

    const batch = await QrBatch.findById(batchId).select('_id').lean().exec();
    if (!batch) {
      res.status(404).json({ status: 'error', code: 'NOT_FOUND', message: 'Batch not found' });
      return;
    }

    const unassigned = await unassignBatchCodes(new Types.ObjectId(batchId));
    res.status(200).json({ status: 'success', unassigned, assignedTo: null });
  })
);

export default router;
