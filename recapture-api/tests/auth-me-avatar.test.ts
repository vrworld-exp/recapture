// tests/auth-me-avatar.test.ts
//
// The profile-picture surface: POST /auth/me/avatar/upload-url (presign),
// PUT /auth/me/avatar (commit), DELETE /auth/me/avatar, and the web-fallback
// GET /auth/me/avatar/bytes.
//
// THE load-bearing case is "committing another user's key → 403, and the DB is
// unchanged". The client supplies the key at commit time, so without that check
// any signed-in user could point their avatar at another user's object — and the
// account snapshot would then hand them a presigned GET of it. Everything else
// in this file is ordinary contract coverage; that one is the security boundary.
//
// Second guardrail carried forward from auth-me-profile.test.ts: no response
// body may contain a raw phone or email substring.
//
// Hermetic: ephemeral in-memory MongoDB, and the S3 seam is SCRIPTED via
// vi.spyOn(s3Client, 'send') the way the admin suites do — CI never calls AWS.
// Presigning is local SigV4 and needs no scripting; only Head/Get/List/Delete do.
//
// ENV NOTE: vitest.config.ts injects env BEFORE the module graph loads —
// config/env.ts validates and freezes at import, so a per-test process.env write
// would be too late. NODE_ENV=development there, so every key prefix is 'dev'.
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';
import {
  DeleteObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
  ListObjectsV2Command,
} from '@aws-sdk/client-s3';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { s3Client } from '@/config/s3';
import { User } from '@/models/User';
import { RateWindow } from '@/models/RateWindow';
import { buildAvatarKey, buildAvatarPrefix } from '@/utils/avatarKeys';

const app = createApp();
let mongod: MongoMemoryServer;

// Seeded identifiers — asserted ABSENT from every response body.
const SEED_PHONE = '+919876543210';
const SEED_EMAIL = 'ashish@example.com';

const AVATAR_ID = 'b3f1c2de-1111-4222-8333-444455556666';

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

afterEach(async () => {
  await User.deleteMany({});
  await RateWindow.deleteMany({});
  vi.restoreAllMocks();
});

async function seedUser(
  fields: Partial<{ phone: string; email: string; avatarKey: string }> = {}
): Promise<{ id: string; token: string }> {
  const user = await User.create({
    authProvider: 'custom',
    authUid: `uid-${Math.random().toString(36).slice(2)}`,
    phoneVerified: Boolean(fields.phone),
    emailVerified: Boolean(fields.email),
    ...fields,
  });
  const id = user.id as string;
  const token = jwt.sign({ userId: id, authUid: user.authUid }, env.JWT_SECRET, {
    expiresIn: '15m',
  });
  return { id, token };
}

/**
 * Scripts the S3 seam. [objects] is the fake bucket: key → byte size. HEAD/GET
 * answer from it, LIST filters it by prefix, DELETE removes from it — so a test
 * can assert on the resulting bucket state rather than on call counts alone.
 */
function scriptS3(objects: Map<string, number>) {
  const deleted: string[] = [];
  const spy = vi.spyOn(s3Client, 'send').mockImplementation((command: unknown) => {
    if (command instanceof HeadObjectCommand) {
      const key = command.input.Key as string;
      if (!objects.has(key)) return Promise.reject(notFound());
      return Promise.resolve({
        ContentLength: objects.get(key),
        ContentType: 'image/jpeg',
      }) as never;
    }
    if (command instanceof GetObjectCommand) {
      const key = command.input.Key as string;
      if (!objects.has(key)) return Promise.reject(notFound());
      return Promise.resolve({
        ContentType: 'image/jpeg',
        Body: { transformToByteArray: async () => new Uint8Array([0xff, 0xd8, 0xff, 0xe0]) },
      }) as never;
    }
    if (command instanceof ListObjectsV2Command) {
      const prefix = (command.input.Prefix as string) ?? '';
      return Promise.resolve({
        Contents: [...objects.entries()]
          .filter(([key]) => key.startsWith(prefix))
          .map(([Key, Size]) => ({ Key, Size })),
        IsTruncated: false,
      }) as never;
    }
    if (command instanceof DeleteObjectCommand) {
      const key = command.input.Key as string;
      deleted.push(key);
      objects.delete(key);
      return Promise.resolve({}) as never;
    }
    return Promise.reject(new Error(`unscripted S3 command: ${String(command)}`));
  });
  return { spy, deleted, objects };
}

