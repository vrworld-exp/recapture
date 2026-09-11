// tests/rep-restaurant-account.test.ts
//
// The restaurant's ACCOUNT NUMBER on the rep's details screen — the second (and
// only other) place in this API that answers with a raw phone.
//
// THIS SUITE IS THE BOUND, not a feature check. `GET /admin/users/:id` was the
// one exception to the PII stance and it is fenced by its own tests; this pair
// of routes is the amendment, and what makes it defensible is a set of
// properties that are all easy to lose in a later refactor:
//
//   • IT IS READ-ONLY. `updateBusinessProfileSchema` is `.strict()`, so a client
//     that tries to write the number is rejected rather than quietly ignored.
//     A rep must not be able to change how a client signs in.
//   • IT IS DELEGATION-GATED, and a stranger's 404 is byte-identical to a
//     nonexistent catalog's.
//   • IT NEVER REACHES THE OWNER SURFACE. `/catalog/profile` must stay free of
//     it: that route is not delegation-gated and has no business carrying a raw
//     identifier.
//   • IT IS `no-store`. A body with an unmasked identifier gets no shared cache
//     and no browser disk copy — the rule the admin route already follows.
//   • IT SURVIVES A SAVE. Every rep route that returns a profile carries the
//     block, or the number disappears the first time somebody edits an address.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { User, type UserRole } from '@/models/User';
import { Catalog } from '@/models/Catalog';
import { CatalogDelegation } from '@/models/CatalogDelegation';
import { QrCode } from '@/models/QrCode';
import { QrCodeAssignment } from '@/models/QrCodeAssignment';
import { RateWindow } from '@/models/RateWindow';

const app = createApp();
let mongod: MongoMemoryServer;

const PHONE = '+919876543210';

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await QrCode.syncIndexes();
  await Catalog.syncIndexes();
  await CatalogDelegation.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  Object.assign(env, { PUBLIC_RESOLVER_BASE_URL: 'https://scan.test' });
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
});

afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all([
    User.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogDelegation.deleteMany({}),
    QrCode.deleteMany({}),
    QrCodeAssignment.deleteMany({}),
    RateWindow.deleteMany({}),
  ]);
});

function authFor(userId: string, authUid: string): { Authorization: string } {
  const token = jwt.sign({ userId, authUid }, env.JWT_SECRET, { expiresIn: '15m' });
  return { Authorization: `Bearer ${token}` };
}

async function makeUser(role: UserRole) {
  const user = await User.create({
    authProvider: 'custom',
    authUid: `test|${new Types.ObjectId().toHexString()}`,
    role,
  });
  const id = user.id as string;
  const authUid = user.authUid as string;
  return { id, authUid, auth: authFor(id, authUid) };
}

async function activated(code: string, phone = PHONE) {
  const rep = await makeUser('SALES_REP');
  await QrCode.create({
    code,
    batchId: new Types.ObjectId(),
    state: 'UNASSIGNED',
    deletedAt: null,
  });
  const res = await request(app)
    .post('/rep/activations')
    .set(rep.auth)
    .send({ code, restaurantName: 'Blue Cafe', restaurantPhone: phone });
  expect(res.status).toBe(201);

  const owner = await User.findOne({ phone }).exec();
  const ownerId = String(owner!._id);
  return {
    rep,
    catalogId: res.body.catalogId as string,
    ownerId,
    ownerAuth: authFor(ownerId, owner!.authUid as string),
  };
}

