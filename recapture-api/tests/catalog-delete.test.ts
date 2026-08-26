// tests/catalog-delete.test.ts
//
// DELETE /catalog — "delete my catalog so I can start over".
//
// THE TWO THINGS THIS SUITE GUARDS, both of which are silent when broken:
//
//   1. The delete is a HARD delete, so POST /catalog afterwards makes a genuinely
//      NEW catalog. `Catalog.userId` is uniquely indexed with no `deletedAt`
//      predicate and `createCatalog` resolves E11000 by replaying the existing
//      row — so a soft delete would hand the user back the catalog they just
//      deleted, and every assertion about "fresh" would still pass except the id.
//
//   2. Mirage is torn down FIRST, and its refusal aborts the whole thing. If the
//      local rows went first, the mapping would be gone, the orphaned restaurant
//      would keep serving the old products at the old URL, and provisioning
//      would silently re-adopt it by name on the next publish (§7.5).
//
// This is the deliberate OPPOSITE of catalog-unpublish.test.ts, which guards that
// the restaurant SURVIVES so a printed QR keeps working. Read the two together
// before changing either.
//
// Hermetic: in-memory MongoDB and the Mirage fake, no network.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { Catalog } from '@/models/Catalog';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogProduct } from '@/models/CatalogProduct';
import { CatalogPublishRun } from '@/models/CatalogPublishRun';
import { Job } from '@/models/Job';
import { User } from '@/models/User';
import { resetMirageClient, setMirageClient } from '@/services/mirage';
import { FakeMirage } from './fixtures/mirageFake';

const app = createApp();
let mongod: MongoMemoryServer;
const mirage = new FakeMirage();

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  // The one-catalog-per-user rule IS the unique index, and mongodb-memory-server
  // starts with no indexes at all — without this, the re-create assertions would
  // pass for the wrong reason.
  await Catalog.syncIndexes();
  await CatalogCategory.syncIndexes();
  await CatalogProduct.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  mirage.reset();
  setMirageClient(mirage);
  Object.assign(env, {
    MIRAGE_BASE_URL: 'https://mirage.test',
    MIRAGE_API_KEY: 'test-api-key',
    MIRAGE_ADMIN_TOKEN: 'test-admin-token',
    MIRAGE_PUBLIC_BASE_URL: 'https://menu.test',
  });
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
});

afterEach(async () => {
  vi.restoreAllMocks();
  resetMirageClient();
  await Promise.all([
    User.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogCategory.deleteMany({}),
    CatalogProduct.deleteMany({}),
    CatalogPublishRun.deleteMany({}),
    Job.deleteMany({}),
  ]);
});

type Auth = { Authorization: string };

async function makeUser(): Promise<{ id: string; auth: Auth }> {
  const user = await User.create({
    authProvider: 'custom',
    authUid: `test|${new Types.ObjectId().toHexString()}`,
  });
  const id = user.id as string;
  const token = jwt.sign({ userId: id, authUid: user.authUid }, env.JWT_SECRET, {
    expiresIn: '15m',
  });
  return { id, auth: { Authorization: `Bearer ${token}` } };
}

/** A published catalog with one category and two products under it. */
async function seedPublished(userId: string): Promise<{
  catalogId: Types.ObjectId;
  restaurantId: string;
}> {
  const restaurant = mirage.seedRestaurant('blue_cafe');
  const owner = new Types.ObjectId(userId);

  const catalog = await Catalog.create({
    userId: owner,
    name: 'Blue Cafe',
    status: 'PUBLISHED',
    draftRevision: 3,
    publishedRevision: 3,
    mirageRestaurantId: restaurant.id,
    publicUrl: `https://menu.test/${restaurant.id}`,
    publicUrlScheme: 'MIRAGE_OBJECT_ID',
    lastPublishedAt: new Date(),
  });
  const catalogId = catalog._id as Types.ObjectId;

  const category = await CatalogCategory.create({
    catalogId,
    userId: owner,
    name: 'Drinks',
    position: 0,
  });

  await CatalogProduct.create([
    {
      catalogId,
      userId: owner,
      categoryId: category._id,
      type: 'IMAGE_ONLY',
      name: 'Chair',
      position: 0,
      assets: { imageKey: 'dev/catalog/x/products/p/0.jpg' },
      mirageItemId: 'mi-1',
      syncStatus: 'SYNCED',
    },
    {
      catalogId,
      userId: owner,
      categoryId: category._id,
      type: 'IMAGE_ONLY',
      name: 'Table',
      position: 1,
      assets: { imageKey: 'dev/catalog/x/products/q/0.jpg' },
      mirageItemId: 'mi-2',
      syncStatus: 'SYNCED',
    },
  ]);

  await CatalogPublishRun.create({
    catalogId,
    userId: owner,
    jobId: new Types.ObjectId(),
    mode: 'FULL',
    state: 'SUCCEEDED',
    snapshotRevision: 3,
  });

  return { catalogId, restaurantId: restaurant.id };
}

/** An unpublished, never-provisioned catalog. */
async function seedDraft(userId: string): Promise<Types.ObjectId> {
  const catalog = await Catalog.create({
    userId: new Types.ObjectId(userId),
    name: 'Blue Cafe',
    status: 'DRAFT',
    draftRevision: 1,
    publishedRevision: -1,
  });
  return catalog._id as Types.ObjectId;
}