function notFound(): Error {
  const err = new Error('NotFound');
  err.name = 'NotFound';
  return err;
}

describe('POST /auth/me/avatar/upload-url', () => {
  it('returns a key under {env}/avatars/{callerId}/ plus a presigned PUT url', async () => {
    const { id, token } = await seedUser({ phone: SEED_PHONE });

    const res = await request(app)
      .post('/auth/me/avatar/upload-url')
      .set('Authorization', `Bearer ${token}`)
      .send({ contentType: 'image/jpeg', contentLength: 120_000 });

    expect(res.status).toBe(200);
    expect(res.body.status).toBe('success');
    expect(res.body.key).toMatch(new RegExp(`^dev/avatars/${id}/[0-9a-f-]+\\.jpg$`));
    expect(res.body.key.startsWith(buildAvatarPrefix(id))).toBe(true);
    expect(res.body.url).toContain('X-Amz-Signature');
    expect(Date.parse(res.body.expiresAt)).toBeGreaterThan(Date.now());

    // Stateless: no DB write happens until the commit.
    expect((await User.findById(id).exec())?.avatarKey).toBeUndefined();
  });

  it('a png request yields a .png key', async () => {
    const { token } = await seedUser({ phone: SEED_PHONE });

    const res = await request(app)
      .post('/auth/me/avatar/upload-url')
      .set('Authorization', `Bearer ${token}`)
      .send({ contentType: 'image/png', contentLength: 5000 });

    expect(res.status).toBe(200);
    expect(res.body.key.endsWith('.png')).toBe(true);
  });

  it('mints a DIFFERENT key every time (cache-busting by construction)', async () => {
    const { token } = await seedUser({ phone: SEED_PHONE });
    const body = { contentType: 'image/jpeg', contentLength: 5000 };

    const first = await request(app)
      .post('/auth/me/avatar/upload-url')
      .set('Authorization', `Bearer ${token}`)
      .send(body);
    const second = await request(app)
      .post('/auth/me/avatar/upload-url')
      .set('Authorization', `Bearer ${token}`)
      .send(body);

    expect(first.body.key).not.toBe(second.body.key);
  });

  const badBodies: { name: string; body: Record<string, unknown> }[] = [
    { name: 'an unsupported content type', body: { contentType: 'image/gif', contentLength: 5000 } },
    { name: 'an svg content type', body: { contentType: 'image/svg+xml', contentLength: 5000 } },
    { name: 'a zero contentLength', body: { contentType: 'image/jpeg', contentLength: 0 } },
    { name: 'a negative contentLength', body: { contentType: 'image/jpeg', contentLength: -1 } },
    {
      name: 'a contentLength over the cap',
      body: { contentType: 'image/jpeg', contentLength: 2_097_153 },
    },
    { name: 'a missing contentType', body: { contentLength: 5000 } },
    // .strict() — this route mints a write credential and must never grow an
    // extra caller-supplied field.
    {
      name: 'an unknown extra key',
      body: { contentType: 'image/jpeg', contentLength: 5000, userId: 'someone-else' },
    },
  ];

  it.each(badBodies)('rejects $name with the standard envelope', async ({ body }) => {
    const { token } = await seedUser({ phone: SEED_PHONE });

    const res = await request(app)
      .post('/auth/me/avatar/upload-url')
      .set('Authorization', `Bearer ${token}`)
      .send(body);

    expect(res.status).toBe(400);
    expect(res.body.status).toBe('error');
    expect(res.body.code).toBe('INVALID_REQUEST');
  });

  it('accepts exactly AVATAR_MAX_BYTES (the boundary is inclusive)', async () => {
    const { token } = await seedUser({ phone: SEED_PHONE });

    const res = await request(app)
      .post('/auth/me/avatar/upload-url')
      .set('Authorization', `Bearer ${token}`)
      .send({ contentType: 'image/jpeg', contentLength: env.AVATAR_MAX_BYTES });

    expect(res.status).toBe(200);
  });

  it('rate-limits per user with a retryAfter', async () => {
    const { token } = await seedUser({ phone: SEED_PHONE });
    const body = { contentType: 'image/jpeg', contentLength: 5000 };

    for (let i = 0; i < env.AVATAR_UPLOAD_MAX_PER_WINDOW; i++) {
      const ok = await request(app)
        .post('/auth/me/avatar/upload-url')
        .set('Authorization', `Bearer ${token}`)
        .send(body);
      expect(ok.status).toBe(200);
    }

    const limited = await request(app)
      .post('/auth/me/avatar/upload-url')
      .set('Authorization', `Bearer ${token}`)
      .send(body);

    expect(limited.status).toBe(429);
    expect(limited.body.code).toBe('RATE_LIMITED');
    expect(limited.body.retryAfter).toBeGreaterThan(0);
  });
});

