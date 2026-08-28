// src/utils/avatarKeys.ts
//
// CANONICAL S3 key naming for USER AVATARS — the single source of truth for
// building AND parsing every profile-picture key. Deliberately a SEPARATE file
// from utils/s3Keys.ts: that one is the capture-job key space, and its
// parseImageKey is a strict 6-segment `{env}/{projectSlug}_{projectId}/{jobId}/
// images/{LEVEL}/{filename}.jpg` parser. An avatar is not a capture image and
// must not be reachable through that parser (nor widen it). Note the capture
// key space dropped {userId} from its path; the AVATAR key space keeps it —
// these are separate schemes with separate parsers, on purpose.
//
// Key format (exact):
//   {env}/avatars/{userId}/{avatarId}.{jpg|png}
//
//   • {env} is CONFIG-DRIVEN via s3EnvPrefix() — IMPORTED from s3Keys.ts, never
//     re-derived here, so a staging deploy can never emit prod/... keys and the
//     NODE_ENV mapping exists in exactly one place.
//   • {avatarId} is a fresh randomUUID() per upload (the route mints it), so the
//     key CHANGES on every change. That buys cache-busting for free — no
//     Image.network cache, no CDN, and no client ever shows the previous
//     picture — and makes the commit step a clean pointer flip.
//
// Every interpolated segment is validated before composition with the SAME
// discipline as s3Keys.ts (no `/` or `\`, no whitespace/control chars, no
// leading dot — which also kills ".." — never empty), so a hostile value can
// neither traverse the hierarchy nor inject extra key levels. Builders THROW;
// the parser returns a discriminated failure, never a partial parse.
//
// SECURITY: parseAvatarKey is the containment guard for PUT /auth/me/avatar —
// the client supplies the key there, so the commit re-derives ownership from
// the token and compares it against the parsed userId. It is the security
// boundary of the whole avatar feature; tests/avatar-keys.test.ts covers it
// directly.
import { s3EnvPrefix, S3_ENV_PREFIXES, type S3EnvPrefix } from '@/utils/s3Keys';

/** The literal second segment that namespaces every avatar key. */
export const AVATAR_SEGMENT = 'avatars';

/** The image extensions an avatar key may carry — the set is closed. */
export const AVATAR_EXTENSIONS = ['jpg', 'png'] as const;
export type AvatarExtension = (typeof AVATAR_EXTENSIONS)[number];

/** The upload content types we accept — a closed set (it is baked into the
 * presigned signature, so it also fixes what can ever be stored). */
export const AVATAR_CONTENT_TYPES = ['image/jpeg', 'image/png'] as const;
export type AvatarContentType = (typeof AVATAR_CONTENT_TYPES)[number];

/** Content type → the extension its key carries. */
const EXT_BY_CONTENT_TYPE: Readonly<Record<AvatarContentType, AvatarExtension>> = {
  'image/jpeg': 'jpg',
  'image/png': 'png',
};

/** The key extension for an accepted upload content type. */
export function avatarExtensionFor(contentType: AvatarContentType): AvatarExtension {
  return EXT_BY_CONTENT_TYPE[contentType];
}

/** Thrown by the builders on any invalid segment — callers never receive a
 * malformed key. */
export class AvatarKeyError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'AvatarKeyError';
  }
}

/**
 * Allowed shape of ONE key segment — identical to s3Keys.ts's SEGMENT_RE (kept
 * as its own const rather than exported/shared, so neither key space can be
 * loosened by a change made for the other): starts alphanumeric (a leading dot,
 * and therefore "..", is rejected), then alphanumerics, dot, underscore,
 * hyphen. Excludes `/` and `\` (hierarchy injection), whitespace, and control
 * characters.
 */
const SEGMENT_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

function requireSegment(name: string, value: string): string {
  if (typeof value !== 'string' || value.length === 0) {
    throw new AvatarKeyError(`${name} must be a non-empty string`);
  }
  if (!SEGMENT_RE.test(value)) {
    throw new AvatarKeyError(
      `${name} contains characters not allowed in an S3 key segment ` +
        `(allowed: alphanumeric start, then [A-Za-z0-9._-]): ${JSON.stringify(value)}`
    );
  }
  return value;
}

