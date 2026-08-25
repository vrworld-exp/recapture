// src/validation/projectPhotoSchemas.ts
//
// Zod schemas for the artist photo-upload surface
// (POST/GET/DELETE /projects/:id/photos*). Mirrors projectSchemas.ts: every
// object is `.strict()` so an unknown field is a 400 rather than something
// silently ignored, and the `:id` param schema is the SAME one the rest of the
// /projects router uses (imported, not re-derived).
//
// The client NEVER names a file. It sends only `{ contentType, size }` per
// photo, in the order it intends them to appear, and the server assigns every
// key from utils/s3Keys.ts — which is what keeps the extension and the charset
// controlled and stops a hostile filename from reaching S3.
import { z } from 'zod';

import { env } from '@/config/env';
import { UPLOADED_PHOTO_CONTENT_TYPES } from '@/utils/s3Keys';
import { MAX_SELECTED_PHOTOS, MIN_SELECTED_PHOTOS } from '@/services/projectModelsService';

export { projectIdParamsSchema, type ProjectIdParams } from '@/validation/projectSchemas';

/**
 * One file the client intends to upload. `size` is the client's claim — it
 * bounds the request cheaply, but the REAL enforcement is at commit, where the
 * server reads each object's listed size (presigning cannot cap a body).
 */
const photoFileSchema = z
  .object({
    contentType: z.enum(UPLOADED_PHOTO_CONTENT_TYPES),
    size: z.number().int().positive().max(env.PROJECT_PHOTO_MAX_BYTES),
  })
  .strict();

/** POST /projects/:id/photos/session body. */
export const photoSessionSchema = z
  .object({
    files: z
      .array(photoFileSchema)
      .min(env.PROJECT_PHOTO_MIN_COUNT)
      .max(env.PROJECT_PHOTO_MAX_COUNT),
  })
  .strict();

export type PhotoSessionInput = z.infer<typeof photoSessionSchema>;

// A Mongo ObjectId rendered as 24 hex chars — the same shape projectSchemas
// validates `:id` against, applied here to a body field.
const OBJECT_ID_RE = /^[a-fA-F0-9]{24}$/;

/** POST /projects/:id/photos/commit body. */
export const photoCommitSchema = z
  .object({
    jobId: z.string().regex(OBJECT_ID_RE, 'Invalid job id'),
  })
  .strict();

export type PhotoCommitInput = z.infer<typeof photoCommitSchema>;

/**
 * DELETE /projects/:id/photos body — job-RELATIVE keys, exactly as
 * `GET /projects/:id/photos` emits them. Shape is re-validated in the service
 * against `isUploadedPhotoRelativeKey`; the bound here only stops an unbounded
 * list from reaching it.
 */
export const photoDeleteSchema = z
  .object({
    keys: z.array(z.string().min(1)).min(1).max(env.PROJECT_PHOTO_MAX_COUNT),
  })
  .strict();

export type PhotoDeleteInput = z.infer<typeof photoDeleteSchema>;

/**
 * POST /projects/:id/photos/generate body — the hand-picked selection.
 *
 * The 3..4 bound reuses the generation service's own constants rather than
 * restating them: this route feeds `createMeshyModelRequest`, which enforces
 * the identical range AFTER dedupe, and two independently written bounds would
 * eventually disagree.
 */
export const photoGenerateSchema = z
  .object({
    keys: z.array(z.string().min(1)).min(MIN_SELECTED_PHOTOS).max(MAX_SELECTED_PHOTOS),
  })
  .strict();

export type PhotoGenerateInput = z.infer<typeof photoGenerateSchema>;
