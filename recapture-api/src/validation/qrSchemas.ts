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