/**
 * Every object belonging to one user's avatar history:
 * `{env}/avatars/{userId}/`.
 *
 * This is the CLEANUP boundary — commit and delete both wipe the whole prefix
 * rather than a single known key, which self-heals the orphans left behind by
 * presigned uploads the user abandoned before committing.
 */
export function buildAvatarPrefix(userId: string): string {
  return `${s3EnvPrefix()}/${AVATAR_SEGMENT}/${requireSegment('userId', userId)}/`;
}

/**
 * Full avatar key: `{env}/avatars/{userId}/{avatarId}.{jpg|png}`.
 *
 * Round-trip guarantee: `parseAvatarKey(buildAvatarKey(u, a, e))` returns
 * exactly `{ env: s3EnvPrefix(), userId: u, avatarId: a, ext: e }`.
 */
export function buildAvatarKey(
  userId: string,
  avatarId: string,
  ext: AvatarExtension
): string {
  if (!(AVATAR_EXTENSIONS as readonly string[]).includes(ext)) {
    throw new AvatarKeyError(
      `ext must be one of ${AVATAR_EXTENSIONS.join('/')}: ${JSON.stringify(ext)}`
    );
  }
  return `${buildAvatarPrefix(userId)}${requireSegment('avatarId', avatarId)}.${ext}`;
}

/** All segments of one canonical avatar key, exactly as they appear in it. */
export interface ParsedAvatarKey {
  env: S3EnvPrefix;
  userId: string;
  avatarId: string;
  ext: AvatarExtension;
}

export type ParseAvatarKeyResult =
  | { ok: true; value: ParsedAvatarKey }
  | { ok: false; reason: string };

/**
 * STRICT parser for canonical avatar keys. Accepts ONLY the exact scheme — four
 * segments, a known env prefix, a literal `avatars` second segment, valid id
 * segments, and a single lowercase `.jpg`/`.png` — and returns a discriminated
 * failure (never a partial parse) otherwise.
 *
 * Note this does NOT check the env prefix against the CONFIGURED one: it
 * reports which env the key claims, and the caller decides. The commit route
 * rejects a mismatch (a staging client must never commit a prod key) — keeping
 * that check at the call site is what makes the mismatch a distinguishable
 * 422 rather than an indistinguishable "malformed".
 */
export function parseAvatarKey(key: string): ParseAvatarKeyResult {
  const fail = (reason: string): ParseAvatarKeyResult => ({ ok: false, reason });
  if (typeof key !== 'string' || key.length === 0) {
    return fail('key must be a non-empty string');
  }

  const parts = key.split('/');
  if (parts.length !== 4) {
    return fail('key must have exactly 4 segments: {env}/avatars/{userId}/{avatarId}.{jpg|png}');
  }
  const [envSeg, avatarsSeg, userId, fileSeg] = parts as [string, string, string, string];

  if (!(S3_ENV_PREFIXES as readonly string[]).includes(envSeg)) {
    return fail(
      `unknown env prefix ${JSON.stringify(envSeg)} (expected ${S3_ENV_PREFIXES.join('/')})`
    );
  }
  if (avatarsSeg !== AVATAR_SEGMENT) {
    return fail(
      `expected literal ${JSON.stringify(AVATAR_SEGMENT)} as the 2nd segment, got ${JSON.stringify(avatarsSeg)}`
    );
  }
  if (!SEGMENT_RE.test(userId)) {
    return fail(`invalid userId segment: ${JSON.stringify(userId)}`);
  }

  const dot = fileSeg.lastIndexOf('.');
  if (dot <= 0) {
    return fail(`filename must be {avatarId}.{jpg|png}: ${JSON.stringify(fileSeg)}`);
  }
  const avatarId = fileSeg.slice(0, dot);
  const ext = fileSeg.slice(dot + 1);
  if (!(AVATAR_EXTENSIONS as readonly string[]).includes(ext)) {
    return fail(
      `extension must be exactly one of ${AVATAR_EXTENSIONS.join('/')} (lowercase): ${JSON.stringify(fileSeg)}`
    );
  }
  if (!SEGMENT_RE.test(avatarId)) {
    return fail(`invalid avatarId segment: ${JSON.stringify(fileSeg)}`);
  }

  return {
    ok: true,
    value: {
      env: envSeg as S3EnvPrefix,
      userId,
      avatarId,
      ext: ext as AvatarExtension,
    },
  };
}
