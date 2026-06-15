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
