// src/routes/auth.ts
import { randomUUID } from 'node:crypto';
import { Router, raw } from 'express';
import { asyncHandler } from '@/utils/asyncHandler';
import { validateBody } from '@/middleware/validate';
import {
  sendOtpSchema,
  verifyOtpSchema,
  refreshSchema,
  updateProfileSchema,
  avatarUploadUrlSchema,
  avatarCommitSchema,
  DISPLAY_NAME_RULES,
  type SendOtpInput,
  type VerifyOtpInput,
} from '@/validation/authSchemas';
import { sendOtp } from '@/services/otpService';
import { verifyOtp } from '@/services/verifyOtpService';
import { refreshSession } from '@/services/refreshTokenService';
import { requireAuth } from '@/middleware/auth';
import { User, type IUser } from '@/models/User';
import { maskIdentifier, contactChannelFor } from '@/utils/maskIdentifier';
import { env } from '@/config/env';
import { s3EnvPrefix } from '@/utils/s3Keys';
import {
  avatarExtensionFor,
  buildAvatarKey,
  buildAvatarPrefix,
  parseAvatarKey,
} from '@/utils/avatarKeys';
import {
  deleteObject,
  deleteObjectsUnderPrefix,
  getObjectBytes,
  headObject,
  listObjectsUnderPrefix,
  presignObjectGetUrl,
  presignObjectPutUrl,
  putObjectBytes,
} from '@/services/s3ObjectStore';
import { AVATAR_CONTENT_TYPES } from '@/utils/avatarKeys';
import { consumeRateWindow } from '@/utils/rateLimit';

const router = Router();

/** Where avatars live: the PRIVATE raw bucket, never the CloudFront-fronted
 * artifacts bucket. An avatar is a photograph of a person's face attached to an
 * account — PII under this repo's stance — so it is never publicly readable by
 * URL. Changing this is a PII policy decision, not an implementation detail. */
const AVATAR_BUCKET = env.S3_BUCKET_RAW;

/**
 * The ONE account-snapshot shape, shared by GET/PATCH /auth/me and by every
 * avatar route, so the client has a single parser rather than four that can
 * drift.
 *
 * PII stance (unchanged in substance): NO raw phone/email ever ships. The client
 * still has to show WHICH account is signed in, so it gets a display MASK
 * (`+91 ••••• ••210` / `a•••@gmail.com`) via @/utils/maskIdentifier — masked-only,
 * never the raw identifier, and null when there is nothing safe to show.
 *
 * AVATAR: `avatarUrl` is a SHORT-LIVED PRESIGNED GET — a bearer credential for
 * that object until `avatarUrlExpiresAt`. It may appear ONLY in a response body:
 * never in a log line, never in analytics. The persisted `avatarKey` is
 * deliberately NOT on the snapshot either; it is an internal identifier and the
 * client has no use for it beyond the commit round-trip it already holds.
 *
 * ASYNC because presigning is async — but it is local SigV4 with no network
 * call (s3ObjectStore.presignObjectGetUrl), so this costs nothing measurable.
 */
async function accountSnapshot(user: IUser): Promise<Record<string, unknown>> {
  const avatarKey = user.avatarKey;
  return {
    id: user.id as string,
    role: user.role,
    displayName: user.displayName ?? null,
    contactMasked: maskIdentifier(user),
    contactChannel: contactChannelFor(user),
    phoneVerified: user.phoneVerified,
    emailVerified: user.emailVerified,
    createdAt: user.createdAt.toISOString(),
    avatarUrl: avatarKey
      ? await presignObjectGetUrl(AVATAR_BUCKET, avatarKey, env.AVATAR_GET_URL_TTL_SECONDS)
      : null,
    avatarUrlExpiresAt: avatarKey
      ? new Date(Date.now() + env.AVATAR_GET_URL_TTL_SECONDS * 1000).toISOString()
      : null,
  };
}

/** The 401 for a valid token whose user no longer exists — same envelope as requireAuth's. */
function vanishedUserBody(): Record<string, string> {
  return {
    status: 'error',
    code: 'UNAUTHENTICATED',
    message: 'Invalid or expired token.',
  };
}

