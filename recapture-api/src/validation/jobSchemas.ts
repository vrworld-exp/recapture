// src/validation/jobSchemas.ts
import { z } from 'zod';
import { OBJECT_SIZE_VALUES } from '@/validation/projectSchemas';
import {
  CAPTURE_FLOW_VARIANTS,
  CAPTURE_MODES,
  DEFAULT_CAPTURE_FLOW_VARIANT,
  DEFAULT_CAPTURE_MODE,
} from '@/models/types/captureVariants';

/**
 * Absolute upper bound on `expectedFilesCount` — a sanity cap far above any
 * legitimate capture (both flow variants max out at 48 images plus the
 * manifest), so a garbage/hostile count can never inflate a job record. The
 * variant-derived RANGE (coverage minimum … full total) is enforced in the
 * service, where the job's captureVariant is known.
 */
export const EXPECTED_FILES_MAX = 1_000;

// Same shape rule as projectIdParamsSchema: a Mongo ObjectId as 24-char hex,
// validated here so a malformed id is a 400 without touching the DB.
const OBJECT_ID_RE = /^[a-fA-F0-9]{24}$/;

/**
 * POST /jobs body. `objectSize` uses the SAME lowercase wire enum as
 * POST /projects (the service maps to the model's UPPERCASE values and
 * cross-checks it against the project's stored size). `.strict()` rejects
 * unknown fields — notably a `userId`/`jobId` in the body, which must never
 * influence ownership or identity.
 */
export const createJobSchema = z
  .object({
    projectId: z.string().regex(OBJECT_ID_RE, 'Invalid project id'),
    objectSize: z.enum(OBJECT_SIZE_VALUES),
    // Optional with a default so pre-variant clients (which never send it)
    // keep working unchanged as full three-ring captures.
    captureVariant: z.enum(CAPTURE_FLOW_VARIANTS).default(DEFAULT_CAPTURE_FLOW_VARIANT),
    // Same treatment, same reason: a client that predates Meshy mode never
    // sends this and must keep creating full captures unchanged.
    captureMode: z.enum(CAPTURE_MODES).default(DEFAULT_CAPTURE_MODE),
    expectedFilesCount: z.coerce
      .number()
      .int('expectedFilesCount must be an integer')
      .positive('expectedFilesCount must be positive')
      .max(EXPECTED_FILES_MAX, `expectedFilesCount must be at most ${EXPECTED_FILES_MAX}`),
  })
  .strict();

export type CreateJobInput = z.infer<typeof createJobSchema>;

/**
 * The optional `Idempotency-Key` request header (standard name; no prior
 * idempotency convention existed in this codebase — this endpoint introduces a
 * minimal per-endpoint mechanism). Bounded so the unique index never stores an
 * unbounded client string.
 */
export const idempotencyKeySchema = z.string().min(1).max(128);

/** `:jobId` path param — malformed id is a 400 without touching the DB. */
export const jobIdParamsSchema = z
  .object({
    jobId: z.string().regex(OBJECT_ID_RE, 'Invalid job id'),
  })
  .strict();

/**
 * Sanity ceiling on a single capture file (bytes) — far above any real photo
 * or manifest, far below S3's 5 TiB object limit, so a garbage size can never
 * demand thousands of presigned parts.
 */
export const FILE_SIZE_MAX = 5 * 1024 * 1024 * 1024; // 5 GiB

/** S3's multipart part-count hard limit (also enforced against fileSize in the
 * service, where the achievable range is known). */
const PART_COUNT_MAX = 10_000;

/**
 * POST /jobs/:jobId/uploads/initiate body — one file's multipart initiate.
 * `key` is the FULL object key (containment under the job's keyPrefix is
 * checked in the service, where the prefix is known); `fileSize`/`partCount`
 * come from the client's part plan (the server cannot know file sizes).
 */
export const initiateUploadSchema = z
  .object({
    key: z.string().min(1).max(1024),
    fileSize: z.coerce
      .number()
      .int('fileSize must be an integer')
      .positive('fileSize must be positive')
      .max(FILE_SIZE_MAX, `fileSize must be at most ${FILE_SIZE_MAX}`),
    partCount: z.coerce
      .number()
      .int('partCount must be an integer')
      .min(1)
      .max(PART_COUNT_MAX),
  })
  .strict();

export type InitiateUploadInput = z.infer<typeof initiateUploadSchema>;

/**
 * POST /jobs/:jobId/uploads/part-url body — re-presign ONE part's URL after
 * the original expired (the engine's 403-recovery path).
 */
export const partUrlSchema = z
  .object({
    key: z.string().min(1).max(1024),
    uploadId: z.string().min(1).max(1024),
    partNumber: z.coerce.number().int().min(1).max(PART_COUNT_MAX),
  })
  .strict();

export type PartUrlInput = z.infer<typeof partUrlSchema>;

/**
 * POST /jobs/:jobId/uploads/complete body — commit ONE file's multipart upload
 * server-side (no presigned complete exists; the SDK call needs credentials).
 * `parts` carries the client-collected part ETags in the shape S3 expects
 * back, bounded by S3's own part-count ceiling. The uploadId is NOT
 * pre-validated — a stale/foreign id is S3's error to raise (part-url policy).
 */
export const completeUploadSchema = z
  .object({
    key: z.string().min(1).max(1024),
    uploadId: z.string().min(1).max(1024),
    parts: z
      .array(
        z
          .object({
            partNumber: z.coerce.number().int().min(1).max(PART_COUNT_MAX),
            etag: z.string().min(1).max(256),
          })
          .strict()
      )
      .min(1, 'parts must not be empty')
      .max(PART_COUNT_MAX),
  })
  .strict();

export type CompleteUploadInput = z.infer<typeof completeUploadSchema>;

/**
 * POST /jobs/:jobId/finalize body. Usually empty; `reportedFilesCount` is an
 * OPTIONAL client cross-check — S3 stays the verification authority either
 * way. `.strict()` rejects unknown fields.
 */
export const finalizeJobSchema = z
  .object({
    reportedFilesCount: z.coerce
      .number()
      .int('reportedFilesCount must be an integer')
      .positive('reportedFilesCount must be positive')
      .max(EXPECTED_FILES_MAX)
      .optional(),
  })
  .strict();

export type FinalizeJobInput = z.infer<typeof finalizeJobSchema>;
