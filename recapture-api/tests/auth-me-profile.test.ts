// tests/auth-me-profile.test.ts
//
// The Profile surface's server contract: GET /auth/me ships displayName +
// contactMasked + contactChannel, PATCH /auth/me sets the name, and NEITHER ever
// ships a raw phone or email.
//
// The no-raw-PII assertion is the load-bearing test in this file. The whole
// design of `maskIdentifier` exists to keep the standing PII stance while still
// telling the user which account they are in; a regression that "helpfully"
// added `phone` to the snapshot would be invisible to every other test here.
//
// Hermetic: ephemeral in-memory MongoDB, no network, no real SMS/email. Tokens
// are minted directly with the same JWT_SECRET the app validates against, so the
// OTP flow is not re-exercised (auth-happy-path.test.ts owns that).
//
// ENV NOTE: vitest.config.ts injects env BEFORE the module graph loads —
// config/env.ts validates and freezes at import, so a per-test process.env write
// would be too late. Never add one here.
import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import request from 'supertest';
import mongoose from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { User } from '@/models/User';

const app = createApp();
let mongod: MongoMemoryServer;

// The seeded identifiers. Asserted ABSENT from every response body — both whole
// and in the fragments a partial leak would produce.
const SEED_PHONE = '+919876543210';
const SEED_EMAIL = 'ashish@example.com';

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

afterEach(async () => {
  const { collections } = mongoose.connection;
  await Promise.all(Object.values(collections).map((c) => c.deleteMany({})));
});

/** Seeds a user and returns it plus an access token for it. */
async function seedUser(
  fields: Partial<{ phone: string; email: string; displayName: string }>
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

describe('GET /auth/me — profile snapshot', () => {
  it('returns displayName, contactMasked and contactChannel for a phone user', async () => {
    const { token } = await seedUser({ phone: SEED_PHONE, displayName: 'Ashish K' });

    const res = await request(app).get('/auth/me').set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(res.body.status).toBe('success');
    expect(res.body.user).toMatchObject({
      role: 'USER',
      displayName: 'Ashish K',
      contactMasked: '+91 ••••• ••210',
      contactChannel: 'sms',
    });
    // The pre-existing fields are untouched.
    expect(typeof res.body.user.id).toBe('string');
    expect(res.body.user.phoneVerified).toBe(true);
    expect(typeof res.body.user.createdAt).toBe('string');
    // No picture set → both avatar fields are null, never absent.
    expect(res.body.user.avatarUrl).toBeNull();
    expect(res.body.user.avatarUrlExpiresAt).toBeNull();
  });

  it('masks an email identifier and reports the email channel', async () => {
    const { token } = await seedUser({ email: SEED_EMAIL });

    const res = await request(app).get('/auth/me').set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(res.body.user).toMatchObject({
      displayName: null, // never set → null, not absent
      contactMasked: 'a•••@example.com',
      contactChannel: 'email',
    });
  });

  it('THE PII GUARDRAIL: no raw phone or email appears anywhere in the body', async () => {
    // One user carrying BOTH identifiers, so a leak of either is caught.
    const { token } = await seedUser({
      phone: SEED_PHONE,
      email: SEED_EMAIL,
      displayName: 'Ashish K',
    });

    const res = await request(app).get('/auth/me').set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);

    const body = JSON.stringify(res.body);
    expect(body).not.toContain(SEED_PHONE);
    expect(body).not.toContain(SEED_EMAIL);
    // Partial leaks: the local part of the email and the un-masked middle of the
    // phone must not survive either. (The mask deliberately keeps the domain,
    // the '+91' dial prefix, and the last 3 digits — those are the whole point.)
    expect(body).not.toContain('ashish@');
    expect(body).not.toContain('9876543');
    // And the fields that would carry them are simply not on the snapshot.
    expect(res.body.user).not.toHaveProperty('phone');
    expect(res.body.user).not.toHaveProperty('email');
  });

  it('returns a null mask when the account has no identifier at all', async () => {
    const { token } = await seedUser({});

    const res = await request(app).get('/auth/me').set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(res.body.user.contactMasked).toBeNull();
  });
});