describe('DELETE /catalog', () => {
  it('deletes the catalog, its categories, its products and its publish runs', async () => {
    const { id, auth } = await makeUser();
    const { catalogId } = await seedPublished(id);

    const res = await request(app).delete('/catalog').set(auth).send();

    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({
      status: 'success',
      deletedProductCount: 2,
      deletedCategoryCount: 1,
      wasPublished: true,
    });

    expect(await Catalog.countDocuments({ _id: catalogId })).toBe(0);
    expect(await CatalogCategory.countDocuments({ catalogId })).toBe(0);
    expect(await CatalogProduct.countDocuments({ catalogId })).toBe(0);
    expect(await CatalogPublishRun.countDocuments({ catalogId })).toBe(0);
  });

  it('tears the Mirage restaurant down — the public page must not outlive it', async () => {
    const { id, auth } = await makeUser();
    const { restaurantId } = await seedPublished(id);

    await request(app).delete('/catalog').set(auth).send();

    expect(mirage.callsTo('deleteRestaurant')).toHaveLength(1);
    expect(mirage.restaurants.has(restaurantId)).toBe(false);
  });

  it('lets the user create a genuinely NEW catalog afterwards', async () => {
    const { id, auth } = await makeUser();
    const { catalogId } = await seedPublished(id);

    await request(app).delete('/catalog').set(auth).send();

    const created = await request(app)
      .post('/catalog')
      .set(auth)
      .send({ name: 'Blue Cafe' });

    // 201 CREATED, not the 200 replay a still-occupied slot would produce, and
    // a different id with none of the old state carried over.
    expect(created.status).toBe(201);
    expect(created.body.catalog.id).not.toBe(catalogId.toHexString());
    expect(created.body.catalog).toMatchObject({
      status: 'DRAFT',
      publicUrl: null,
      isProvisioned: false,
      counts: { products: 0, categories: 0 },
    });
  });

  it('makes no Mirage call for a catalog that was never provisioned', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seedDraft(id);

    const res = await request(app).delete('/catalog').set(auth).send();

    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ wasPublished: false });
    expect(mirage.calls).toHaveLength(0);
    expect(await Catalog.countDocuments({ _id: catalogId })).toBe(0);
  });

  it('deletes nothing when Mirage refuses to drop the restaurant', async () => {
    const { id, auth } = await makeUser();
    const { catalogId, restaurantId } = await seedPublished(id);

    mirage.failNext({
      method: 'deleteRestaurant',
      status: 500,
      message: 'Error by server (boom)',
    });

    const res = await request(app).delete('/catalog').set(auth).send();

    expect(res.status).toBe(502);
    expect(res.body).toMatchObject({ status: 'error', code: 'MIRAGE_UNAVAILABLE' });

    // The whole point: a failed teardown leaves the user's work exactly where it
    // was, so retrying is the fix and nothing is stranded.
    expect(await Catalog.countDocuments({ _id: catalogId })).toBe(1);
    expect(await CatalogProduct.countDocuments({ catalogId })).toBe(2);
    expect(await CatalogCategory.countDocuments({ catalogId })).toBe(1);
    expect(mirage.restaurants.has(restaurantId)).toBe(true);
  });

  it('treats a restaurant Mirage has already lost as success', async () => {
    const { id, auth } = await makeUser();
    const { catalogId } = await seedPublished(id);

    mirage.failNext({
      method: 'deleteRestaurant',
      status: 404,
      message: 'No restaurant found with given restaurantId (x)',
    });

    const res = await request(app).delete('/catalog').set(auth).send();

    // The end state is the one we were asking for, so refusing here would trap
    // the user with a catalog they can never delete.
    expect(res.status).toBe(200);
    expect(await Catalog.countDocuments({ _id: catalogId })).toBe(0);
  });

  it('refuses while a publish run holds the catalog', async () => {
    const { id, auth } = await makeUser();
    const { catalogId } = await seedPublished(id);

    const runId = new Types.ObjectId();
    await Catalog.updateOne(
      { _id: catalogId },
      { $set: { activePublishRunId: runId } }
    ).exec();

    const res = await request(app).delete('/catalog').set(auth).send();

    expect(res.status).toBe(409);
    expect(res.body).toMatchObject({
      status: 'error',
      code: 'PUBLISH_IN_PROGRESS',
      runId: runId.toHexString(),
    });

    // Nothing touched — the worker is mid-write into Mirage.
    expect(await Catalog.countDocuments({ _id: catalogId })).toBe(1);
    expect(mirage.callsTo('deleteRestaurant')).toHaveLength(0);
  });

  it('is a 404 when the caller has no catalog', async () => {
    const { auth } = await makeUser();

    const res = await request(app).delete('/catalog').set(auth).send();

    expect(res.status).toBe(404);
    expect(res.body).toMatchObject({ code: 'CATALOG_NOT_FOUND' });
  });

  it("never touches another user's catalog", async () => {
    const owner = await makeUser();
    const stranger = await makeUser();
    const { catalogId } = await seedPublished(owner.id);

    const res = await request(app).delete('/catalog').set(stranger.auth).send();

    // Enumeration-safe: the stranger simply has no catalog of their own.
    expect(res.status).toBe(404);
    expect(await Catalog.countDocuments({ _id: catalogId })).toBe(1);
    expect(mirage.calls).toHaveLength(0);
  });

  it('requires authentication', async () => {
    const res = await request(app).delete('/catalog').send();
    expect(res.status).toBe(401);
  });
});