describe('PUT /auth/me/avatar — the commit', () => {
  it('THE SECURITY BOUNDARY: committing another user’s key → 403, DB unchanged', async () => {
    const victim = await seedUser({ phone: SEED_PHONE });
    const attacker = await seedUser({ email: SEED_EMAIL });

    const victimKey = buildAvatarKey(victim.id, AVATAR_ID, 'jpg');
    // The object EXISTS — the rejection must come from ownership, not absence.
    const { spy } = scriptS3(new Map([[victimKey, 40_000]]));

    const res = await request(app)
      .put('/auth/me/avatar')
      .set('Authorization', `Bearer ${attacker.token}`)
      .send({ key: victimKey });

    expect(res.status).toBe(403);
    expect(res.body.code).toBe('FORBIDDEN');

    // Nothing was written for EITHER user…
    expect((await User.findById(attacker.id).exec())?.avatarKey).toBeUndefined();
    expect((await User.findById(victim.id).exec())?.avatarKey).toBeUndefined();
    // …and S3 was never touched at all: the guard runs before any object access,
    // so this cannot even be used as an existence oracle.
    expect(spy).not.toHaveBeenCalled();
  });

  it('a well-formed key with no object in S3 → 409', async () => {
    const { id, token } = await seedUser({ phone: SEED_PHONE });
    const key = buildAvatarKey(id, AVATAR_ID, 'jpg');
    scriptS3(new Map()); // empty bucket

    const res = await request(app)
      .put('/auth/me/avatar')
      .set('Authorization', `Bearer ${token}`)
      .send({ key });

    expect(res.status).toBe(409);
    expect(res.body.code).toBe('OBJECT_NOT_FOUND');
    expect(res.body.message).toBe('Upload the image before saving it.');
    expect((await User.findById(id).exec())?.avatarKey).toBeUndefined();
  });

  it('an oversized object → 413 AND the object is deleted', async () => {
    const { id, token } = await seedUser({ phone: SEED_PHONE });
    const key = buildAvatarKey(id, AVATAR_ID, 'jpg');
    const { deleted, objects } = scriptS3(new Map([[key, env.AVATAR_MAX_BYTES + 1]]));

    const res = await request(app)
      .put('/auth/me/avatar')
      .set('Authorization', `Bearer ${token}`)
      .send({ key });

    expect(res.status).toBe(413);
    expect(res.body.code).toBe('PAYLOAD_TOO_LARGE');
    // Presigning can't cap size, so this is the only place the ceiling is real —
    // and refusing without deleting would leave an uncollectable object.
    expect(deleted).toEqual([key]);
    expect(objects.has(key)).toBe(false);
    expect((await User.findById(id).exec())?.avatarKey).toBeUndefined();
  });

  it('accepts an object of exactly AVATAR_MAX_BYTES', async () => {
    const { id, token } = await seedUser({ phone: SEED_PHONE });
    const key = buildAvatarKey(id, AVATAR_ID, 'jpg');
    scriptS3(new Map([[key, env.AVATAR_MAX_BYTES]]));

    const res = await request(app)
      .put('/auth/me/avatar')
      .set('Authorization', `Bearer ${token}`)
      .send({ key });

    expect(res.status).toBe(200);
  });

  it('a successful commit persists the KEY and ships only a presigned URL', async () => {
    const { id, token } = await seedUser({ phone: SEED_PHONE });
    const key = buildAvatarKey(id, AVATAR_ID, 'jpg');
    scriptS3(new Map([[key, 40_000]]));

    const res = await request(app)
      .put('/auth/me/avatar')
      .set('Authorization', `Bearer ${token}`)
      .send({ key });

    expect(res.status).toBe(200);
    expect(res.body.status).toBe('success');

    // Persisted as the KEY, never a URL (a presigned URL is a credential that
    // dies within the hour — it must not sit in a document).
    const after = await User.findById(id).exec();
    expect(after?.avatarKey).toBe(key);
    expect(after?.avatarKey).not.toMatch(/^https?:/);
    expect(after?.avatarUpdatedAt).toBeInstanceOf(Date);

    // The payload carries the URL and NOT the key.
    expect(typeof res.body.user.avatarUrl).toBe('string');
    expect(res.body.user.avatarUrl).toContain('X-Amz-Signature');
    expect(Date.parse(res.body.user.avatarUrlExpiresAt)).toBeGreaterThan(Date.now());
    expect(res.body.user).not.toHaveProperty('avatarKey');
    // The key appears ONLY as the path inside the presigned URL (unavoidable —
    // that is what the URL points at). No FIELD of the snapshot carries it.
    expect(Object.values(res.body.user)).not.toContain(key);

    // Same snapshot shape as GET /auth/me — one client parser across all four
    // snapshot-returning endpoints.
    const get = await request(app).get('/auth/me').set('Authorization', `Bearer ${token}`);
    expect(Object.keys(get.body.user).sort()).toEqual(Object.keys(res.body.user).sort());
    expect(typeof get.body.user.avatarUrl).toBe('string');
  });

  it('a second commit deletes the previous object and any abandoned uploads', async () => {
    const { id, token } = await seedUser({ phone: SEED_PHONE });
    const first = buildAvatarKey(id, 'aaaaaaaa-1111-4222-8333-444455556666', 'jpg');
    const second = buildAvatarKey(id, 'bbbbbbbb-1111-4222-8333-444455556666', 'jpg');
    // An orphan from a presigned upload the user abandoned before committing —
    // the prefix sweep self-heals it.
    const orphan = buildAvatarKey(id, 'cccccccc-1111-4222-8333-444455556666', 'png');

    // Only the first upload exists at first-commit time (the later ones haven't
    // been PUT yet) — anything else would test a bucket state that can't occur.
    const { deleted, objects } = scriptS3(new Map([[first, 40_000]]));

    await request(app)
      .put('/auth/me/avatar')
      .set('Authorization', `Bearer ${token}`)
      .send({ key: first });

    // Now the user picks again: a second slot is uploaded, and an earlier slot
    // they abandoned before committing is still sitting under their prefix.
    objects.set(second, 41_000);
    objects.set(orphan, 42_000);

    const res = await request(app)
      .put('/auth/me/avatar')
      .set('Authorization', `Bearer ${token}`)
      .send({ key: second });

    expect(res.status).toBe(200);
    expect((await User.findById(id).exec())?.avatarKey).toBe(second);
    expect(deleted).toContain(first);
    expect(deleted).toContain(orphan);
    // Exactly the committed one survives.
    expect([...objects.keys()]).toEqual([second]);
  });

  it('never deletes ANOTHER user’s objects while sweeping', async () => {
    const mine = await seedUser({ phone: SEED_PHONE });
    const theirs = await seedUser({ email: SEED_EMAIL });
    const myKey = buildAvatarKey(mine.id, AVATAR_ID, 'jpg');
    const theirKey = buildAvatarKey(theirs.id, AVATAR_ID, 'jpg');

    const { deleted } = scriptS3(
      new Map([
        [myKey, 40_000],
        [theirKey, 40_000],
      ])
    );

    await request(app)
      .put('/auth/me/avatar')
      .set('Authorization', `Bearer ${mine.token}`)
      .send({ key: myKey });

    expect(deleted).not.toContain(theirKey);
  });

  it('a failed cleanup does NOT fail the save (pointer already flipped)', async () => {
    const { id, token } = await seedUser({ phone: SEED_PHONE });
    const key = buildAvatarKey(id, AVATAR_ID, 'jpg');

    vi.spyOn(s3Client, 'send').mockImplementation((command: unknown) => {
      if (command instanceof HeadObjectCommand) {
        return Promise.resolve({ ContentLength: 40_000, ContentType: 'image/jpeg' }) as never;
      }
      // Every cleanup call blows up.
      return Promise.reject(new Error('S3 is having a day'));
    });

    const res = await request(app)
      .put('/auth/me/avatar')
      .set('Authorization', `Bearer ${token}`)
      .send({ key });

    expect(res.status).toBe(200);
    expect((await User.findById(id).exec())?.avatarKey).toBe(key);
  });

  const invalidKeys: { name: string; key: (id: string) => string }[] = [
    { name: 'a traversal', key: (id) => `dev/avatars/${id}/../../etc/passwd` },
    { name: 'a capture image key', key: (id) => `dev/${id}/proj/job/images/EYE/frame_0001.jpg` },
    { name: 'a disallowed extension', key: (id) => `dev/avatars/${id}/${AVATAR_ID}.svg` },
    { name: 'a bare filename', key: () => 'avatar.jpg' },
    { name: 'an absolute-looking key', key: (id) => `/dev/avatars/${id}/${AVATAR_ID}.jpg` },
  ];

  it.each(invalidKeys)('$name → 422 INVALID_KEY', async ({ key }) => {
    const { id, token } = await seedUser({ phone: SEED_PHONE });
    const { spy } = scriptS3(new Map());

    const res = await request(app)
      .put('/auth/me/avatar')
      .set('Authorization', `Bearer ${token}`)
      .send({ key: key(id) });

    expect(res.status).toBe(422);
    expect(res.body.code).toBe('INVALID_KEY');
    expect(spy).not.toHaveBeenCalled();
    expect((await User.findById(id).exec())?.avatarKey).toBeUndefined();
  });

  it('a key from a DIFFERENT environment → 422 (staging must not commit prod)', async () => {
    const { id, token } = await seedUser({ phone: SEED_PHONE });
    const { spy } = scriptS3(new Map());

    const res = await request(app)
      .put('/auth/me/avatar')
      .set('Authorization', `Bearer ${token}`)
      .send({ key: `prod/avatars/${id}/${AVATAR_ID}.jpg` });

    expect(res.status).toBe(422);
    expect(res.body.code).toBe('INVALID_KEY');
    expect(spy).not.toHaveBeenCalled();
  });

  it('rejects an extra body key (.strict())', async () => {
    const { id, token } = await seedUser({ phone: SEED_PHONE });

    const res = await request(app)
      .put('/auth/me/avatar')
      .set('Authorization', `Bearer ${token}`)
      .send({ key: buildAvatarKey(id, AVATAR_ID, 'jpg'), userId: 'someone-else' });

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
  });
});

