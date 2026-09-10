// tests/admin-project-owner.test.ts
//
// "Created by" on the Live-projects list: the ADMIN-only owner summary on
// GET /admin/projects, and the two routes behind the detail sheet
// (GET /admin/users/:id and its /avatar/bytes).
//
// The point of most of these assertions is the PII BOUNDARY, not the happy
// path. `/admin/users/:id` is the one route in this API that answers with an
// unmasked phone/email, so the tests that matter are the ones proving nobody
// below ADMIN can reach it and that the LIST never carries an identifier at
// all — a page of twenty projects must not become twenty phone numbers.
//
// Hermetic: in-memory MongoDB; the avatar object read is scripted on the
// shared S3 client.
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { s3Client } from '@/config/s3';
import { User, type UserRole } from '@/models/User';
import { Project } from '@/models/Project';
import { RateWindow } from '@/models/RateWindow';
import { buildAvatarKey } from '@/utils/avatarKeys';

const app = createApp();
let mongod: MongoMemoryServer;

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
  await Project.deleteMany({});
  await RateWindow.deleteMany({});
  vi.restoreAllMocks();
});

async function makeUser(
  role: UserRole | undefined,
  extras: Record<string, unknown> = {}
): Promise<{ id: string; auth: { Authorization: string } }> {
  const user = await User.create({
    authProvider: 'custom',
    authUid: `test|${new Types.ObjectId().toHexString()}`,
    ...(role ? { role } : {}),
    ...extras,
  });
  const id = user.id as string;
  const token = jwt.sign({ userId: id, authUid: user.authUid }, env.JWT_SECRET, {
    expiresIn: '15m',
  });
  return { id, auth: { Authorization: `Bearer ${token}` } };
}

async function makeLiveProject(ownerId: string) {
  return Project.create({
    userId: new Types.ObjectId(ownerId),
    name: `Owner-label-${new Types.ObjectId().toHexString().slice(-6)}`,
    objectSize: 'MEDIUM',
    mode: 'GUIDED',
    status: 'COMPLETED',
  });
}

/** One PNG-ish blob served for any GetObject. */
function mockAvatarGet(bytes = Buffer.from([0x89, 0x50, 0x4e, 0x47])) {
  return vi.spyOn(s3Client, 'send').mockImplementation((async (cmd: {
    constructor: { name: string };
  }) => {
    if (cmd.constructor.name !== 'GetObjectCommand') {
      throw new Error(`unexpected S3 command: ${cmd.constructor.name}`);
    }
    return {
      Body: { transformToByteArray: async () => new Uint8Array(bytes) },
      ContentType: 'image/png',
    };
  }) as never);
}

// ── The list label ───────────────────────────────────────────────────────────

describe('GET /admin/projects — the ADMIN-only owner summary', () => {
  it('gives an ADMIN the owner name + hasAvatar, and NO identifier of any kind', async () => {
    const owner = await makeUser('USER', {
      displayName: 'Ravi Sharma',
      phone: '+919876543210',
      email: 'ravi@example.com',
    });
    await makeLiveProject(owner.id);
    const { auth } = await makeUser('ADMIN');

    const res = await request(app).get('/admin/projects').set(auth);

    expect(res.status).toBe(200);
    expect(res.body.items).toHaveLength(1);
    expect(res.body.items[0].owner).toEqual({
      id: owner.id,
      displayName: 'Ravi Sharma',
      hasAvatar: false,
    });
    // The whole reason the summary is a separate shape from the detail: the
    // list must be safe to fetch a page of.
    const body = JSON.stringify(res.body);
    expect(body).not.toContain('9876543210');
    expect(body).not.toContain('ravi@example.com');
  });

  it('omits the owner entirely for a MODEL_ARTIST — the opaque ownerId is all they get', async () => {
    const owner = await makeUser('USER', { displayName: 'Ravi Sharma' });
    await makeLiveProject(owner.id);
    const { auth } = await makeUser('MODEL_ARTIST');

    const res = await request(app).get('/admin/projects').set(auth);

    expect(res.status).toBe(200);
    expect(res.body.items[0].ownerId).toBe(owner.id);
    expect(res.body.items[0].owner).toBeUndefined();
    expect(JSON.stringify(res.body)).not.toContain('Ravi Sharma');
  });

  it('reports hasAvatar for an owner who has a picture', async () => {
    const owner = await makeUser('USER', {
      displayName: 'Ravi Sharma',
      avatarKey: buildAvatarKey(new Types.ObjectId().toHexString(), 'abc', 'jpg'),
    });
    await makeLiveProject(owner.id);
    const { auth } = await makeUser('ADMIN');

    const res = await request(app).get('/admin/projects').set(auth);

    expect(res.body.items[0].owner.hasAvatar).toBe(true);
  });

  it('leaves the owner absent (not null) when the account is gone', async () => {
    const orphanId = new Types.ObjectId().toHexString();
    await makeLiveProject(orphanId);
    const { auth } = await makeUser('ADMIN');

    const res = await request(app).get('/admin/projects').set(auth);

    expect(res.body.items[0].ownerId).toBe(orphanId);
    expect(res.body.items[0]).not.toHaveProperty('owner');
  });

  it('de-duplicates: many projects by one owner still resolve to one summary', async () => {
    const owner = await makeUser('USER', { displayName: 'Ravi Sharma' });
    await makeLiveProject(owner.id);
    await makeLiveProject(owner.id);
    await makeLiveProject(owner.id);
    const { auth } = await makeUser('ADMIN');

    const res = await request(app).get('/admin/projects').set(auth);

    expect(res.body.items).toHaveLength(3);
    for (const item of res.body.items) {
      expect(item.owner.displayName).toBe('Ravi Sharma');
    }
  });
});