describe('the rep sees the number the restaurant signs in with', () => {
  it('carries the raw account phone on the profile read', async () => {
    const { rep, catalogId } = await activated('ACCA2345');

    const res = await request(app)
      .get(`/rep/catalogs/${catalogId}/profile`)
      .set(rep.auth);

    expect(res.status).toBe(200);
    // The number the REP TYPED at activation, handed back verbatim. That is the
    // whole justification for the raw form: it is a receipt, not a disclosure.
    expect(res.body.profile.accountPhone).toBe(PHONE);
  });

  it('is uncacheable, like the only other raw-identifier route', async () => {
    const { rep, catalogId } = await activated('ACCB2345');

    const res = await request(app)
      .get(`/rep/catalogs/${catalogId}/profile`)
      .set(rep.auth);

    expect(res.headers['cache-control']).toBe('no-store');
  });

  it('survives a save — the PATCH response carries it too', async () => {
    const { rep, catalogId } = await activated('ACCC2345');

    const res = await request(app)
      .patch(`/rep/catalogs/${catalogId}/profile`)
      .set(rep.auth)
      .send({ businessName: 'Blue Cafe Ltd' });

    expect(res.status).toBe(200);
    // The client adopts this body as the profile. Without the block here, the
    // number vanishes off the screen the first time a rep edits anything —
    // which reads as the app having lost it.
    expect(res.body.profile.accountPhone).toBe(PHONE);
    expect(res.headers['cache-control']).toBe('no-store');
  });
});

describe('it is read-only, and the schema is what enforces that', () => {
  it('REJECTS an attempt to write it rather than ignoring it', async () => {
    const { rep, catalogId } = await activated('ACCD2345');

    const res = await request(app)
      .patch(`/rep/catalogs/${catalogId}/profile`)
      .set(rep.auth)
      .send({ accountPhone: '+919999999999' });

    // `.strict()` doing the work. A silently-dropped key would look like a
    // successful edit to a rep and leave them believing they had changed it.
    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');

    const owner = await User.findOne({ phone: PHONE }).exec();
    expect(owner).not.toBeNull();
    // And nothing moved.
    expect(await User.countDocuments({ phone: '+919999999999' })).toBe(0);
  });

  it('does not let a rep change it through the contact block either', async () => {
    const { rep, catalogId } = await activated('ACCE2345');

    // `contact.phone` IS editable and is a different field — this asserts the
    // two never became one wire. Editing the public contact must not touch the
    // account the restaurant signs in with.
    const res = await request(app)
      .patch(`/rep/catalogs/${catalogId}/profile`)
      .set(rep.auth)
      .send({ contact: { phone: '+911111111111' } });

    expect(res.status).toBe(200);
    expect(res.body.profile.contact.phone).toBe('+911111111111');
    expect(res.body.profile.accountPhone).toBe(PHONE);
  });
});

describe('the bounds', () => {
  it('is never on the OWNER profile route', async () => {
    const { catalogId, ownerAuth } = await activated('ACCF2345');
    expect(catalogId).toBeTruthy();

    const res = await request(app).get('/catalog/profile').set(ownerAuth);

    expect(res.status).toBe(200);
    // /catalog is not delegation-gated and has no business carrying a raw
    // identifier. An owner knows their own number; /auth/me is masked-only.
    expect(res.body.profile.accountPhone).toBeUndefined();
    expect(JSON.stringify(res.body)).not.toContain(PHONE);
  });

  it('gives a stranger the same 404 a nonexistent catalog gives', async () => {
    const { catalogId } = await activated('ACCG2345');
    const stranger = await makeUser('SALES_REP');
    const ghostId = new Types.ObjectId().toHexString();

    const notDelegated = await request(app)
      .get(`/rep/catalogs/${catalogId}/profile`)
      .set(stranger.auth);
    const nonexistent = await request(app)
      .get(`/rep/catalogs/${ghostId}/profile`)
      .set(stranger.auth);

    expect(notDelegated.status).toBe(404);
    expect(nonexistent.status).toBe(404);
    expect(notDelegated.body).toEqual(nonexistent.body);
    // The negative that matters: a refusal must not leak what it refused.
    expect(JSON.stringify(notDelegated.body)).not.toContain(PHONE);
  });

  it('is gone the moment the delegation is', async () => {
    const { rep, catalogId } = await activated('ACCH2345');
    const { revokeDelegation } = await import('@/services/catalogDelegationService');

    await revokeDelegation(new Types.ObjectId(rep.id), new Types.ObjectId(catalogId));

    const res = await request(app)
      .get(`/rep/catalogs/${catalogId}/profile`)
      .set(rep.auth);

    // Same token, same second. The number is bound to the grant, not to having
    // once held it.
    expect(res.status).toBe(404);
  });
});