/**
 * GET /auth/me — the authenticated user's own account snapshot; how the client
 * learns its role (fetched at app start / after OTP verify — a role changed by
 * scripts/set-user-role.ts is picked up then, which is the accepted v1 lag) and
 * what the Profile screen renders.
 *
 * Contact identifiers are MASKED-ONLY: the raw phone/email never leaves the API
 * (PII stance), but a mask + its channel do, because the screen must be able to
 * say which account this is. See accountSnapshot above.
 */
router.get(
  '/me',
  requireAuth,
  asyncHandler(async (req, res) => {
    const user = await User.findById(req.user!.userId).exec();
    if (!user) {
      // Valid token for a vanished user — an auth failure, same envelope as
      // requireAuth's own rejections.
      res.status(401).json(vanishedUserBody());
      return;
    }

    res.status(200).json({ status: 'success', user: await accountSnapshot(user) });
  })
);

/**
 * PATCH /auth/me — set the signed-in user's display name. The ONLY mutable field
 * on the account: the body schema is `.strict()`, so this can never become a back
 * door for changing phone/email/role (role is DB-flag-only by design).
 *
 * Returns the same `user` snapshot as GET /auth/me.
 *
 * VALIDATION: parsed inline rather than through `validateBody` so the rejection
 * can carry a STABLE rule id (`rule`) alongside the standard error envelope —
 * the manifest-validation convention. `validateBody` emits a message-only 400 and
 * has no place to put one. The envelope itself is unchanged (status/code/message
 * plus an optional extra field).
 */
router.patch(
  '/me',
  requireAuth,
  asyncHandler(async (req, res) => {
    const parsed = updateProfileSchema.safeParse(req.body);
    if (!parsed.success) {
      const issue = parsed.error.issues[0];
      // Only `custom` issues carry params; a type/strict failure falls back to
      // the generic rule.
      const rule =
        (issue?.code === 'custom' &&
          (issue.params as { rule?: string } | undefined)?.rule) ||
        DISPLAY_NAME_RULES.invalid;
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: issue?.message ?? 'Invalid request',
        rule,
      });
      return;
    }

    const user = await User.findByIdAndUpdate(
      req.user!.userId,
      { $set: { displayName: parsed.data.displayName } },
      { new: true }
    ).exec();
    if (!user) {
      res.status(401).json(vanishedUserBody());
      return;
    }

    res.status(200).json({ status: 'success', user: await accountSnapshot(user) });
  })
);

// ── Profile picture ──────────────────────────────────────────────────────────
//
// A THREE-STEP flow, on purpose:
//
//   1. POST   /auth/me/avatar/upload-url   → { key, url, expiresAt }
//   2. PUT    <url>                        → 200   (client → S3, direct; the
//                                                   bytes never transit this API)
//   3. PUT    /auth/me/avatar  { key }     → { user }
//
// Step 3 is not ceremony. Without it the server never learns the upload
// happened, and a client that died mid-PUT would leave avatarKey pointing at an
// object that does not exist — a permanently broken avatar with no way back.
// It is also where the server VERIFIES rather than trusts: the client supplies
// the key, so the commit re-derives ownership from the token and HEADs the
// object before flipping the pointer.
//
// Every change writes a NEW key (a fresh randomUUID per upload), which buys
// cache-busting for free — no Image.network cache, no CDN, no client ever shows
// the previous picture — and makes the commit a clean pointer flip.

/**
 * POST /auth/me/avatar/upload-url — mint ONE presigned PUT slot for the
 * signed-in user's next profile picture.
 *
 * Stateless and cheap (a local SigV4 presign; no DB write, no S3 call), so like
 * the model-image slots this carries its own generous rate window rather than
 * anything heavier.
 *
 * The returned `url` is a WRITE bearer credential for exactly that key until
 * `expiresAt`: this response body is the ONLY place it may appear — never a log
 * line, never an analytics property.
 */
