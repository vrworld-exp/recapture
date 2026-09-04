// tests/rep-delegation.test.ts
//
// Stage 4: the authorization model behind acting-on-behalf-of.
//
// WHAT THIS SUITE IS PROTECTING is a negative: that letting a rep write into
// somebody else's catalog did NOT open a second, weaker door into owner data.
// The two assertions that matter most are the ones that could pass silently if
// the gate were wrong —
//
//   • a rep with no grant gets an answer BYTE-IDENTICAL to the one a
//     nonexistent catalog gives, so /rep cannot be used to discover which
//     catalogs exist;
//   • a rep hitting /catalog gets their OWN (empty) catalog and never the
//     restaurant's, proving the owner routes are untouched by this stage.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';

import {
  HeadObjectCommand,
  ListObjectsV2Command,
  DeleteObjectCommand,
} from '@aws-sdk/client-s3';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { s3Client } from '@/config/s3';
import { buildProductImageKey } from '@/utils/productImageKeys';
import { User, type UserRole } from '@/models/User';
import { Catalog } from '@/models/Catalog';
import { CatalogDelegation } from '@/models/CatalogDelegation';
import { CatalogProduct } from '@/models/CatalogProduct';
import { QrCode } from '@/models/QrCode';
import { QrCodeAssignment } from '@/models/QrCodeAssignment';
import { RateWindow } from '@/models/RateWindow';
import { revokeDelegation, grantDelegation } from '@/services/catalogDelegationService';

const app = createApp();
let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await QrCode.syncIndexes();
  await Catalog.syncIndexes();
  // The revoke-then-re-grant test is meaningless unless the PARTIAL index is
  // the one that actually exists: a plain unique index would let that test pass
  // for the wrong reason on the first grant and fail on the second.
  await CatalogDelegation.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

/** Keys the scripted S3 believes exist, and their sizes. */
const s3Objects = new Map<string, number>();

beforeEach(() => {
  Object.assign(env, { PUBLIC_RESOLVER_BASE_URL: 'https://scan.test' });
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});

  // An IMAGE_ONLY product needs a COMMITTED image key, and createProduct HEADs
  // the object rather than trusting the key — the same containment guard a
  // replacement goes through. Scripted here (the shape tests/catalog-product-*
  // use) so the rep path exercises the real service, not a stub of it.
  s3Objects.clear();
  vi.spyOn(s3Client, 'send').mockImplementation((command: unknown) => {
    if (command instanceof HeadObjectCommand) {
      const key = command.input.Key as string;
      if (!s3Objects.has(key)) {
        const err = new Error('NotFound');
        err.name = 'NotFound';
        return Promise.reject(err);
      }
      return Promise.resolve({ ContentLength: s3Objects.get(key) }) as never;
    }
    if (command instanceof ListObjectsV2Command) {
      const prefix = (command.input.Prefix as string) ?? '';
      return Promise.resolve({
        Contents: [...s3Objects.entries()]
          .filter(([key]) => key.startsWith(prefix))
          .map(([Key, Size]) => ({ Key, Size })),
        IsTruncated: false,
      }) as never;
    }
    if (command instanceof DeleteObjectCommand) {
      s3Objects.delete(command.input.Key as string);
      return Promise.resolve({}) as never;
    }
    return Promise.reject(new Error(`unscripted S3 command: ${String(command)}`));
  });
});

afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all([
    User.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogDelegation.deleteMany({}),
    CatalogProduct.deleteMany({}),
    QrCode.deleteMany({}),
    QrCodeAssignment.deleteMany({}),
    RateWindow.deleteMany({}),
  ]);
});

async function makeUser(role: UserRole): Promise<{ id: string; auth: { Authorization: string } }> {
  const user = await User.create({
    authProvider: 'custom',
    authUid: `test|${new Types.ObjectId().toHexString()}`,
    role,
  });
  const id = user.id as string;
  const token = jwt.sign({ userId: id, authUid: user.authUid }, env.JWT_SECRET, {
    expiresIn: '15m',
  });
  return { id, auth: { Authorization: `Bearer ${token}` } };
}

async function mint(code: string): Promise<void> {
  await QrCode.create({
    code,
    batchId: new Types.ObjectId(),
    state: 'UNASSIGNED',
    deletedAt: null,
  });
}

