// src/validation/projectSchemas.ts
import { z } from 'zod';

/**
 * GET /projects query params. `limit` is coerced and hard-bounded to 1-100
 * (default 20) so a client can never trigger an unbounded scan; `cursor` is an
 * optional opaque pagination token (decoded separately, defensively).
 */
export const listProjectsQuerySchema = z
  .object({
    limit: z.coerce.number().int().min(1).max(100).default(20),
    cursor: z.string().min(1).optional(),
  })
  .strict();

export type ListProjectsQuery = z.infer<typeof listProjectsQuerySchema>;

// Allowed values mirror the app's apiValues (lowercase). The service maps these
// to the Project model's UPPERCASE enums for storage.
export const OBJECT_SIZE_VALUES = ['small', 'medium', 'large'] as const;
export const CAPTURE_MODE_VALUES = ['guided', 'manual'] as const;

// Upper bound matches the Project model's `name` maxlength (100). The app caps
// its input shorter (60), so any client-valid name passes here.
const NAME_MAX = 100;

/**
 * POST /projects body. `size` and `mode` are strictly enum-validated (no
 * free-form strings); `category` is optional free-form (the product has no fixed
 * taxonomy). `.strict()` rejects unknown fields — notably an `ownerId`/`userId`
 * in the body, which must never influence ownership.
 */
export const createProjectSchema = z
  .object({
    name: z.string().trim().min(1).max(NAME_MAX),
    size: z.enum(OBJECT_SIZE_VALUES),
    mode: z.enum(CAPTURE_MODE_VALUES),
    category: z.string().trim().min(1).max(50).optional(),
  })
  .strict();

export type CreateProjectInput = z.infer<typeof createProjectSchema>;

// A Mongo ObjectId rendered as a 24-char hex string. Validating the shape here
// keeps a malformed `:id` a 400 without ever touching the DB, and keeps mongoose
// out of the validation layer (consistent with the rest of this file).
const OBJECT_ID_RE = /^[a-fA-F0-9]{24}$/;

/**
 * `:id` path param for project routes that target a single project (DELETE,
 * PATCH). Malformed id → 400 (never queried).
 */
export const projectIdParamsSchema = z
  .object({
    id: z.string().regex(OBJECT_ID_RE, 'Invalid project id'),
  })
  .strict();

export type ProjectIdParams = z.infer<typeof projectIdParamsSchema>;

/**
 * `:id`/`:modelId` params for the owner-facing model actions (optimize).
 * Mirrors the admin router's adminModelIdParamsSchema — same shape, separate
 * declaration, because the two routers validate their own surfaces.
 */
export const ownerModelIdParamsSchema = z
  .object({
    id: z.string().regex(OBJECT_ID_RE, 'Invalid project id'),
    modelId: z.string().regex(OBJECT_ID_RE, 'Invalid model id'),
  })
  .strict();

/**
 * DELETE /projects/:id body. The client must echo the project's exact current
 * `name` as `confirmName` — a server-enforced guard against accidental
 * destructive deletes. Presence is validated here; the value is matched against
 * the stored name in the service. `.strict()` rejects unknown fields.
 */
export const deleteProjectBodySchema = z
  .object({
    confirmName: z.string().min(1),
  })
  .strict();

export type DeleteProjectInput = z.infer<typeof deleteProjectBodySchema>;

/**
 * PATCH /projects/:id body — rename only. `name` uses the EXACT same bounds as
 * {@link createProjectSchema} (trim, 1..NAME_MAX) so create and rename never
 * diverge. `.strict()` rejects every other field, so `objectSize`/`category`/
 * `mode`/`userId` cannot be smuggled into a rename.
 */
export const renameProjectSchema = z
  .object({
    name: z.string().trim().min(1).max(NAME_MAX),
  })
  .strict();

export type RenameProjectInput = z.infer<typeof renameProjectSchema>;