// ── The detail sheet ─────────────────────────────────────────────────────────

describe('GET /admin/users/:id', () => {
  it('ADMIN gets the RAW email and phone — the one deliberate exception', async () => {
    const owner = await makeUser('USER', {
      displayName: 'Ravi Sharma',
      phone: '+919876543210',
      email: 'ravi@example.com',
      phoneVerified: true,
    });
    const { auth } = await makeUser('ADMIN');

    const res = await request(app).get(`/admin/users/${owner.id}`).set(auth);

    expect(res.status).toBe(200);
    expect(res.body.user).toMatchObject({
      id: owner.id,
      displayName: 'Ravi Sharma',
      email: 'ravi@example.com',
      phone: '+919876543210',
      phoneVerified: true,
      emailVerified: false,
      role: 'USER',
      hasAvatar: false,
    });
    expect(typeof res.body.user.createdAt).toBe('string');
    // Personal data must not sit in any cache.
    expect(res.headers['cache-control']).toBe('no-store');
  });

  it('audits the read with hashed ids only — and the event actually survives the emit layer', async () => {
    const owner = await makeUser('USER', {
      displayName: 'Ravi Sharma',
      phone: '+919876543210',
      email: 'ravi@example.com',
    });
    const admin = await makeUser('ADMIN');
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});

    await request(app).get(`/admin/users/${owner.id}`).set(admin.auth);

    const events = logSpy.mock.calls.filter((c) =>
      String(c[0]).includes('[analytics] admin_project_owner_viewed')
    );
    // Not just "one event": a prop named has_phone/has_email would be STRIPPED
    // and the strict schema would then drop the whole event, leaving an audit
    // trail that quietly does not exist. This asserts it arrived.
    expect(events).toHaveLength(1);
    const props = JSON.parse(String(events[0]![1]));
    expect(props.contact_channels).toBe('both');
    expect(props.subject_role).toBe('USER');
    expect(props.subject_id_hash).not.toBe(owner.id);
    expect(props.actor_id_hash).not.toBe(admin.id);
    const serialized = String(events[0]![1]);
    expect(serialized).not.toContain('9876543210');
    expect(serialized).not.toContain('ravi@example.com');
    expect(serialized).not.toContain('Ravi Sharma');
  });

  it('is ADMIN-only: a MODEL_ARTIST is refused', async () => {
    const owner = await makeUser('USER', { phone: '+919876543210' });
    const { auth } = await makeUser('MODEL_ARTIST');

    const res = await request(app).get(`/admin/users/${owner.id}`).set(auth);

    expect(res.status).toBe(403);
    expect(JSON.stringify(res.body)).not.toContain('9876543210');
  });

  it('nulls the fields an account never had, rather than omitting them', async () => {
    const owner = await makeUser('USER');
    const { auth } = await makeUser('ADMIN');

    const res = await request(app).get(`/admin/users/${owner.id}`).set(auth);

    expect(res.body.user.displayName).toBeNull();
    expect(res.body.user.email).toBeNull();
    expect(res.body.user.phone).toBeNull();
  });

  it('404s for an id that no longer resolves', async () => {
    const { auth } = await makeUser('ADMIN');
    const res = await request(app)
      .get(`/admin/users/${new Types.ObjectId().toHexString()}`)
      .set(auth);
    expect(res.status).toBe(404);
    expect(res.body.code).toBe('NOT_FOUND');
  });

  it('400s a malformed id', async () => {
    const { auth } = await makeUser('ADMIN');
    const res = await request(app).get('/admin/users/not-an-id').set(auth);
    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
  });

  it('meters the lookup per admin', async () => {
    const owner = await makeUser('USER', { phone: '+919876543210' });
    const { auth } = await makeUser('ADMIN');

    // One request past the cap; the last one must be the refusal.
    let last = await request(app).get(`/admin/users/${owner.id}`).set(auth);
    for (let i = 0; i < env.ADMIN_USER_LOOKUP_MAX_PER_WINDOW; i += 1) {
      last = await request(app).get(`/admin/users/${owner.id}`).set(auth);
    }

    expect(last.status).toBe(429);
    expect(last.body.code).toBe('RATE_LIMITED');
    // A refusal must not leak what it refused to hand over.
    expect(JSON.stringify(last.body)).not.toContain('9876543210');
  });
});

// ── The picture ──────────────────────────────────────────────────────────────

describe('GET /admin/users/:id/avatar/bytes', () => {
  it('serves the bytes of an owner who has a picture', async () => {
    const owner = await makeUser('USER');
    await User.findByIdAndUpdate(owner.id, {
      $set: { avatarKey: buildAvatarKey(owner.id, 'avatar-1', 'png') },
    }).exec();
    const { auth } = await makeUser('ADMIN');
    mockAvatarGet();

    const res = await request(app).get(`/admin/users/${owner.id}/avatar/bytes`).set(auth);

    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toContain('image/png');
    expect(res.headers['cache-control']).toBe('private, max-age=300');
  });

  it('404s when the account has no picture — S3 is never touched', async () => {
    const owner = await makeUser('USER');
    const { auth } = await makeUser('ADMIN');
    const send = mockAvatarGet();

    const res = await request(app).get(`/admin/users/${owner.id}/avatar/bytes`).set(auth);

    expect(res.status).toBe(404);
    expect(send).not.toHaveBeenCalled();
  });

  it('is ADMIN-only', async () => {
    const owner = await makeUser('USER');
    const { auth } = await makeUser('MODEL_ARTIST');
    const res = await request(app).get(`/admin/users/${owner.id}/avatar/bytes`).set(auth);
    expect(res.status).toBe(403);
  });
});
