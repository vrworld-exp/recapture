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
