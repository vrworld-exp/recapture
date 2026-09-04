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
import {
  catalogNameField,
  businessNameField,
  contactSchema,
} from '@/validation/catalogSchemas';

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
  })
  .strict();

export type RepActivationInput = z.infer<typeof repActivationSchema>;

/** POST /rep/catalogs/:id/qr-codes — attach a replacement standee. */
export const attachQrCodeSchema = z.object({ code: qrCodeParam }).strict();

export type AttachQrCodeInput = z.infer<typeof attachQrCodeSchema>;
