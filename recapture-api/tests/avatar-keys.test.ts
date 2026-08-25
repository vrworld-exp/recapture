// tests/avatar-keys.test.ts
//
// The avatar key space (src/utils/avatarKeys.ts) — PURE, no DB, no S3.
//
// parseAvatarKey is the containment guard for PUT /auth/me/avatar: the client
// supplies the key there, and everything that stops one user pointing their
// avatar at another user's object starts with this parser refusing to accept
// anything but the exact canonical scheme. That is why it is tested directly
// here as well as through the route (tests/auth-me-avatar.test.ts).
//
// ENV NOTE: vitest.config.ts sets NODE_ENV=development BEFORE the module graph
// loads, so s3EnvPrefix() is 'dev' throughout this file.
import { describe, it, expect } from 'vitest';

import {
  AVATAR_CONTENT_TYPES,
  AvatarKeyError,
  avatarExtensionFor,
  buildAvatarKey,
  buildAvatarPrefix,
  parseAvatarKey,
} from '@/utils/avatarKeys';
import { s3EnvPrefix } from '@/utils/s3Keys';

const USER = '507f1f77bcf86cd799439011';
const AVATAR = 'b3f1c2de-1111-4222-8333-444455556666';

describe('buildAvatarPrefix / buildAvatarKey', () => {
  it('builds the canonical prefix and key under the CONFIGURED env', () => {
    expect(buildAvatarPrefix(USER)).toBe(`dev/avatars/${USER}/`);
    expect(s3EnvPrefix()).toBe('dev'); // imported, never re-derived
    expect(buildAvatarKey(USER, AVATAR, 'jpg')).toBe(`dev/avatars/${USER}/${AVATAR}.jpg`);
    expect(buildAvatarKey(USER, AVATAR, 'png')).toBe(`dev/avatars/${USER}/${AVATAR}.png`);
  });

  it('round-trips through parseAvatarKey', () => {
    for (const ext of ['jpg', 'png'] as const) {
      const parsed = parseAvatarKey(buildAvatarKey(USER, AVATAR, ext));
      expect(parsed.ok).toBe(true);
      if (!parsed.ok) return;
      expect(parsed.value).toEqual({
        env: 'dev',
        userId: USER,
        avatarId: AVATAR,
        ext,
      });
    }
  });

  it('maps each accepted content type to its extension', () => {
    expect(AVATAR_CONTENT_TYPES).toEqual(['image/jpeg', 'image/png']);
    expect(avatarExtensionFor('image/jpeg')).toBe('jpg');
    expect(avatarExtensionFor('image/png')).toBe('png');
  });

  // The builders THROW rather than emitting a malformed key — a caller can
  // never end up holding one.
  const hostileSegments: { name: string; value: string }[] = [
    { name: 'a parent-directory traversal', value: '..' },
    { name: 'an embedded traversal', value: '../other' },
    { name: 'a leading dot', value: '.hidden' },
    { name: 'a forward slash', value: 'a/b' },
    { name: 'a backslash', value: 'a\\b' },
    { name: 'a space', value: 'a b' },
    { name: 'a newline', value: `a${String.fromCharCode(10)}b` },
    { name: 'a NUL', value: `a${String.fromCharCode(0)}b` },
    { name: 'a tab', value: `a${String.fromCharCode(9)}b` },
    { name: 'the empty string', value: '' },
  ];

  it.each(hostileSegments)('buildAvatarKey rejects $name as the userId', ({ value }) => {
    expect(() => buildAvatarKey(value, AVATAR, 'jpg')).toThrow(AvatarKeyError);
    expect(() => buildAvatarPrefix(value)).toThrow(AvatarKeyError);
  });

  it.each(hostileSegments)('buildAvatarKey rejects $name as the avatarId', ({ value }) => {
    expect(() => buildAvatarKey(USER, value, 'jpg')).toThrow(AvatarKeyError);
  });

  it('rejects an extension outside the closed set', () => {
    // Cast: the point is that a caller who defeats the type still cannot build
    // `…/{id}.svg`.
    expect(() => buildAvatarKey(USER, AVATAR, 'svg' as 'jpg')).toThrow(AvatarKeyError);
  });
});

describe('parseAvatarKey — the containment guard', () => {
  const rejections: { name: string; key: string }[] = [
    { name: 'the empty string', key: '' },
    { name: 'too few segments', key: `dev/avatars/${AVATAR}.jpg` },
    { name: 'too many segments', key: `dev/avatars/${USER}/nested/${AVATAR}.jpg` },
    { name: 'an unknown env prefix', key: `qa/avatars/${USER}/${AVATAR}.jpg` },
    { name: 'a missing avatars segment', key: `dev/users/${USER}/${AVATAR}.jpg` },
    { name: 'a traversal in the userId', key: `dev/avatars/../${AVATAR}.jpg` },
    { name: 'a traversal in the filename', key: `dev/avatars/${USER}/...jpg` },
    { name: 'a backslash in the userId', key: `dev/avatars/a\\b/${AVATAR}.jpg` },
    { name: 'whitespace in the userId', key: `dev/avatars/a b/${AVATAR}.jpg` },
    { name: 'a control char in the filename', key: `dev/avatars/${USER}/a${String.fromCharCode(0)}b.jpg` },
    { name: 'an empty userId', key: `dev/avatars//${AVATAR}.jpg` },
    { name: 'an empty filename', key: `dev/avatars/${USER}/` },
    { name: 'no extension', key: `dev/avatars/${USER}/${AVATAR}` },
    { name: 'a disallowed extension', key: `dev/avatars/${USER}/${AVATAR}.svg` },
    { name: 'an uppercase extension', key: `dev/avatars/${USER}/${AVATAR}.JPG` },
    { name: 'a leading-dot filename', key: `dev/avatars/${USER}/.jpg` },
    // A capture-job key must never parse as an avatar key (and vice versa) —
    // the two key spaces are deliberately separate parsers.
    { name: 'a capture image key', key: `dev/${USER}/proj/job/images/EYE/frame_0001.jpg` },
  ];

  it.each(rejections)('rejects $name with a reason, never a partial parse', ({ key }) => {
    const result = parseAvatarKey(key);
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(typeof result.reason).toBe('string');
    expect(result.reason.length).toBeGreaterThan(0);
    expect(result).not.toHaveProperty('value');
  });

  it('reports the env a key CLAIMS, so the route can reject a foreign one', () => {
    // A well-formed prod key parses — it is the ROUTE that refuses to commit it
    // because it is not the configured env. Keeping the check at the call site
    // is what makes that a distinguishable 422 rather than "malformed".
    const parsed = parseAvatarKey(`prod/avatars/${USER}/${AVATAR}.jpg`);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    expect(parsed.value.env).toBe('prod');
    expect(parsed.value.env).not.toBe(s3EnvPrefix());
  });

  it('a non-string key is a clean failure, not a throw', () => {
    const result = parseAvatarKey(undefined as unknown as string);
    expect(result.ok).toBe(false);
  });
});