/** A rep who has activated one standee, and the catalog they now hold. */
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
  return { rep, catalogId, ownerId: String(owner!._id) };
}

/**
 * An IMAGE_ONLY product body whose image key exists in the scripted S3 and is
 * scoped to this catalog — the containment guard rejects anything else.
 */
function productBody(catalogId: string, name: string): Record<string, string> {
  const key = buildProductImageKey(
    catalogId,
    new Types.ObjectId().toHexString(),
    new Types.ObjectId().toHexString(),
    'jpg'
  );
  s3Objects.set(key, 1024);
  return { type: 'IMAGE_ONLY', name, imageKey: key };
}

describe('the gate — no existence leak', () => {
  it('answers identically for a catalog that is not delegated and one that does not exist', async () => {
    const { catalogId } = await activated('ABCD2345');
    const stranger = await makeUser('SALES_REP');
    const ghostId = new Types.ObjectId().toHexString();

    const notDelegated = await request(app)
      .post(`/rep/catalogs/${catalogId}/products`)
      .set(stranger.auth)
      .send({ name: 'Dosa', type: 'IMAGE_ONLY' });
    const nonexistent = await request(app)
      .post(`/rep/catalogs/${ghostId}/products`)
      .set(stranger.auth)
      .send({ name: 'Dosa', type: 'IMAGE_ONLY' });

    // Status, code and body all identical — /rep must not become a way to
    // enumerate which catalogs are real.
    expect(notDelegated.status).toBe(404);
    expect(nonexistent.status).toBe(404);
    expect(notDelegated.body).toEqual(nonexistent.body);
  });

  it('gives a malformed catalog id the same 404, not a 400', async () => {
    const stranger = await makeUser('SALES_REP');

    const res = await request(app)
      .post('/rep/catalogs/not-an-objectid/products')
      .set(stranger.auth)
      .send({ name: 'Dosa', type: 'IMAGE_ONLY' });

    // A 400 for "not an ObjectId" and a 404 for "not yours" would still be two
    // distinguishable answers.
    expect(res.status).toBe(404);
    expect(res.body.code).toBe('CATALOG_NOT_FOUND');
  });
});

describe('revocation', () => {
  it('is effective on the very next request — no token expiry involved', async () => {
    const { rep, catalogId } = await activated('BBBB2222');

    const before = await request(app)
      .post(`/rep/catalogs/${catalogId}/products`)
      .set(rep.auth)
      .send(productBody(catalogId, 'Idli'));
    expect(before.status).toBe(201);

    await revokeDelegation(new Types.ObjectId(rep.id), new Types.ObjectId(catalogId));

    const after = await request(app)
      .post(`/rep/catalogs/${catalogId}/products`)
      .set(rep.auth)
      .send(productBody(catalogId, 'Vada'));
    // Same token, same second, no access. The grant is read per request.
    expect(after.status).toBe(404);
    expect(await CatalogProduct.countDocuments({ name: 'vada' })).toBe(0);
  });

  it('drops a revoked catalog out of GET /rep/catalogs', async () => {
    const { rep, catalogId } = await activated('CCCC3333');

    const listed = await request(app).get('/rep/catalogs').set(rep.auth);
    expect(listed.body.catalogs).toHaveLength(1);
    expect(listed.body.catalogs[0]).toMatchObject({
      id: catalogId,
      publicUrl: 'https://scan.test/r/CCCC3333',
      isProvisioned: false,
    });

    await revokeDelegation(new Types.ObjectId(rep.id), new Types.ObjectId(catalogId));

    const after = await request(app).get('/rep/catalogs').set(rep.auth);
    expect(after.body.catalogs).toEqual([]);
  });

  it('allows a re-grant after a revoke — the unique index is on LIVE rows only', async () => {
    const { rep, catalogId } = await activated('DDDD4444');
    const repId = new Types.ObjectId(rep.id);
    const catId = new Types.ObjectId(catalogId);

    await revokeDelegation(repId, catId);
    await grantDelegation(repId, catId);

    // A plain unique index would have made the revoked row block this forever,
    // and "revoke by mistake, grant again" is an ordinary Monday.
    const res = await request(app)
      .post(`/rep/catalogs/${catalogId}/products`)
      .set(rep.auth)
      .send(productBody(catalogId, 'Uttapam'));
    expect(res.status).toBe(201);

    expect(await CatalogDelegation.countDocuments({ repUserId: repId, catalogId: catId })).toBe(2);
    expect(
      await CatalogDelegation.countDocuments({ repUserId: repId, catalogId: catId, revokedAt: null })
    ).toBe(1);
  });

  it('grantDelegation is idempotent — a second grant opens no second live row', async () => {
    const { rep, catalogId } = await activated('EEEE5555');
    const repId = new Types.ObjectId(rep.id);
    const catId = new Types.ObjectId(catalogId);

    await grantDelegation(repId, catId);
    await grantDelegation(repId, catId);

    expect(await CatalogDelegation.countDocuments({ repUserId: repId, catalogId: catId })).toBe(1);
  });
});

