// src/validation/repSchemas.ts
//
// Zod schemas for the /rep route group — the acting-on-behalf-of surface.
//
// EVERY FIELD HERE IS BORROWED, NOT DECLARED. The code refinement comes from
// qrSchemas, the phone from authSchemas, the name and contact from
// catalogSchemas. That is the whole design of this file: a rep-created catalog
// must satisfy exactly the rules an owner-created one does, and a rep-typed
// phone must normalise exactly as the OTP flow's does — and the only way to
// guarantee either is to import the one schema rather than restate it. A
// locally-declared field in this file is a bug waiting for the day the other
// side's bounds change.
import { z } from 'zod';

import { qrCodeParam } from '@/validation/qrSchemas';
import { phoneField } from '@/validation/authSchemas';
import { catalogNameField, businessNameField, contactSchema } from '@/validation/catalogSchemas';

/**
 * POST /rep/activations.
 *
 * `.strict()` for the same reason every catalog schema is: ownership comes from
 * the resolved restaurant user and the token, never from the body, so a
 * `userId` or `catalogId` smuggled in here must be REJECTED rather than
 * ignored — silently dropping it makes a privilege-escalation attempt look like
 * a success.
 *
 * `restaurantPhone` is the identity the restaurant will later sign in with. It
 * parses through the OTP flow's own `phoneField`, so the string stored at
 * activation is byte-identical to the one `verifyOtpService` will look up.
 */
export const repActivationSchema = z
  .object({
    code: qrCodeParam,
    restaurantName: catalogNameField,
    restaurantPhone: phoneField,
    businessName: businessNameField.optional(),
    contact: contactSchema.optional(),
    /**
     * Stage 16 (Q4): activate this standee on a NEW BRANCH of the restaurant
     * that already owns an account — its own outlet, standee pool and page.
     */
    branchName: z.string().trim().min(2).max(40).optional(),
  })
  .strict();

export type RepActivationInput = z.infer<typeof repActivationSchema>;

/** POST /rep/catalogs/:id/qr-codes — attach a replacement standee. */
export const attachQrCodeSchema = z.object({ code: qrCodeParam }).strict();

export type AttachQrCodeInput = z.infer<typeof attachQrCodeSchema>;

/**
 * POST /rep/catalogs/:id/unpublish/admin — an ADMIN's takedown. The reason is
 * REQUIRED and is shown to the restaurant's owner, so it has to be a sentence,
 * not a keystroke: 5–500 characters after trimming.
 */
export const ADMIN_UNPUBLISH_REASON_MIN = 5;
export const ADMIN_UNPUBLISH_REASON_MAX = 500;
export const adminUnpublishSchema = z
  .object({
    reason: z
      .string()
      .trim()
      .min(ADMIN_UNPUBLISH_REASON_MIN, 'Give a reason of at least 5 characters.')
      .max(ADMIN_UNPUBLISH_REASON_MAX, 'Keep the reason under 500 characters.'),
  })
  .strict();

export type AdminUnpublishInput = z.infer<typeof adminUnpublishSchema>;
