// src/validation/qrSchemas.ts
//
// Zod schemas for the QR inventory surface. Same two house rules as
// catalogSchemas.ts: `.strict()` everywhere, and bounds that mirror the model's
// so a value that passes here cannot fail Mongoose validation as a 500.
import { z } from 'zod';
import { env } from '@/config/env';
import { normalizeQrCode } from '@/utils/qrCodes';

/**
 * A printed code, accepted in whatever form a human typed it and TRANSFORMED to
 * the stored form. Downstream code therefore never sees `abcd-2345`.
 *
 * Shared deliberately: the resolver and the activation endpoint must agree
 * character-for-character on what a valid code is, and the only way to
 * guarantee that is for both to import this.
 */
export const qrCodeParam = z
  .string()
  .transform((raw, ctx) => {
    const normalized = normalizeQrCode(raw);
    if (!normalized) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'Invalid QR code' });
      return z.NEVER;
    }
    return normalized;
  });

/**
 * POST /admin/qr-batches.
 *
 * The upper bound is checked in a `refine` rather than baked in with `.max()`
 * so it is read from `env` AT PARSE TIME. A `.max(env.QR_BATCH_MAX_SIZE)`
 * captured at module load would freeze whatever the value was when this file
 * was first imported, which is both a config-reload hazard and untestable.
 *
 * The bound lives here, not in the handler, so anyone reading the schema can
 * see what the endpoint will accept. It bounds ONE bad request, not total
 * inventory — minting a second batch is always allowed.
 */
export const mintQrBatchSchema = z
  .object({
    count: z
      .number()
      .int('count must be a whole number')
      .positive('count must be at least 1')
      .refine(
        (n) => n <= env.QR_BATCH_MAX_SIZE,
        () => ({ message: `count must be at most ${env.QR_BATCH_MAX_SIZE}` })
      ),
    label: z.string().trim().min(1, 'label is required').max(120, 'label must be at most 120 characters'),
  })
  .strict();

export type MintQrBatchInput = z.infer<typeof mintQrBatchSchema>;

/**
 * GET /admin/qr-batches/:batchId/codes query.
 *
 * `after` is the previous page's last code, normalised through the SAME
 * transform every other code path uses — so a cursor echoed back from a row the
 * screen is holding cannot be rejected for a formatting difference the client
 * never introduced.
 *
 * The 200 ceiling is a response-size bound, not a policy: a 2,000-code batch is
 * the default ceiling of one mint, and shipping it in a single JSON body is how
 * an admin screen becomes the slowest page in the app.
 */
export const adminBatchCodesQuerySchema = z
  .object({
    limit: z.coerce.number().int().positive().max(200).default(100),
    after: qrCodeParam.optional(),
  })
  .strict();

export type AdminBatchCodesQuery = z.infer<typeof adminBatchCodesQuerySchema>;

/**
 * The standee-sheet query, for BOTH callers that render one:
 * `GET /admin/qr-codes/:code/qr` and `GET /rep/standees/:code/qr`.
 *
 * Deliberately the same shape as `catalogQrQuerySchema` — same formats, same
 * "clamp the size rather than reject it" rule — because it feeds the same
 * renderer. That one stays in catalogSchemas.ts, which its own route group
 * owns; the two standee callers share THIS one, because they are both the QR
 * inventory surface and this file is where that surface's validation lives.
 * (The earlier note here said to hoist when a third caller appeared. The rep
 * download is that caller, and this rename is the hoist.)
 */
export const standeeQrQuerySchema = z
  .object({
    format: z.enum(['png', 'pdf']).default('png'),
    size: z.coerce.number().int().positive().optional(),
  })
  .strict();

export type StandeeQrQuery = z.infer<typeof standeeQrQuerySchema>;

/**
 * POST /admin/qr-codes/:code/assignment — hand this standee to that rep.
 *
 * The id is checked for SHAPE only. Whether it names a real account, and one
 * with a role that can act on the assignment, is decided by
 * `standeeAssignmentService.assignCode` against the database — a schema cannot
 * know that, and splitting the check across both would leave two places to fix
 * when the set of assignable roles changes.
 */
export const assignStandeeSchema = z
  .object({
    repUserId: z
      .string()
      .trim()
      .regex(/^[a-fA-F0-9]{24}$/, 'repUserId must be a valid id'),
  })
  .strict();

export type AssignStandeeInput = z.infer<typeof assignStandeeSchema>;
