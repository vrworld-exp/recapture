// src/validation/authSchemas.ts
import { z } from 'zod';
import { env } from '@/config/env';
import { AVATAR_CONTENT_TYPES } from '@/utils/avatarKeys';

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

/**
 * Stable rule ids for a rejected PATCH /auth/me body. They are part of the API
 * contract (a client may map them to its own copy), so treat them like the
 * manifest-validation rule ids: append, never rename.
 */
export const DISPLAY_NAME_RULES = {
  /** Not a string / field missing / unknown key present. */
  invalid: 'DISPLAY_NAME_INVALID',
  /** Nothing left after trimming. */
  empty: 'DISPLAY_NAME_EMPTY',
  /** More than 60 characters after trimming (matches the schema maxlength). */
  tooLong: 'DISPLAY_NAME_TOO_LONG',
  /** Contains a Unicode control character (newline, tab, NUL, …). */
  invalidChars: 'DISPLAY_NAME_INVALID_CHARS',
} as const;

export type DisplayNameRule = (typeof DISPLAY_NAME_RULES)[keyof typeof DISPLAY_NAME_RULES];

export const DISPLAY_NAME_MAX_LENGTH = 60;

// Any Unicode control character (category Cc — the C0 block, DEL, and C1).
// Checked AFTER trimming, so ordinary leading/trailing whitespace is normalized
// away rather than being an error, while an EMBEDDED newline or NUL — which
// would break the single-line Profile layout — still fails.
const CONTROL_CHARS = /\p{Cc}/u;

/**
 * PATCH /auth/me body — the display name only. `.strict()` rejects any other key
 * (this route must never become a back door for changing phone/email/role).
 *
 * Each rejection carries a stable rule id in `issue.params.rule`; the route maps
 * the first issue onto the standard error envelope. The parsed output is the
 * TRIMMED name, so the persisted value is exactly what was validated.
 */
export const updateProfileSchema = z
  .object({
    displayName: z.string(),
  })
  .strict()
  .superRefine((value, ctx) => {
    const trimmed = value.displayName.trim();
    if (trimmed.length === 0) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['displayName'],
        message: 'displayName must not be empty',
        params: { rule: DISPLAY_NAME_RULES.empty },
      });
      return;
    }
    if (trimmed.length > DISPLAY_NAME_MAX_LENGTH) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['displayName'],
        message: `displayName must be at most ${DISPLAY_NAME_MAX_LENGTH} characters`,
        params: { rule: DISPLAY_NAME_RULES.tooLong },
      });
    }
    if (CONTROL_CHARS.test(trimmed)) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['displayName'],
        message: 'displayName must not contain control characters',
        params: { rule: DISPLAY_NAME_RULES.invalidChars },
      });
    }
  })
  .transform((value) => ({ displayName: value.displayName.trim() }));

export type UpdateProfileInput = z.infer<typeof updateProfileSchema>;

/**
 * POST /auth/me/avatar/upload-url body. `.strict()` for the same reason the
 * profile schema is: this route mints a WRITE credential, so it must never grow
 * a caller-supplied key, user id, or bucket.
 *
 * `contentType` is a closed set because it is baked into the presigned
 * signature — the uploader can then only ever store an object of the declared
 * type — and because it selects the key's extension.
 *
 * `contentLength` is DECLARED, not enforced: S3 presigning has no size
 * condition, so this only rejects an obviously-too-large intent up front. The
 * real ceiling is applied at commit time (PUT /auth/me/avatar HEADs the object).
 */
export const avatarUploadUrlSchema = z
  .object({
    contentType: z.enum(AVATAR_CONTENT_TYPES),
    contentLength: z.coerce
      .number()
      .int()
      .positive()
      .max(env.AVATAR_MAX_BYTES, `contentLength must be at most ${env.AVATAR_MAX_BYTES} bytes`),
  })
  .strict();

export type AvatarUploadUrlInput = z.infer<typeof avatarUploadUrlSchema>;

/**
 * PUT /auth/me/avatar body — the commit. The `key` is CALLER-SUPPLIED, so the
 * schema only checks it is a plausible string; the route re-derives ownership
 * from the token and runs it through parseAvatarKey (the containment guard)
 * before anything touches the DB.
 */
export const avatarCommitSchema = z
  .object({
    key: z.string().min(1).max(512),
  })
  .strict();

export type AvatarCommitInput = z.infer<typeof avatarCommitSchema>;
