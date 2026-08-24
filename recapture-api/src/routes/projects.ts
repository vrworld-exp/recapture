// src/routes/projects.ts
import { Router } from 'express';
import type { Types } from 'mongoose';
import { asyncHandler } from '@/utils/asyncHandler';
import { requireAuth } from '@/middleware/auth';
import {
  listProjectsQuerySchema,
  createProjectSchema,
  projectIdParamsSchema,
  ownerModelIdParamsSchema,
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
import {
  photoSessionSchema,
  photoCommitSchema,
  photoDeleteSchema,
  photoGenerateSchema,
} from '@/validation/projectPhotoSchemas';
import {
  createPhotoUploadSession,
  commitPhotoUpload,
  listProjectPhotos,
  softDeleteProjectPhotos,
  findGenerationSourceJob,
} from '@/services/projectPhotosService';
import { requireRole } from '@/middleware/requireRole';
import {
  createMeshyModelRequest,
  findProjectModelById,
  latestOwnerModelFor,
  listOwnerProjectModels,
  pendingOwnerGenerationFor,
  requestModelOptimization,
  MAX_SELECTED_PHOTOS,
  MIN_SELECTED_PHOTOS,
  NOT_OPTIMIZABLE_CODES,
  NOT_OPTIMIZABLE_MESSAGES,
} from '@/services/projectModelsService';
import {
  generateModelOnDemand,
  GenerationInfrastructureError,
  type OnDemandBlockReason,
} from '@/services/onDemandModelGenerationService';
import { consumeRateWindow } from '@/utils/rateLimit';
import { env } from '@/config/env';
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


    console.log('Incoming request query:', req.query); // Log the incoming query for debugging

    const parsed = listProjectsQuerySchema.safeParse(req.query);

    console.log('Parsed query:', parsed); // Log the parsed query for debugging

    if (!parsed.success) {
      console.log('Invalid query parameters:', parsed.error.issues); // Log validation errors
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
 *
 * Also carries `model`: the newest finished 3D model for the project, or null.
 * It rides ALONGSIDE the project DTO rather than inside it — the Project DTO is
 * identical across GET /projects, POST /projects and the Flutter `Project`
 * entity by contract (AGENTS.md), so a field that only this endpoint can answer
 * must not join it. The payload is the owner-safe projection (URL + origin flag
 * + approved): no S3 keys, no staff actor ids.
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

    // Ownership was already proven by getProject(userId, …) above, so this
    // lookup can be by project alone — an owner only ever reaches their own.
    // Two independent facts, deliberately not collapsed into one: the model the
    // owner HAS, and the generation they are WAITING on. A regenerate in flight
    // must not blank out the model already on screen.
    const [model, generation] = await Promise.all([
      latestOwnerModelFor(project.id),
      pendingOwnerGenerationFor(project.id),
    ]);

    res.status(200).json({ status: 'success', project, model, generation });
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

    console.log('Incoming request body:', req.body); // Log the incoming request body for debugging

    const parsed = createProjectSchema.safeParse(req.body);
    if (!parsed.success) {


      console.log('Invalid request body:', parsed.error.issues); // Log validation errors

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
      // Null on an upload project: createProjectSchema refuses a size/mode on
      // one, so there is nothing to report rather than a value to invent.
      object_size: parsed.data.size ?? null,
      mode: parsed.data.mode ?? null,
      source: project.source,
      category: parsed.data.category ?? null,
    });

    res.status(201).json({ status: 'success', project });
  })
);

/**
 * POST /projects/:id/model — the OWNER-facing "Generate 3D model" request.
 *
 * Same server-side selection as the staff button, with every internal fact
 * stripped: no steps, no selector trace, no key names, no phase vocabulary, no
 * hint that Meshy exists. An owner learns only that a model is being made, or
 * one plain reason it cannot be.
 *
 * Gated by MANUAL_MODEL_GENERATION_ENABLED like the staff route. Called two
 * ways: with no body it is idempotent (a repeat replays the existing run — this
 * is what the automatic / post-capture path uses); with `{ regenerate: true }`
 * the owner is deliberately asking for a NEW version of the same capture, so it
 * forces a fresh spend — still bounded by the rate window and the per-user 24h
 * ceiling, which both count it.
 */