router.post(
  '/me/avatar/upload-url',
  requireAuth,
  asyncHandler(async (req, res) => {
    const parsed = avatarUploadUrlSchema.safeParse(req.body);
    if (!parsed.success) {
      const issue = parsed.error.issues[0];
      const field = issue?.path.join('.') || 'body';
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: issue?.message ?? 'Invalid request',
        fields: { [field]: issue?.message ?? 'invalid value' },
      });
      return;
    }

    const userId = req.user!.userId;
    const rate = await consumeRateWindow(
      `avatar-upload:${userId}`,
      env.AVATAR_UPLOAD_MAX_PER_WINDOW,
      env.AVATAR_UPLOAD_WINDOW_SECONDS
    );
    if (rate.limited) {
      res.status(429).json({
        status: 'error',
        code: 'RATE_LIMITED',
        message: 'Too many upload requests. Please try again later.',
        retryAfter: rate.retryAfter,
      });
      return;
    }

    // A fresh id every time — see the block comment above.
    const key = buildAvatarKey(
      userId,
      randomUUID(),
      avatarExtensionFor(parsed.data.contentType)
    );
    // The declared content type is part of the SIGNATURE, so the uploader can
    // only ever store an object of that type at that key.
    const url = await presignObjectPutUrl(
      AVATAR_BUCKET,
      key,
      env.AVATAR_UPLOAD_URL_TTL_SECONDS,
      parsed.data.contentType
    );

    res.status(200).json({
      status: 'success',
      key,
      url,
      expiresAt: new Date(
        Date.now() + env.AVATAR_UPLOAD_URL_TTL_SECONDS * 1000
      ).toISOString(),
    });
  })
);

/**
 * POST /auth/me/avatar/bytes — upload a profile picture in ONE call: the raw
 * image body goes to S3 server-side and the pointer is flipped, atomically from
 * the client's point of view. Returns the same `user` snapshot as GET /auth/me.
 *
 * WHY THIS EXISTS ALONGSIDE THE PRESIGNED FLOW. The three-step flow
 * (upload-url → PUT to S3 → commit) keeps image bytes off this API, which is
 * the right shape for capture uploads and works fine from a native client. It
 * cannot work from the BROWSER build: a presigned PUT is a cross-origin request
 * to the raw bucket, and that bucket deliberately serves no CORS policy — the
 * same constraint that forced the admin photo-bytes proxy (routes/admin.ts).
 * Rather than open a PII bucket to browser PUTs, the bytes come through here.
 *
 * An avatar is a single ≤2 MiB image, so proxying it costs little; this
 * reasoning does NOT extend to capture uploads, which must stay direct-to-S3.
 *
 * The body is the image itself (Content-Type: image/jpeg | image/png), not
 * multipart — no parser dependency, and the type is unambiguous.
 *
 * The declared Content-Type is NOT trusted: the magic bytes decide, so a
 * mislabelled body cannot store an object whose stored type lies about its
 * content.
 */
router.post(
  '/me/avatar/bytes',
  requireAuth,
  // Only these two types are parsed at all; anything else leaves req.body
  // unset and falls through to the 415 below. `limit` is the first line of
  // defence on size — the explicit check after it is the second.
  raw({ type: [...AVATAR_CONTENT_TYPES], limit: env.AVATAR_MAX_BYTES }),
  asyncHandler(async (req, res) => {
    const userId = req.user!.userId;

    const body: unknown = req.body;
    if (!Buffer.isBuffer(body) || body.length === 0) {
      res.status(415).json({
        status: 'error',
        code: 'UNSUPPORTED_MEDIA_TYPE',
        message: 'Send the image as a JPEG or PNG body.',
      });
      return;
    }
    if (body.length > env.AVATAR_MAX_BYTES) {
      res.status(413).json({
        status: 'error',
        code: 'PAYLOAD_TOO_LARGE',
        message: 'That image is too large. Please choose a smaller one.',
      });
      return;
    }

    // The bytes, not the header, decide what this is.
    const sniffed = sniffImageContentType(body);
    if (sniffed === null) {
      res.status(415).json({
        status: 'error',
        code: 'UNSUPPORTED_MEDIA_TYPE',
        message: 'That file is not a JPEG or PNG.',
      });
      return;
    }

    const rate = await consumeRateWindow(
      `avatar-upload:${userId}`,
      env.AVATAR_UPLOAD_MAX_PER_WINDOW,
      env.AVATAR_UPLOAD_WINDOW_SECONDS
    );
    if (rate.limited) {
      res.status(429).json({
        status: 'error',
        code: 'RATE_LIMITED',
        message: 'Too many upload requests. Please try again later.',
        retryAfter: rate.retryAfter,
      });
      return;
    }

    const key = buildAvatarKey(userId, randomUUID(), avatarExtensionFor(sniffed));
    await putObjectBytes(AVATAR_BUCKET, key, body, sniffed);

    const user = await User.findByIdAndUpdate(
      userId,
      { $set: { avatarKey: key, avatarUpdatedAt: new Date() } },
      { new: true }
    ).exec();
    if (!user) {
      // The token outlived its user. The object we just wrote has no owner, so
      // take it back out rather than leaving it for a sweep that will never run.
      await deleteObject(AVATAR_BUCKET, key).catch(() => undefined);
      res.status(401).json(vanishedUserBody());
      return;
    }

    // Same ordering rule as the presigned commit: pointer first, cleanup after.
    await sweepOtherAvatarObjects(userId, key);

    res.status(200).json({ status: 'success', user: await accountSnapshot(user) });
  })
);

