// tests/rep-catalog-qr.test.ts
//
// GET /rep/catalogs/:id/qr — the restaurant's own code, fetched by the rep who
// put the menu online.
//
// THE ASSERTION THAT CARRIES THIS SUITE is byte-identity with the owner's
// `/catalog/qr`. The whole justification for a second endpoint is that it is a
// second DOOR to one image, not a second image: the day these two diverge, a
// rep and a restaurant are printing different squares for the same table and
// nothing else in the system would notice. The test compares the bytes, and the
// ETag, rather than trusting that both call the same function today.
//
// The rest are the ones that fail quietly if the route is wrong: the 404 a
// stranger gets — which must be indistinguishable from a nonexistent catalog —
// the conditional request, because this endpoint is meant to be cached and a
// broken ETag turns every open into a render, and the pair around the frozen
// URL, which pins something easy to get backwards: a rep activation mints the
// URL, so the square exists BEFORE the first publish and the 409 is a guard on
// a state the rep path does not normally reach.
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

async function mint(code: string): Promise<void> {
  await QrCode.create({
    code,
    batchId: new Types.ObjectId(),
    state: 'UNASSIGNED',
    deletedAt: null,
  });
}

/**
 * A rep who has activated one standee, plus the restaurant OWNER's own
 * credentials.
 *
 * The second half is what makes the byte-identity test possible: one catalog
 * has to be fetched through both doors in the same test.
 */
async function activated(code: string, phone = '+919876543210') {
  const rep = await makeUser('SALES_REP');
  await mint(code);
  const res = await request(app)
    .post('/rep/activations')
    .set(rep.auth)
    .send({ code, restaurantName: 'Blue Cafe', restaurantPhone: phone });
  expect(res.status).toBe(201);

  const catalogId: string = res.body.catalogId;
  const owner = await User.findOne({ phone }).exec();
  const ownerId = String(owner!._id);
  return {
    rep,
    catalogId,
    ownerId,
    ownerAuth: authFor(ownerId, owner!.authUid as string),
  };
}

/**
 * Provisioning, without running a publish.
 *
 * The URL is what the renderer takes verbatim, and the publish pipeline is a
 * different suite's subject — writing the field directly is the smallest thing
 * that makes a catalog "live" in the only sense this endpoint cares about.
 */
async function provision(catalogId: string, url = 'https://menu.test/blue-cafe'): Promise<void> {
  await Catalog.updateOne(
    { _id: new Types.ObjectId(catalogId) },
    { $set: { publicUrl: url, mirageRestaurantId: 'mir-1' } }
  ).exec();
}

describe('a rep reads the restaurant own QR', () => {
  it('renders the SAME bytes the owner gets from /catalog/qr', async () => {
    const { rep, catalogId, ownerAuth } = await activated('QRAA2345');
    await provision(catalogId);

    const viaRep = await request(app)
      .get(`/rep/catalogs/${catalogId}/qr`)
      .set(rep.auth)
      .responseType('blob');
    const viaOwner = await request(app).get('/catalog/qr').set(ownerAuth).responseType('blob');

    expect(viaRep.status).toBe(200);
    expect(viaOwner.status).toBe(200);
    expect(viaRep.headers['content-type']).toBe('image/png');

    // The whole point of the endpoint. Not "both are PNGs" — the same PNG.
    expect(Buffer.from(viaRep.body).equals(Buffer.from(viaOwner.body))).toBe(true);
    // And the same cache key, so a client holding one must hit on the other.
    expect(viaRep.headers.etag).toBe(viaOwner.headers.etag);
  });

  it('renders a PDF when asked for one', async () => {
    const { rep, catalogId } = await activated('QRBB2345');
    await provision(catalogId);

    const res = await request(app)
      .get(`/rep/catalogs/${catalogId}/qr?format=pdf`)
      .set(rep.auth)
      .responseType('blob');

    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toBe('application/pdf');
    expect(res.headers['content-disposition']).toContain('attachment');
  });

  it('answers a conditional request with 304 and no body', async () => {
    const { rep, catalogId } = await activated('QRCC2345');
    await provision(catalogId);

    const first = await request(app).get(`/rep/catalogs/${catalogId}/qr`).set(rep.auth);
    expect(first.status).toBe(200);

    const second = await request(app)
      .get(`/rep/catalogs/${catalogId}/qr`)
      .set(rep.auth)
      .set('If-None-Match', first.headers.etag);

    expect(second.status).toBe(304);
  });
});

describe('before there is a URL', () => {
  it('refuses with CATALOG_NOT_PUBLISHED rather than inventing one', async () => {
    const { rep, catalogId } = await activated('QRDD2345');
    // ACTIVATION ALREADY FREEZES A URL on this path — the standee resolves from
    // the moment a rep claims it, to a "not live yet" page — so the unprovisioned
    // state has to be constructed here rather than assumed. It is still the state
    // this branch exists for: a delegated catalog that reached the rep some other
    // way has no URL, and the route must not compose one.
    await Catalog.updateOne(
      { _id: new Types.ObjectId(catalogId) },
      { $unset: { publicUrl: '' } }
    ).exec();

    const res = await request(app).get(`/rep/catalogs/${catalogId}/qr`).set(rep.auth);

    // A QR that resolves to nothing is worse than no QR — it might get printed.
    expect(res.status).toBe(409);
    expect(res.body.code).toBe('CATALOG_NOT_PUBLISHED');
  });

  it('does NOT serve the standee URL a rep activation froze, before the first publish', async () => {
    // Activation freezes `{resolver}/r/{code}` into `publicUrl`, and this route
    // used to draw it. It no longer does: the resolver is this API's own host,
    // and a rep reprinting from the QR screen must get the Mirage page or
    // nothing (services/customerUrl.ts). Before the first publish there is no
    // Mirage page, so the answer is the owner route's 409 — and the button
    // that reaches this screen is gated on a live menu anyway.
    const { rep, catalogId } = await activated('QRGG2345');

    const res = await request(app).get(`/rep/catalogs/${catalogId}/qr`).set(rep.auth);

    expect(res.status).toBe(409);
    expect(res.body.code).toBe('CATALOG_NOT_PUBLISHED');
  });
});

describe('the gate', () => {
  it('gives a stranger the same answer a nonexistent catalog gives', async () => {
    const { catalogId } = await activated('QREE2345');
    await provision(catalogId);
    const stranger = await makeUser('SALES_REP');
    const ghostId = new Types.ObjectId().toHexString();

    const notDelegated = await request(app).get(`/rep/catalogs/${catalogId}/qr`).set(stranger.auth);
    const nonexistent = await request(app).get(`/rep/catalogs/${ghostId}/qr`).set(stranger.auth);

    // Identical, so this route cannot be used to discover which restaurants a
    // competitor has signed up — the rule the rest of /rep follows.
    expect(notDelegated.status).toBe(404);
    expect(nonexistent.status).toBe(404);
    expect(notDelegated.body).toEqual(nonexistent.body);
  });

  it('is closed to a plain user, delegation or not', async () => {
    const { catalogId } = await activated('QRFF2345');
    await provision(catalogId);
    const outsider = await makeUser('USER');

    const res = await request(app).get(`/rep/catalogs/${catalogId}/qr`).set(outsider.auth);

    // The router-level role gate, not the delegation one.
    expect(res.status).toBe(403);
  });
});