router.post(
  '/:id/model',
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

    // Ownership is proven the same way every other owner route proves it, and
    // a project that is missing, not-owned, or soft-deleted is one identical
    // 404 — no existence leak.
    const userId = req.user!.userId;
    const project = await getProject(userId, params.data.id);
    if (!project) {
      res.status(404).json({ status: 'error', code: 'NOT_FOUND', message: 'Project not found.' });
      return;
    }

    const rate = await consumeRateWindow(
      `meshy-create:${userId}`,
      env.MESHY_CREATE_MAX_PER_WINDOW,
      env.MESHY_CREATE_WINDOW_SECONDS
    );
    if (rate.limited) {
      res.status(429).json({
        status: 'error',
        code: 'RATE_LIMITED',
        message: 'Too many requests. Please try again later.',
        retryAfter: rate.retryAfter,
      });
      return;
    }

    // An explicit `{ regenerate: true }` is a deliberate NEW spend on the same
    // capture — the owner asked for a fresh version. Without it the request is
    // idempotent by default (server derives `manual:{jobId}`), so the automatic
    // and post-capture paths can never double-spend on a repeat. A regenerate is
    // NOT unbounded: it still passes through the rate window above AND the
    // per-user 24h ceiling inside the service (MANUAL_MODEL_MAX_PER_USER_PER_DAY),
    // both of which count it. That daily cap is the real "pay again" bound.
    const regenerate =
      req.body != null && (req.body as { regenerate?: unknown }).regenerate === true;

    let result;
    try {
      result = await generateModelOnDemand({
        projectId: project.id,
        actor: { userId, role: 'USER' },
        force: regenerate,
      });
    } catch (err: unknown) {
      if (err instanceof GenerationInfrastructureError) {
        // The steps ride along on the error for staff; the owner gets none.
        res.status(502).json({
          status: 'error',
          code: 'GENERATION_UNAVAILABLE',
          message: "We couldn't start this right now. Please try again.",
        });
        return;
      }
      throw err;
    }

    if (result.outcome === 'BLOCKED') {
      if (result.reason === 'PROJECT_NOT_FOUND') {
        res.status(404).json({ status: 'error', code: 'NOT_FOUND', message: 'Project not found.' });
        return;
      }
      res.status(result.reason === 'NOT_EXPORTABLE' ? 422 : 409).json({
        status: 'error',
        code: OWNER_BLOCK_CODES[result.reason],
        message: OWNER_BLOCK_MESSAGES[result.reason],
      });
      return;
    }

    if (result.outcome === 'DECLINED') {
      track(AnalyticsEvent.MODEL_GENERATION_DECLINED, {
        actor_id_hash: hashIdentifier(userId),
        project_id_hash: hashIdentifier(project.id),
        trigger: 'manual_button',
        reason: result.reason,
        pool_size: result.trace.poolSize,
        dropped_no_blur: result.trace.droppedNoBlurScore,
        quadrants_filled: result.trace.quadrantHistogram.filter((n) => n > 0).length,
      });
      // Mapped copy only. The reason CODE stays out of the body too: it is a
      // rule id from our selector, and it would only invite the client to
      // branch on internals instead of on the message we chose.
      res.status(422).json({
        status: 'error',
        code: 'NOT_SELECTABLE',
        message: OWNER_DECLINE_MESSAGES[result.reason],
      });
      return;
    }

    // Read the record back for the truthful job id and selection size rather
    // than approximating them — an analytics field that lies is worse than one
    // that is missing.
    const record = await findProjectModelById(result.modelId);
    track(AnalyticsEvent.MODEL_GENERATION_REQUESTED, {
      actor_id_hash: hashIdentifier(userId),
      project_id_hash: hashIdentifier(project.id),
      job_id_hash: hashIdentifier(record?.jobId.toHexString() ?? 'unknown'),
      model_id_hash: hashIdentifier(result.modelId),
      source: 'meshy',
      key_count: record?.selectedKeys.length ?? MIN_SELECTED_PHOTOS,
      was_replay: result.outcome === 'REPLAYED',
      trigger: 'manual_button',
      actor_role: 'USER',
      forced: regenerate,
    });

    // 202: the request is accepted and queued; the model itself takes minutes
    // and arrives through the polling the project detail already drives.
    const generation = await pendingOwnerGenerationFor(project.id);
    res.status(202).json({ status: 'success', generation });
  })
);

/** The blocked reasons this route maps (PROJECT_NOT_FOUND is handled above as
 * its own 404, so it is deliberately absent from both tables). */
