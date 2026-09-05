// tests/catalog-unpublish.test.ts
//
// POST /catalog/unpublish — feature 39.
//
// THE ONE THING THIS SUITE GUARDS: the Mirage restaurant survives. Its `_id` is
// what the public URL is built from and what every printed QR encodes, so
// `delete-restaurant` would turn a business's stickers into dead links with no
// way back. Unpublish therefore removes the ITEMS and flips `isPublished`, and
// republishing restores the same page at the same URL.
//
// If a future change makes `deleteRestaurant` reachable from this endpoint, the
// first assertion below is what should fail.
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
  await Catalog.syncIndexes();
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
    mongoose.connection.collection('ratewindows').deleteMany({}),
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

/** A catalog that has already been published once. */
async function seedPublished(userId: string): Promise<{
  catalogId: Types.ObjectId;
  restaurantId: string;
  publicUrl: string;
}> {
  const restaurant = mirage.seedRestaurant('blue_cafe');
  const publicUrl = `https://menu.test/${restaurant.id}`;
  const catalog = await Catalog.create({
    userId: new Types.ObjectId(userId),
    name: 'Blue Cafe',
    status: 'PUBLISHED',
    draftRevision: 2,
    publishedRevision: 2,
    mirageRestaurantId: restaurant.id,
    publicUrl,
    publicUrlScheme: 'MIRAGE_OBJECT_ID',
    lastPublishedAt: new Date(),
  });
  const catalogId = catalog._id as Types.ObjectId;

  await CatalogProduct.create({
    catalogId,
    userId: new Types.ObjectId(userId),
    type: 'IMAGE_ONLY',
    name: 'Chair',
    position: 0,
    assets: { imageKey: 'dev/catalog/x/products/p/0.jpg' },
    mirageItemId: 'mi-1',
    syncStatus: 'SYNCED',
  });

  return { catalogId, restaurantId: restaurant.id, publicUrl };
}

describe('POST /catalog/unpublish', () => {
  it('keeps the restaurant, the URL and the QR, and queues an UNPUBLISH run', async () => {
    const { id, auth } = await makeUser();
    const { catalogId, restaurantId, publicUrl } = await seedPublished(id);

    const res = await request(app).post('/catalog/unpublish').set(auth).send({});

    expect(res.status).toBe(202);
    expect(res.body).toMatchObject({ status: 'success', unpublished: true });

    // The restaurant document — and therefore the ObjectId every printed QR
    // resolves through — is untouched.
    expect(mirage.restaurants.has(restaurantId)).toBe(true);
    expect(mirage.callsTo('deleteRestaurant')).toHaveLength(0);

    const catalog = await Catalog.findById(catalogId).lean().exec();
    expect(catalog?.status).toBe('UNPUBLISHED');
    expect(catalog?.mirageRestaurantId).toBe(restaurantId);
    expect(catalog?.publicUrl).toBe(publicUrl);

    const job = await Job.findOne({ jobType: 'MIRAGE_CATALOG_PUBLISH' }).lean().exec();
    expect(job?.payload).toMatchObject({ mode: 'UNPUBLISH' });
  });

  it('flips the restaurant’s isPublished so the page goes dark immediately', async () => {
    const { id, auth } = await makeUser();
    const { restaurantId } = await seedPublished(id);

    await request(app).post('/catalog/unpublish').set(auth).send({});

    expect(mirage.restaurants.get(restaurantId)?.isPublished).toBe(false);
  });

  it('is a no-op success on a DRAFT catalog, with no Mirage call', async () => {
    const { id, auth } = await makeUser();
    await Catalog.create({
      userId: new Types.ObjectId(id),
      name: 'Blue Cafe',
      status: 'DRAFT',
      draftRevision: 0,
      publishedRevision: -1,
    });

    const res = await request(app).post('/catalog/unpublish').set(auth).send({});

    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ status: 'success', unpublished: false, runId: null });
    expect(mirage.calls).toHaveLength(0);
    expect(await Job.countDocuments({})).toBe(0);
  });

  it('gets 409 while a publish is already running', async () => {
    const { id, auth } = await makeUser();
    const { catalogId } = await seedPublished(id);
    await Catalog.updateOne(
      { _id: catalogId },
      { $set: { activePublishRunId: new Types.ObjectId() } }
    ).exec();

    const res = await request(app).post('/catalog/unpublish').set(auth).send({});

    expect(res.status).toBe(409);
    expect(res.body.code).toBe('PUBLISH_IN_PROGRESS');
  });

  it('proceeds with the item removal even when Mirage refuses the flag', async () => {
    const { id, auth } = await makeUser();
    const { catalogId } = await seedPublished(id);
    mirage.failNext({ method: 'updateRestaurant', status: 400, message: 'Restaurant not found' });

    const res = await request(app).post('/catalog/unpublish').set(auth).send({});

    // Taking the items down is the substantive half; a refused soft switch must
    // not leave the catalog live AND unremovable.
    expect(res.status).toBe(202);
    expect((await Catalog.findById(catalogId).lean().exec())?.status).toBe('UNPUBLISHED');
  });

  it('gives another user’s catalog the same 404 as a nonexistent one', async () => {
    const { auth } = await makeUser();
    const stranger = await makeUser();
    await seedPublished(stranger.id);

    const res = await request(app).post('/catalog/unpublish').set(auth).send({});

    expect(res.status).toBe(404);
    expect(res.body.code).toBe('CATALOG_NOT_FOUND');
  });
});

describe('republishing after an unpublish', () => {
  it('reuses the same public URL', async () => {
    const { id, auth } = await makeUser();
    const { catalogId, publicUrl } = await seedPublished(id);

    await request(app).post('/catalog/unpublish').set(auth).send({});
    await Catalog.updateOne({ _id: catalogId }, { $set: { activePublishRunId: null } }).exec();

    const res = await request(app).post('/catalog/publish').set(auth).send({});

    expect(res.status).toBe(202);
    const catalog = await Catalog.findById(catalogId).lean().exec();
    expect(catalog?.publicUrl).toBe(publicUrl);
    // Provisioning is idempotent: an already-mapped catalog makes NO Mirage
    // call at all, so there is nothing that could mint a second restaurant.
    expect(mirage.callsTo('createRestaurant')).toHaveLength(0);
  });
});
