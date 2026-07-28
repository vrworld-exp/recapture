// src/validation/adminSchemas.ts
//
// Zod schemas for the staff-only /admin route group (min role MODEL_ARTIST).
// Query/param validation is done inline with safeParse in the handlers, per
// the AGENTS.md convention — these routes have no bodies.
import { z } from 'zod';
import { PROJECT_STATUS_VALUES } from '@/models/Project';

/**
 * GET /admin/projects query. Same limit bounds as the owner list (1-100,
 * default 20). `status` optionally overrides the default uploaded-and-finalized
 * filter (PROCESSING/COMPLETED) with ONE explicit status — restricted to the
 * ProjectStatus enum so the filter can never be a free-form string.
 */
export const adminListProjectsQuerySchema = z
  .object({
    limit: z.coerce.number().int().min(1).max(100).default(20),
    cursor: z.string().min(1).optional(),
    status: z.enum(PROJECT_STATUS_VALUES).optional(),
  })
  .strict();

export type AdminListProjectsQuery = z.infer<typeof adminListProjectsQuerySchema>;

const OBJECT_ID_RE = /^[a-fA-F0-9]{24}$/;

/** `:id` param for /admin/projects/:id and its /export. Malformed → 400. */
export const adminProjectIdParamsSchema = z
  .object({
    id: z.string().regex(OBJECT_ID_RE, 'Invalid project id'),
  })
  .strict();

/**
 * Body for DELETE /admin/projects/:id/photos: the RELATIVE keys (exactly as the
 * export manifest emits them, e.g. `images/EYE/eye_0001.jpg`) to soft-delete.
 * At least one, bounded to a job's object count ceiling so one request can't ask
 * to move thousands of objects. Per-key CONTAINMENT (no traversal / prefix
 * escape) is enforced in the service against the resolved job prefix — the shape
 * check here only guarantees non-empty strings.
 */
export const adminDeletePhotosBodySchema = z
  .object({
    keys: z.array(z.string().min(1).max(1024)).min(1).max(500),
  })
  .strict();

export type AdminDeletePhotosBody = z.infer<typeof adminDeletePhotosBodySchema>;

/**
 * How an admin project delete behaves. SOFT = flag `deletedAt` (hidden from
 * every list, recoverable by the team); HARD = permanently erase the project,
 * its jobs, its model records and every S3 object they own.
 */
export const ADMIN_DELETE_MODES = ['SOFT', 'HARD'] as const;
export type AdminDeleteMode = (typeof ADMIN_DELETE_MODES)[number];

/**
 * Body for DELETE /admin/projects/:id. `confirmName` must echo the project's
 * exact name for BOTH modes — the server-side confirmation the owner delete
 * route already enforces; deleting someone ELSE'S capture deserves no less.
 */
export const adminDeleteProjectBodySchema = z
  .object({
    mode: z.enum(ADMIN_DELETE_MODES),
    confirmName: z.string().min(1).max(200),
  })
  .strict();

export type AdminDeleteProjectBody = z.infer<typeof adminDeleteProjectBodySchema>;

/**
 * Body for POST /admin/projects/:id/model: the RELATIVE export-manifest keys of
 * the 3–4 photos the staff user picked for Meshy generation.
 *
 * The 3–4 bound is asserted HERE only as a cheap shape check — the authority is
 * projectModelsService (MIN/MAX_SELECTED_PHOTOS), which counts AFTER deduping,
 * so `[a, a, a, b]` is correctly a 2-photo selection and rejected there rather
 * than passing this length test. Per-key containment is likewise the service's
 * job, against the resolved job prefix.
 */
export const adminCreateModelBodySchema = z
  .object({
    keys: z.array(z.string().min(1).max(1024)).min(3).max(4),
  })
  .strict();

export type AdminCreateModelBody = z.infer<typeof adminCreateModelBodySchema>;

/**
 * Body for POST /admin/projects/:id/model/auto — the "Generate 3D model"
 * button, where the SERVER picks the photos.
 *
 * No keys: choosing them is the whole point. `force` is the staff-only
 * escape hatch that mints a fresh idempotency key so a second press pays for a
 * second generation; without it a repeat press replays the existing record,
 * which is what keeps the button from being a hole in the budget.
 */
export const adminAutoModelBodySchema = z
  .object({
    force: z.boolean().optional(),
  })
  .strict();

export type AdminAutoModelBody = z.infer<typeof adminAutoModelBodySchema>;

/**
 * Body for POST /admin/projects/:id/model-images/upload-urls: how many edited
 * model-input images the Prepare-Images screen will upload. Bounded by the
 * Meshy selection ceiling — a prep session never needs more slots than photos
 * a generation can consume.
 */
export const adminModelImageUploadsBodySchema = z
  .object({
    count: z.number().int().min(1).max(4),
  })
  .strict();

export type AdminModelImageUploadsBody = z.infer<typeof adminModelImageUploadsBodySchema>;

/**
 * Query for GET /admin/projects/:id/photo-bytes — the read-through proxy the
 * Prepare-Images screen falls back to when it cannot fetch a presigned URL
 * directly (browser, no raw-bucket CORS; or an expired presign).
 *
 * Same key shape as a Create-Model selection element. Containment against the
 * resolved job prefix is the SERVICE's job, exactly as for `keys` above — this
 * only bounds the string.
 */
export const adminPhotoBytesQuerySchema = z
  .object({
    key: z.string().min(1).max(1024),
  })
  .strict();

export type AdminPhotoBytesQuery = z.infer<typeof adminPhotoBytesQuerySchema>;

/** `:id`/`:modelId` params for the model approve route. */
export const adminModelIdParamsSchema = z
  .object({
    id: z.string().regex(OBJECT_ID_RE, 'Invalid project id'),
    modelId: z.string().regex(OBJECT_ID_RE, 'Invalid model id'),
  })
  .strict();