describe('PATCH /auth/me — display name', () => {
  it('persists a name and returns the same snapshot shape as GET', async () => {
    const { id, token } = await seedUser({ phone: SEED_PHONE });

    const res = await request(app)
      .patch('/auth/me')
      .set('Authorization', `Bearer ${token}`)
      .send({ displayName: '  Ashish K  ' });

    expect(res.status).toBe(200);
    expect(res.body.status).toBe('success');
    expect(res.body.user.displayName).toBe('Ashish K'); // trimmed
    // Same shape as GET — one client parser, not two. (avatarUrl /
    // avatarUrlExpiresAt are on every snapshot; they are null until a picture is
    // committed — see auth-me-avatar.test.ts. `avatarKey` is deliberately NOT
    // here: the key is an internal identifier, only the URL ships.)
    expect(Object.keys(res.body.user).sort()).toEqual(
      [
        'avatarUrl',
        'avatarUrlExpiresAt',
        'contactChannel',
        'contactMasked',
        'createdAt',
        'displayName',
        'emailVerified',
        'id',
        'phoneVerified',
        'role',
      ].sort()
    );

    // Actually persisted, and readable back through GET.
    expect((await User.findById(id).exec())?.displayName).toBe('Ashish K');
    const get = await request(app).get('/auth/me').set('Authorization', `Bearer ${token}`);
    expect(get.body.user.displayName).toBe('Ashish K');
  });

  it('leaks no raw identifier on the PATCH response either', async () => {
    const { token } = await seedUser({ phone: SEED_PHONE, email: SEED_EMAIL });

    const res = await request(app)
      .patch('/auth/me')
      .set('Authorization', `Bearer ${token}`)
      .send({ displayName: 'Ashish K' });

    const body = JSON.stringify(res.body);
    expect(body).not.toContain(SEED_PHONE);
    expect(body).not.toContain(SEED_EMAIL);
  });

  const rejections: { name: string; displayName: unknown; rule: string }[] = [
    { name: 'an empty string', displayName: '', rule: 'DISPLAY_NAME_EMPTY' },
    { name: 'whitespace only', displayName: '   ', rule: 'DISPLAY_NAME_EMPTY' },
    { name: '61 characters', displayName: 'x'.repeat(61), rule: 'DISPLAY_NAME_TOO_LONG' },
    {
      name: 'an embedded newline',
      displayName: `Ashish${String.fromCharCode(10)}K`,
      rule: 'DISPLAY_NAME_INVALID_CHARS',
    },
    {
      name: 'an embedded NUL',
      displayName: `Ashish${String.fromCharCode(0)}K`,
      rule: 'DISPLAY_NAME_INVALID_CHARS',
    },
    { name: 'a non-string', displayName: 42, rule: 'DISPLAY_NAME_INVALID' },
  ];

  it.each(rejections)('rejects $name with the standard envelope', async (c) => {
    const { id, token } = await seedUser({ phone: SEED_PHONE });

    const res = await request(app)
      .patch('/auth/me')
      .set('Authorization', `Bearer ${token}`)
      .send({ displayName: c.displayName });

    expect(res.status).toBe(400);
    expect(res.body.status).toBe('error');
    expect(res.body.code).toBe('INVALID_REQUEST');
    expect(res.body.rule).toBe(c.rule);
    // Nothing was written.
    expect((await User.findById(id).exec())?.displayName).toBeUndefined();
  });

  it('accepts exactly 60 characters (the boundary is inclusive)', async () => {
    const { token } = await seedUser({ phone: SEED_PHONE });
    const name = 'x'.repeat(60);

    const res = await request(app)
      .patch('/auth/me')
      .set('Authorization', `Bearer ${token}`)
      .send({ displayName: name });

    expect(res.status).toBe(200);
    expect(res.body.user.displayName).toBe(name);
  });

  it('rejects an attempt to change phone/email/role through this route', async () => {
    const { id, token } = await seedUser({ phone: SEED_PHONE });

    const res = await request(app)
      .patch('/auth/me')
      .set('Authorization', `Bearer ${token}`)
      .send({ displayName: 'Ashish K', role: 'ADMIN', phone: '+10000000000' });

    expect(res.status).toBe(400);
    const after = await User.findById(id).exec();
    expect(after?.role).toBe('USER');
    expect(after?.phone).toBe(SEED_PHONE);
  });

  it('without a token → 401', async () => {
    const res = await request(app).patch('/auth/me').send({ displayName: 'Ashish K' });

    expect(res.status).toBe(401);
    expect(res.body.code).toBe('UNAUTHENTICATED');
  });
});