describe('DELETE /auth/me/avatar', () => {
  it('clears the pointer, removes the objects, and is IDEMPOTENT', async () => {
    const { id, token } = await seedUser({ phone: SEED_PHONE });
    const key = buildAvatarKey(id, AVATAR_ID, 'jpg');
    await User.findByIdAndUpdate(id, {
      $set: { avatarKey: key, avatarUpdatedAt: new Date() },
    }).exec();
    const { deleted, objects } = scriptS3(new Map([[key, 40_000]]));

    const first = await request(app)
      .delete('/auth/me/avatar')
      .set('Authorization', `Bearer ${token}`);

    expect(first.status).toBe(200);
    expect(first.body.user.avatarUrl).toBeNull();
    expect(first.body.user.avatarUrlExpiresAt).toBeNull();
    expect(deleted).toEqual([key]);
    expect(objects.size).toBe(0);

    const after = await User.findById(id).exec();
    expect(after?.avatarKey).toBeUndefined();
    expect(after?.avatarUpdatedAt).toBeUndefined();

    // Second call: a plain 200 with the snapshot, never a 404.
    const second = await request(app)
      .delete('/auth/me/avatar')
      .set('Authorization', `Bearer ${token}`);
    expect(second.status).toBe(200);
    expect(second.body.user.avatarUrl).toBeNull();
  });

  it('a user who never had a picture gets a 200, not a 404', async () => {
    const { token } = await seedUser({ phone: SEED_PHONE });
    scriptS3(new Map());

    const res = await request(app)
      .delete('/auth/me/avatar')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(res.body.user.avatarUrl).toBeNull();
  });
});