/** JPEG/PNG by MAGIC BYTES, or null. Mirrors the client's sniffer exactly. */
function sniffImageContentType(bytes: Buffer): 'image/jpeg' | 'image/png' | null {
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return 'image/jpeg';
  }
  const png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (bytes.length >= 8 && png.every((b, i) => bytes[i] === b)) return 'image/png';
  return null;
}

/**
 * PUT /auth/me/avatar — COMMIT an uploaded object as the signed-in user's
 * avatar. Returns the same `user` snapshot as GET /auth/me.
 *
 * The key is caller-supplied, so everything is verified BEFORE the DB is
 * touched, in this order:
 *
 *   1. unparseable key                    → 422 INVALID_KEY
 *   2. key belongs to ANOTHER user        → 403 FORBIDDEN   ← the one that matters:
 *      without it any signed-in user could point their avatar at another user's
 *      object, and the snapshot would then presign a GET of it.
 *   3. key carries a different env prefix → 422 INVALID_KEY (a staging client
 *      must never commit a prod key)
 *   4. no such object in S3               → 409 OBJECT_NOT_FOUND
 *   5. object over the byte ceiling       → 413 PAYLOAD_TOO_LARGE + delete it.
 *      Presigning cannot enforce a size, so this is the ONLY place the ceiling
 *      is real.
 *
 * ORDER OF WRITES: the pointer flips FIRST, cleanup second. A crash after the
 * flip leaves an orphaned object (harmless, and the next commit's prefix sweep
 * collects it); a crash before it would leave the user pointing at a deleted
 * picture (broken).
 */
router.put(
  '/me/avatar',
  requireAuth,
  asyncHandler(async (req, res) => {
    const parsed = avatarCommitSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({
        status: 'error',
        code: 'INVALID_REQUEST',
        message: parsed.error.issues[0]?.message ?? 'Invalid request',
      });
      return;
    }

    const userId = req.user!.userId;
    const key = parsed.data.key;

    const keyParse = parseAvatarKey(key);
    if (!keyParse.ok) {
      res.status(422).json({
        status: 'error',
        code: 'INVALID_KEY',
        message: 'That image key is not a valid avatar key.',
      });
      return;
    }
    if (keyParse.value.userId !== userId) {
      res.status(403).json({
        status: 'error',
        code: 'FORBIDDEN',
        message: 'That image does not belong to this account.',
      });
      return;
    }
    if (keyParse.value.env !== s3EnvPrefix()) {
      res.status(422).json({
        status: 'error',
        code: 'INVALID_KEY',
        message: 'That image key is not a valid avatar key.',
      });
      return;
    }

    const head = await headObject(AVATAR_BUCKET, key);
    if (head.outcome === 'absent') {
      res.status(409).json({
        status: 'error',
        code: 'OBJECT_NOT_FOUND',
        message: 'Upload the image before saving it.',
      });
      return;
    }
    if (head.contentLength > env.AVATAR_MAX_BYTES) {
      // Refuse it AND remove it: an over-cap object that is never committed
      // would otherwise sit in the bucket forever, uncollected (the prefix
      // sweep below only runs on a SUCCESSFUL commit).
      await deleteObject(AVATAR_BUCKET, key).catch(() => undefined);
      res.status(413).json({
        status: 'error',
        code: 'PAYLOAD_TOO_LARGE',
        message: 'That image is too large. Please choose a smaller one.',
      });
      return;
    }

    const user = await User.findByIdAndUpdate(
      userId,
      { $set: { avatarKey: key, avatarUpdatedAt: new Date() } },
      { new: true }
    ).exec();
    if (!user) {
      res.status(401).json(vanishedUserBody());
      return;
    }

    // The pointer has flipped — the save has already succeeded from here on.
    // Sweep every OTHER object under the user's prefix (not just the previous
    // key): that also self-heals the orphans left by presigned uploads the user
    // abandoned before committing. Best-effort by design — a failed cleanup
    // must never turn a successful save into an error.
    await sweepOtherAvatarObjects(userId, key);

    res.status(200).json({ status: 'success', user: await accountSnapshot(user) });
  })
);