type MappedOwnerBlockReason = Exclude<OnDemandBlockReason, 'PROJECT_NOT_FOUND'>;

/** Owner-safe error codes for a blocked generation — never the internal reason. */
const OWNER_BLOCK_CODES: Record<MappedOwnerBlockReason, string> = {
  DISABLED: 'GENERATION_UNAVAILABLE',
  USER_CAP_REACHED: 'DAILY_LIMIT_REACHED',
  NOT_EXPORTABLE: 'NOT_READY',
  AUTO_SELECTION_UNAVAILABLE: 'AUTO_SELECTION_UNAVAILABLE',
};

const OWNER_BLOCK_MESSAGES: Record<MappedOwnerBlockReason, string> = {
  DISABLED: '3D model creation is not available right now.',
  USER_CAP_REACHED: "You've reached today's limit for creating 3D models. Try again tomorrow.",
  NOT_EXPORTABLE: 'Finish uploading this capture before creating a 3D model.',
  // Names no pipeline internal — not the selector, not the manifest, not a key
  // layout, and not Meshy. It says what happened and what to do instead.
  AUTO_SELECTION_UNAVAILABLE:
    "This project's photos were uploaded, so photos must be chosen by hand. " +
    'Select 3–4 photos and generate.',
};

/**
 * The decline copy an owner sees. Each one says what to DO about it — an owner
 * cannot act on "INSUFFICIENT_SPREAD", but they can act on "walk all the way
 * around the object".
 */
const OWNER_DECLINE_MESSAGES: Record<
  'MANIFEST_UNREADABLE' | 'NO_USABLE_PHOTOS' | 'INSUFFICIENT_SPREAD',
  string
> = {
  MANIFEST_UNREADABLE: "We couldn't read this capture. Please capture it again.",
  NO_USABLE_PHOTOS:
    'The photos in this capture are too blurry to build a 3D model. Try capturing again in better light, holding the phone steady.',
  INSUFFICIENT_SPREAD:
    'This capture only shows one side of the object. Walk all the way around it and capture again.',
};

/**
 * GET /projects/:id/models — the OWNER-facing model history for their own
 * project, newest first.
 *
 * The owner counterpart of `GET /admin/projects/:id/models`, and deliberately
 * NOT the same payload: it returns {@link OwnerModelListItemDto} rows, which
 * carry no selectedKeys, no generationTrace, no actor ids, no S3 keys and no
 * job/project ids. Staff keep their route; this one exists so an owner never
 * has to be handed the staff projection to see their own models.
 *
 * Scoped by `getProject(userId, id)` — the same ownership proof every other
 * route in this router uses — so "no such project" and "not your project"
 * collapse into one identical 404 and a model list cannot be enumerated across
 * users.
 *
 * Read-only, so it takes no rate window of its own; the optimize action below
 * keeps the one that guards real work.
 */
router.get(
  '/:id/models',
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

    const project = await getProject(req.user!.userId, params.data.id);
    if (!project) {
      res.status(404).json({ status: 'error', code: 'NOT_FOUND', message: 'Project not found.' });
      return;
    }

    const models = await listOwnerProjectModels(project.id);
    res.json({ status: 'success', models });
  })
);

/**
 * POST /projects/:id/models/:modelId/optimize — the OWNER-facing "Optimize"
 * action: make a smaller copy of a model this project already has.
 *
 * Costs no Meshy credits, so none of the generation spend guards apply — but it
 * IS CPU-expensive (glTF-Transform holds the whole document in memory and
 * re-encodes every buffer), so it keeps its own rate window.
 *
 * ENUMERATION-SAFE: "no such project", "not your project" and "no such model in
 * this project" are ONE identical 404, the same stance every other owner route
 * takes. An owner must not be able to probe which model ids exist.
 */