describe('the role gate', () => {
  it('refuses a plain USER on every /rep route', async () => {
    const { auth } = await makeUser('USER');
    const id = new Types.ObjectId().toHexString();

    const responses = await Promise.all([
      request(app).get('/rep/codes/ABCD2345').set(auth),
      request(app).post('/rep/activations').set(auth).send({}),
      request(app).get('/rep/catalogs').set(auth),
      request(app).post(`/rep/catalogs/${id}/products`).set(auth).send({}),
      request(app).post(`/rep/catalogs/${id}/qr-codes`).set(auth).send({}),
      request(app).post('/rep/qr-codes/ABCD2345/retire').set(auth).send({}),
    ]);

    for (const res of responses) {
      expect(res.status).toBe(403);
      expect(res.body.code).toBe('FORBIDDEN');
    }
  });

  it('lets SALES_REP, MODEL_ARTIST and ADMIN through — inheritance, pinned', async () => {
    // The role ladder is inclusive upward, so a MODEL_ARTIST and an ADMIN pass
    // every /rep gate. That is ACCEPTED, not overlooked (both are
    // script-granted, and every acting-on-behalf-of write leaves a delegation
    // row) — asserted here so the decision is pinned by a test rather than
    // rediscovered by someone reading the rank table.
    for (const role of ['SALES_REP', 'MODEL_ARTIST', 'ADMIN'] as const) {
      const { auth } = await makeUser(role);
      const res = await request(app).get('/rep/catalogs').set(auth);
      expect(res.status).toBe(200);
      expect(res.body.catalogs).toEqual([]);
    }
  });

  it('refuses an unauthenticated caller before any role read', async () => {
    const res = await request(app).get('/rep/catalogs');
    expect(res.status).toBe(401);
  });
});

describe('the owner routes are untouched', () => {
  it('a rep hitting /catalog gets their OWN (absent) catalog, never the restaurant’s', async () => {
    const { rep, catalogId } = await activated('FFFF6666');

    const res = await request(app).get('/catalog').set(rep.auth);

    // The rep owns no catalog. If /rep had opened a second door into owner
    // data, this is where the restaurant's catalog would leak out of it.
    expect(res.status).toBe(404);
    expect(JSON.stringify(res.body)).not.toContain(catalogId);
  });

  it('a rep-created product belongs to the RESTAURANT, not the rep', async () => {
    const { rep, catalogId, ownerId } = await activated('GGGG7777');

    const res = await request(app)
      .post(`/rep/catalogs/${catalogId}/products`)
      .set(rep.auth)
      .send(productBody(catalogId, 'Masala Dosa'));

    expect(res.status).toBe(201);
    const product = await CatalogProduct.findById(res.body.product.id).exec();
    // The rep's identity is not on the row at all — the audit trail is the
    // CatalogDelegation grant, not a second owner column nothing understands.
    expect(String(product!.userId)).toBe(ownerId);
    expect(String(product!.userId)).not.toBe(rep.id);
    expect(String(product!.catalogId)).toBe(catalogId);
  });

  it('rejects a product body carrying a catalogId', async () => {
    const { rep, catalogId } = await activated('HHHH8888');

    const res = await request(app)
      .post(`/rep/catalogs/${catalogId}/products`)
      .set(rep.auth)
      .send({ ...productBody(catalogId, 'Sambar'), catalogId });

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
  });
});