/**
 * DELETE /auth/me/avatar — clear the signed-in user's profile picture and
 * remove every stored object for it. Returns the same `user` snapshot.
 *
 * IDEMPOTENT: a user with no avatar gets a plain 200 with the snapshot, never a
 * 404. "Remove my picture" is satisfied either way, and a 404 would just be a
 * failure the client has to special-case into a success.
 */
router.delete(
  '/me/avatar',
  requireAuth,
  asyncHandler(async (req, res) => {
    const userId = req.user!.userId;

    const user = await User.findByIdAndUpdate(
      userId,
      { $unset: { avatarKey: '', avatarUpdatedAt: '' } },
      { new: true }
    ).exec();
    if (!user) {
      res.status(401).json(vanishedUserBody());
      return;
    }

    // Same ordering rule as the commit: the pointer is already cleared, so a
    // failure here leaves orphans, not a broken avatar.
    try {
      await deleteObjectsUnderPrefix(AVATAR_BUCKET, buildAvatarPrefix(userId));
    } catch {
      // Swallowed: the account no longer references anything.
    }

    res.status(200).json({ status: 'success', user: await accountSnapshot(user) });
  })
);

/**
 * GET /auth/me/avatar/bytes — read-through proxy for the signed-in user's OWN
 * avatar.
 *
 * Exists for the same documented reason as the admin photo-bytes proxy: the raw
 * bucket serves no CORS, so the Flutter WEB build cannot fetch the presigned
 * `avatarUrl` as an image subresource. NATIVE clients use `avatarUrl` directly
 * and never hit this route.
 *
 * There is no containment question here at all: the key is read from the
 * TOKEN's user document, never from the caller, so this cannot be turned into
 * an arbitrary-object reader the way a `?key=` parameter could.
 */
router.get(
  '/me/avatar/bytes',
  requireAuth,
  asyncHandler(async (req, res) => {
    const user = await User.findById(req.user!.userId).exec();
    if (!user) {
      res.status(401).json(vanishedUserBody());
      return;
    }
    if (!user.avatarKey) {
      res.status(404).json({
        status: 'error',
        code: 'NOT_FOUND',
        message: 'No profile picture set.',
      });
      return;
    }

    const object = await getObjectBytes(AVATAR_BUCKET, user.avatarKey);
    if (object.outcome === 'absent') {
      // The pointer outlived the object (a manual bucket edit, say). Report it
      // as missing rather than 500 — the client falls back to initials.
      res.status(404).json({
        status: 'error',
        code: 'NOT_FOUND',
        message: 'No profile picture set.',
      });
      return;
    }

    // Private: this is authenticated, personal imagery — never let a shared
    // cache hold it.
    res.setHeader('Cache-Control', 'private, max-age=300');
    res.setHeader('Content-Type', object.contentType);
    res.status(200).send(object.body);
  })
);

/**
 * Best-effort removal of every avatar object of [userId] EXCEPT [keepKey].
 * Never throws — see the commit route's ordering note.
 */
async function sweepOtherAvatarObjects(userId: string, keepKey: string): Promise<void> {
  try {
    const objects = await listObjectsUnderPrefix(AVATAR_BUCKET, buildAvatarPrefix(userId));
    for (const object of objects) {
      if (object.key !== keepKey) {
        await deleteObject(AVATAR_BUCKET, object.key);
      }
    }
  } catch {
    // Swallowed: a failed cleanup must never fail a successful save.
  }
}