describe('GET /auth/me/avatar/bytes — the web fallback', () => {
  it('streams the caller’s own avatar with a private cache header', async () => {
    const { id, token } = await seedUser({ phone: SEED_PHONE });
    const key = buildAvatarKey(id, AVATAR_ID, 'jpg');
    await User.findByIdAndUpdate(id, { $set: { avatarKey: key } }).exec();
    scriptS3(new Map([[key, 40_000]]));

    const res = await request(app)
      .get('/auth/me/avatar/bytes')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toContain('image/jpeg');
    expect(res.headers['cache-control']).toBe('private, max-age=300');
    expect(res.body.length).toBeGreaterThan(0);
  });

  it('404s when the account has no picture (no caller-supplied key exists)', async () => {
    const { token } = await seedUser({ phone: SEED_PHONE });

    const res = await request(app)
      .get('/auth/me/avatar/bytes')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(404);
    expect(res.body.code).toBe('NOT_FOUND');
  });

  it('404s when the pointer outlived the object', async () => {
    const { id, token } = await seedUser({ phone: SEED_PHONE });
    await User.findByIdAndUpdate(id, {
      $set: { avatarKey: buildAvatarKey(id, AVATAR_ID, 'jpg') },
    }).exec();
    scriptS3(new Map()); // the object is gone

    const res = await request(app)
      .get('/auth/me/avatar/bytes')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(404);
  });
});