router.post(
  '/:id/models/:modelId/optimize',
  asyncHandler(async (req, res) => {
    const params = ownerModelIdParamsSchema.safeParse(req.params);
    if (!params.success) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: params.error.issues[0]?.message ?? 'Invalid request',
      });
      return;
    }

    const userId = req.user!.userId;
    // Ownership proven the same way as everywhere else — and the ONLY way the
    // service is ever reached, so a cross-user model id can never be optimized.
    const project = await getProject(userId, params.data.id);
    if (!project) {
      res.status(404).json({ status: 'error', code: 'NOT_FOUND', message: 'Project not found.' });
      return;
    }

    const rate = await consumeRateWindow(
      `model-optimize:${userId}`,
      env.MODEL_OPTIMIZE_MAX_PER_WINDOW,
      env.MODEL_OPTIMIZE_WINDOW_SECONDS
    );
    if (rate.limited) {
      res.status(429).json({
        status: 'error',
        code: 'RATE_LIMITED',
        message: 'Too many requests. Please try again later.',
        retryAfter: rate.retryAfter,
      });
      return;
    }

    const result = await requestModelOptimization({
      projectId: project.id,
      modelId: params.data.modelId,
      actor: { userId, role: 'USER' },
    });

    if (result.outcome === 'PROJECT_NOT_FOUND' || result.outcome === 'MODEL_NOT_FOUND') {
      // Collapsed on purpose — see the route comment.
      res.status(404).json({ status: 'error', code: 'NOT_FOUND', message: 'Project not found.' });
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

    track(AnalyticsEvent.MODEL_OPTIMIZE_REQUESTED, {
      actor_id_hash: hashIdentifier(userId),
      project_id_hash: hashIdentifier(project.id),
      model_id_hash: hashIdentifier(params.data.modelId),
      optimized_model_id_hash: hashIdentifier(result.model.id as string),
      source_bytes: result.sourceBytes,
      was_replay: result.outcome === 'REPLAYED',
      surface: 'owner',
    });

    // The owner gets the same minimal projection the rest of this router uses:
    // the id to poll and the status, never the staff DTO.
    res.status(result.outcome === 'REPLAYED' ? 200 : 201).json({
      status: 'success',
      optimization: {
        id: result.model.id as string,
        status: result.model.status,
      },
    });
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

// ── Artist photo-upload projects ─────────────────────────────────────────────
//
// An artist uploads a hand-picked photo set instead of running a guided
// capture. These live on /projects (not /admin) because the artist uploads into
// their OWN project: ownership is proved by `getProject(userId, id)` inside the
// service exactly as every other route in this router does, and missing /
// not-owned / soft-deleted collapse into ONE identical 404.
//
// `requireRole('MODEL_ARTIST')` is applied PER-ROUTE, never `router.use(...)` —
// the owner routes above must stay open to a plain USER. Privilege is inclusive
// upward, so an ADMIN passes. The client's staff gate is UX only; this is the
// security boundary.
//
// The BYTES do not move through here. `POST /jobs/:jobId/uploads/*` is
// unchanged and carries the photo set over the identical presigned-multipart
// transport, with identical resume, retry and progress behaviour.

/**
 * POST /projects/:id/photos/session — open one upload session.
 *
 * Costs nothing: it mints a PHOTO_UPLOAD job and assigns the object keys. The
 * client sends only `{ contentType, size }` per file; every KEY is
 * server-assigned, so a hostile filename never reaches S3.
 */
router.post(
  '/:id/photos/session',
  requireRole('MODEL_ARTIST'),
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
    const body = photoSessionSchema.safeParse(req.body);
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
    const idempotencyKey = req.get('Idempotency-Key');
    const result = await createPhotoUploadSession({
      userId,
      projectId: params.data.id,
      files: body.data.files,
      ...(idempotencyKey ? { idempotencyKey } : {}),
      consumeRate: () =>
        consumeRateWindow(
          `photo-upload-session:${userId}`,
          env.PROJECT_PHOTO_UPLOAD_MAX_PER_WINDOW,
          env.PROJECT_PHOTO_UPLOAD_WINDOW_SECONDS
        ),
    });

    switch (result.outcome) {
      case 'PROJECT_NOT_FOUND':
        res.status(404).json({ status: 'error', code: 'NOT_FOUND', message: 'Project not found.' });
        return;
      case 'NOT_AN_UPLOAD_PROJECT':
        res.status(409).json({
          status: 'error',
          code: 'NOT_AN_UPLOAD_PROJECT',
          message:
            'This project was created for guided capture, so photos cannot be uploaded to it.',
        });
        return;
      case 'RATE_LIMITED':
        res.status(429).json({
          status: 'error',
          code: 'RATE_LIMITED',
          message: 'Too many upload sessions. Please try again later.',
          retryAfter: result.retryAfter,
        });
        return;
    }

    track(AnalyticsEvent.PHOTO_UPLOAD_SESSION_CREATED, {
      user_id_hash: hashIdentifier(userId),
      project_id: result.projectId,
      file_count: result.files.length,
    });

    // 201 for a fresh session, 200 for an Idempotency-Key replay — the same
    // distinction POST /jobs draws.
    res.status(result.outcome === 'REPLAYED' ? 200 : 201).json({
      status: 'success',
      jobId: result.jobId,
      uploadPlan: result.uploadPlan,
      files: result.files,
    });
  })
);

