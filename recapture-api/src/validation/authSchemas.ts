// src/validation/authSchemas.ts
import { z } from 'zod';

// E.164: a leading '+', a non-zero country digit, then up to 14 more digits.
const E164 = /^\+[1-9]\d{7,14}$/;

// Identifier normalization, shared by send + verify so lookups always match:
// phone has spaces/dashes stripped and is E.164-checked; email is trimmed and
// lowercased.
const phoneField = z
  .string()
  .trim()
  .min(8)
  .max(20)
  .transform((p) => p.replace(/[\s-]/g, ''))
  .refine((p) => E164.test(p), 'phone must be in E.164 format (e.g. +919876543210)');

const emailField = z.string().trim().toLowerCase().email();

// Exactly six digits.
const codeField = z.string().regex(/^\d{6}$/, 'code must be 6 digits');

/**
 * POST /auth/send-otp body. A discriminated union on `channel` guarantees the
 * matching identifier is present; `.strict()` rejects the *other* identifier (so
 * supplying both phone and email is a 400).
 */
export const sendOtpSchema = z.discriminatedUnion('channel', [
  z.object({ channel: z.literal('sms'), phone: phoneField }).strict(),
  z.object({ channel: z.literal('email'), email: emailField }).strict(),
]);

export type SendOtpInput = z.infer<typeof sendOtpSchema>;

/**
 * POST /auth/verify-otp body. Same discriminated union + identical identifier
 * normalization as send-otp (so the stored record is found), plus the submitted
 * `code`.
 */
export const verifyOtpSchema = z.discriminatedUnion('channel', [
  z.object({ channel: z.literal('sms'), phone: phoneField, code: codeField }).strict(),
  z.object({ channel: z.literal('email'), email: emailField, code: codeField }).strict(),
]);

export type VerifyOtpInput = z.infer<typeof verifyOtpSchema>;

/**
 * POST /auth/refresh body. Body transport mirrors what verify-otp returns. A
 * missing/empty token is surfaced as a generic 401 by the route (not a 400),
 * so failures across all causes stay enumeration-safe.
 */
export const refreshSchema = z
  .object({
    refreshToken: z.string().min(1),
  })
  .strict();

export type RefreshInput = z.infer<typeof refreshSchema>;