describe('auth + PII guardrails', () => {
  const routes: { name: string; call: () => request.Test }[] = [
    {
      name: 'POST /auth/me/avatar/upload-url',
      call: () =>
        request(app)
          .post('/auth/me/avatar/upload-url')
          .send({ contentType: 'image/jpeg', contentLength: 5000 }),
    },
    {
      name: 'PUT /auth/me/avatar',
      call: () => request(app).put('/auth/me/avatar').send({ key: 'dev/avatars/x/y.jpg' }),
    },
    { name: 'DELETE /auth/me/avatar', call: () => request(app).delete('/auth/me/avatar') },
    {
      name: 'GET /auth/me/avatar/bytes',
      call: () => request(app).get('/auth/me/avatar/bytes'),
    },
  ];

  it.each(routes)('$name without a token → 401', async ({ call }) => {
    const res = await call();
    expect(res.status).toBe(401);
  });

  it('THE PII GUARDRAIL: no avatar response body carries a raw phone or email', async () => {
    // One user carrying BOTH identifiers, so a leak of either is caught.
    const { id, token } = await seedUser({ phone: SEED_PHONE, email: SEED_EMAIL });
    const key = buildAvatarKey(id, AVATAR_ID, 'jpg');
    scriptS3(new Map([[key, 40_000]]));

    const bodies = [
      (
        await request(app)
          .post('/auth/me/avatar/upload-url')
          .set('Authorization', `Bearer ${token}`)
          .send({ contentType: 'image/jpeg', contentLength: 5000 })
      ).body,
      (
        await request(app)
          .put('/auth/me/avatar')
          .set('Authorization', `Bearer ${token}`)
          .send({ key })
      ).body,
      (await request(app).delete('/auth/me/avatar').set('Authorization', `Bearer ${token}`))
        .body,
    ];

    for (const body of bodies) {
      const json = JSON.stringify(body);
      expect(json).not.toContain(SEED_PHONE);
      expect(json).not.toContain(SEED_EMAIL);
      // Partial leaks too — the local part of the email and the un-masked middle
      // of the phone must not survive either.
      expect(json).not.toContain('ashish@');
      expect(json).not.toContain('9876543');
      expect(body).not.toHaveProperty('user.phone');
      expect(body).not.toHaveProperty('user.email');
    }
  });
});