/**
 * POST /projects/:id/photos/commit — verify what landed and close the session.
 *
 * Idempotent. Enforces PROJECT_PHOTO_MAX_BYTES from each object's real size
 * (presigning cannot cap a body) and DELETES an over-cap object. Never queues
 * the job — a PHOTO_UPLOAD job is not processed.
 */
router.post(
  '/:id/photos/commit',
  requireRole('MODEL_ARTIST'),
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
    const body = photoCommitSchema.safeParse(req.body);
    if (!body.success) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: body.error.issues[0]?.message ?? 'Invalid request',
      });
      return;
    }

    const userId = req.user!.userId;
    const result = await commitPhotoUpload({
      userId,
      projectId: params.data.id,
      jobId: body.data.jobId,
    });

    switch (result.outcome) {
      // A job that isn't this project's is an identical 404 to a project that
      // isn't the caller's — no existence leak either way.
      case 'PROJECT_NOT_FOUND':
      case 'JOB_NOT_FOUND':
        res.status(404).json({ status: 'error', code: 'NOT_FOUND', message: 'Project not found.' });
        return;
      case 'PHOTO_TOO_LARGE':
        res.status(413).json({
          status: 'error',
          code: 'PHOTO_TOO_LARGE',
          message:
            `${result.deleted} photo(s) were larger than the limit and were removed. ` +
            'Please re-upload smaller versions.',
        });
        return;
      case 'TOO_FEW_PHOTOS':
        res.status(400).json({
          status: 'error',
          code: 'TOO_FEW_PHOTOS',
          message: `Only ${result.found} photo(s) arrived — at least ${result.minimum} are needed.`,
        });
        return;
    }

    track(AnalyticsEvent.PHOTO_UPLOAD_COMMITTED, {
      user_id_hash: hashIdentifier(userId),
      project_id: result.projectId,
      job_id: result.jobId,
      photo_count: result.photoCount,
      total_bytes: result.totalBytes,
    });

    res.status(200).json({
      status: 'success',
      jobId: result.jobId,
      photoCount: result.photoCount,
      alreadyCommitted: result.alreadyCommitted,
    });
  })
);

/**
 * GET /projects/:id/photos — the uploaded set, presigned for the grid.
 *
 * A presigned URL is a BEARER CREDENTIAL. It appears in this response body and
 * NOWHERE else — never in a log, never in analytics (AGENTS.md).
 */
router.get(
  '/:id/photos',
  requireRole('MODEL_ARTIST'),
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

    const result = await listProjectPhotos({
      userId: req.user!.userId,
      projectId: params.data.id,
    });

    if (result.outcome === 'PROJECT_NOT_FOUND') {
      res.status(404).json({ status: 'error', code: 'NOT_FOUND', message: 'Project not found.' });
      return;
    }
    if (result.outcome === 'NO_PHOTO_SET') {
      // Not an error state: a project whose upload was never started simply has
      // no photos yet, and the grid renders its empty state from this.
      res.status(200).json({ status: 'success', jobId: null, items: [], urlsExpireAt: null });
      return;
    }

    res.status(200).json({
      status: 'success',
      jobId: result.jobId,
      items: result.items,
      urlsExpireAt: result.urlsExpireAt,
    });
  })
);

/**
 * DELETE /projects/:id/photos — soft-delete photos out of the set.
 *
 * Moves each into the job's `deleted/` park (the same namespace the admin photo
 * delete uses) — never a hard delete. FAIL-CLOSED: one escaping key refuses the
 * whole request and moves nothing.
 */