/**
 * POST /auth/send-otp — generate and dispatch an OTP via SMS or email.
 *
 * Verification is a separate endpoint and is intentionally not handled here.
 * The success body is identical regardless of whether the identifier maps to a
 * real account (no account enumeration).
 */
router.post(
  '/send-otp',
  validateBody(sendOtpSchema),
  asyncHandler(async (req, res) => {
    const result = await sendOtp(req.body as SendOtpInput);

    if (result.ok) {
      res.status(200).json({
        status: 'success',
        message: 'If the account exists, an OTP has been sent.',
        expiresInSeconds: result.expiresInSeconds,
        // Present only when the service's non-production gate exposed it
        // (dev tooling handshake — the providers are stubs).
        ...(result.devCode !== undefined ? { devCode: result.devCode } : {}),
      });
      return;
    }

    if (result.kind === 'rate_limited') {
      res.status(429).json({
        status: 'error',
        code: 'RATE_LIMITED',
        retryAfter: result.retryAfter,
      });
      return;
    }

    res.status(502).json({
      status: 'error',
      code: 'DISPATCH_FAILED',
      message: 'Could not send OTP. Please try again.',
    });
  })
);

/**
 * POST /auth/verify-otp — validate a submitted OTP and, on success, issue a JWT
 * access token + a rotating refresh token.
 *
 * Enumeration-safe: no-record, expired, wrong-code, and locked all return the
 * SAME generic 401 body — the distinction lives only in analytics.
 */
router.post(
  '/verify-otp',
  validateBody(verifyOtpSchema),
  asyncHandler(async (req, res) => {
    const result = await verifyOtp(req.body as VerifyOtpInput);

    if (result.ok) {
      res.status(200).json({
        status: 'success',
        accessToken: result.accessToken,
        accessTokenExpiresIn: result.accessTokenExpiresIn,
        refreshToken: result.refreshToken,
        refreshTokenExpiresIn: result.refreshTokenExpiresIn,
        isNewUser: result.isNewUser,
      });
      return;
    }

    if (result.kind === 'rate_limited') {
      res.status(429).json({
        status: 'error',
        code: 'RATE_LIMITED',
        retryAfter: result.retryAfter,
      });
      return;
    }

    if (result.kind === 'server_error') {
      res.status(500).json({
        status: 'error',
        code: 'INTERNAL_ERROR',
        message: 'Could not complete verification. Please try again.',
      });
      return;
    }

    // Generic invalid/expired/locked — identical for every cause (no enumeration).
    res.status(401).json({
      status: 'error',
      code: 'INVALID_OTP',
      message: 'The code is invalid or has expired.',
    });
  })
);

/**
 * POST /auth/refresh — exchange a refresh token for a new access token + a
 * rotated refresh token (rotation with reuse detection).
 *
 * Enumeration-safe: missing/unknown/expired/reused/revoked tokens all return the
 * SAME generic 401. A missing token is intentionally a 401 (not a 400 schema
 * error) so the failure surface stays uniform.
 */
router.post(
  '/refresh',
  asyncHandler(async (req, res) => {
    const parsed = refreshSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(401).json(invalidRefreshBody());
      return;
    }

    const clientKey = req.ip ?? 'unknown';
    const result = await refreshSession(parsed.data.refreshToken, clientKey);

    if (result.ok) {
      res.status(200).json({
        status: 'success',
        accessToken: result.accessToken,
        accessTokenExpiresIn: result.accessTokenExpiresIn,
        refreshToken: result.refreshToken,
        refreshTokenExpiresIn: result.refreshTokenExpiresIn,
      });
      return;
    }

    if (result.kind === 'rate_limited') {
      res.status(429).json({
        status: 'error',
        code: 'RATE_LIMITED',
        retryAfter: result.retryAfter,
      });
      return;
    }

    if (result.kind === 'server_error') {
      res.status(500).json({
        status: 'error',
        code: 'INTERNAL_ERROR',
        message: 'Could not refresh the session. Please try again.',
      });
      return;
    }

    res.status(401).json(invalidRefreshBody());
  })
);

/** The single generic refresh-failure body, shared so every cause is identical. */
function invalidRefreshBody() {
  return {
    status: 'error',
    code: 'INVALID_REFRESH_TOKEN',
    message: 'Session expired. Please sign in again.',
  };
}

export default router;