router.delete(
  '/:id/photos',
  requireRole('MODEL_ARTIST'),
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
    const body = photoDeleteSchema.safeParse(req.body);
    if (!body.success) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: body.error.issues[0]?.message ?? 'Invalid request',
      });
      return;
    }

    const result = await softDeleteProjectPhotos({
      userId: req.user!.userId,
      projectId: params.data.id,
      keys: body.data.keys,
    });

    switch (result.outcome) {
      case 'PROJECT_NOT_FOUND':
      case 'NO_PHOTO_SET':
        res.status(404).json({ status: 'error', code: 'NOT_FOUND', message: 'Project not found.' });
        return;
      case 'INVALID_KEY':
        // The offending key is never echoed — it is caller-controlled, and
        // reflecting it would let an attacker probe the message.
        res.status(400).json({
          status: 'error',
          code: 'INVALID_KEY',
          message: "Each key must name a photo in this project's uploaded set.",
        });
        return;
    }

    res.status(200).json({
      status: 'success',
      jobId: result.jobId,
      deleted: result.deleted,
      missing: result.missing,
    });
  })
);

/**
 * POST /projects/:id/photos/generate — the artist's hand-picked generation.
 *
 * THIS is the step that spends Meshy credits, so it keeps every guard the staff
 * surface has: the shared `meshy-create:{userId}` rate window, the
 * `Idempotency-Key` replay guard, and the unique-index race authority inside
 * the service. The source job is resolved SERVER-SIDE (the project's newest
 * UPLOADED photo-upload job) and is never taken from the body.
 *
 * The result union maps to exactly the status codes the staff route already
 * maps — read from it, not invented here.
 */
router.post(
  '/:id/photos/generate',
  requireRole('MODEL_ARTIST'),
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
    const body = photoGenerateSchema.safeParse(req.body);
    if (!body.success) {
      const issue = body.error.issues[0];
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: issue?.message ?? 'Invalid request',
        fields: { keys: `must be ${MIN_SELECTED_PHOTOS}-${MAX_SELECTED_PHOTOS} distinct keys` },
      });
      return;
    }

    const userId = req.user!.userId;

    // Ownership first, so a foreign project is a 404 before any rate window is
    // consumed on the caller's behalf.
    const project = await getProject(userId, params.data.id);
    if (!project) {
      res.status(404).json({ status: 'error', code: 'NOT_FOUND', message: 'Project not found.' });
      return;
    }

    const sourceJob = await findGenerationSourceJob(params.data.id);
    if (!sourceJob) {
      res.status(409).json({
        status: 'error',
        code: 'NOT_EXPORTABLE',
        message: 'Finish uploading this project’s photos before creating a 3D model.',
      });
      return;
    }

    // The SAME window the staff Create-Model route consumes — one ceiling on
    // "generations this user can start", however they start them.
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
      jobId: sourceJob._id as Types.ObjectId,
      ...(idempotencyKey ? { idempotencyKey } : {}),
    });

    switch (result.outcome) {
      case 'PROJECT_NOT_FOUND':
        res.status(404).json({ status: 'error', code: 'NOT_FOUND', message: 'Project not found.' });
        return;
      case 'NOT_EXPORTABLE':
        res.status(409).json({
          status: 'error',
          code: 'NOT_EXPORTABLE',
          message: 'This project has no finished photo upload to generate a model from.',
        });
        return;
      case 'INVALID_COUNT':
        res.status(400).json({
          status: 'error',
          code: 'INVALID_REQUEST',
          message: `Select between ${MIN_SELECTED_PHOTOS} and ${MAX_SELECTED_PHOTOS} distinct photos.`,
          fields: { keys: `must be ${MIN_SELECTED_PHOTOS}-${MAX_SELECTED_PHOTOS} distinct keys` },
        });
        return;
      case 'INVALID_KEY':
        res.status(400).json({
          status: 'error',
          code: 'INVALID_REQUEST',
          message: "Each key must live under the job's file set.",
          fields: { keys: "must be a photo key from this project's uploaded set" },
        });
        return;
    }

    track(AnalyticsEvent.PHOTO_UPLOAD_GENERATION_REQUESTED, {
      user_id_hash: hashIdentifier(userId),
      project_id: params.data.id,
      job_id: sourceJob.id as string,
      selected_count: result.model.selectedKeys.length,
    });

    // A replay is not a new creation — 200 distinguishes it from the 201 that
    // actually enqueued a generation, exactly as the staff route does.
    res.status(result.outcome === 'REPLAYED' ? 200 : 201).json({
      status: 'success',
      modelId: result.model.id as string,
    });
  })
);

export default router;
