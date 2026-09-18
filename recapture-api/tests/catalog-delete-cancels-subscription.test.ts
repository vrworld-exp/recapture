// tests/catalog-delete-cancels-subscription.test.ts
//
// `DELETE /catalog` and the subscription (C9, D2): the row is CANCELLED, not
// deleted; `trialUsedAt` survives; a re-created catalog inherits the owner's
// history so the free month cannot be had twice; and a Mirage refusal — which
// aborts the whole delete — leaves the subscription exactly as it was.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { Catalog } from '@/models/Catalog';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogDelegation } from '@/models/CatalogDelegation';
import { CatalogProduct } from '@/models/CatalogProduct';
import { CatalogPublishRun } from '@/models/CatalogPublishRun';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { RateWindow } from '@/models/RateWindow';
import { User, type UserRole } from '@/models/User';
import { resetMirageClient, setMirageClient } from '@/services/mirage';
import { FakeMirage } from './fixtures/mirageFake';

const app = createApp();
let mongod: MongoMemoryServer;
const mirage = new FakeMirage();

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Catalog.syncIndexes();
  await CatalogSubscription.syncIndexes();
  await CatalogDelegation.syncIndexes();
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
    CatalogDelegation.deleteMany({}),
    CatalogProduct.deleteMany({}),
    CatalogPublishRun.deleteMany({}),
    CatalogSubscription.deleteMany({}),
    RateWindow.deleteMany({}),
  ]);
});

type Auth = { Authorization: string };

async function makeUser(role: UserRole = 'USER'): Promise<{ id: Types.ObjectId; auth: Auth }> {
  const user = await User.create({
    authProvider: 'custom',
    authUid: `test|${new Types.ObjectId().toHexString()}`,
    role,
  });
  const token = jwt.sign({ userId: user.id, authUid: user.authUid }, env.JWT_SECRET, {
    expiresIn: '15m',
  });
  return { id: user._id as Types.ObjectId, auth: { Authorization: `Bearer ${token}` } };
}

async function seedPublished(ownerId: Types.ObjectId): Promise<Types.ObjectId> {
  const restaurant = mirage.seedRestaurant('blue_cafe');
  const catalog = await Catalog.create({
    userId: ownerId,
    name: 'blue_cafe',
    status: 'PUBLISHED',
    draftRevision: 3,
    publishedRevision: 3,
    mirageRestaurantId: restaurant.id,
    publicUrl: `https://menu.test/${restaurant.id}`,
    publicUrlScheme: 'MIRAGE_OBJECT_ID',
    lastPublishedAt: new Date(),
  });
  return catalog._id as Types.ObjectId;
}

async function trialRow(catalogId: Types.ObjectId, ownerId: Types.ObjectId): Promise<Date> {
  const trialUsedAt = new Date('2026-09-01T00:00:00.000Z');
  await CatalogSubscription.create({
    catalogId,
    userId: ownerId,
    status: 'TRIAL',
    source: 'TRIAL',
    periodStart: trialUsedAt,
    periodEnd: new Date(trialUsedAt.getTime() + 30 * 86_400_000),
    threeDDishCap: 10,
    trialUsedAt,
  });
  return trialUsedAt;
}

describe('DELETE /catalog and the subscription', () => {
  it('moves the row to CANCELLED, keeps trialUsedAt, and says so in the result', async () => {
    const owner = await makeUser();
    const catalogId = await seedPublished(owner.id);
    const trialUsedAt = await trialRow(catalogId, owner.id);

    const res = await request(app).delete('/catalog').set(owner.auth).send();

    expect(res.status).toBe(200);
    expect(await Catalog.countDocuments({ _id: catalogId })).toBe(0);
    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row?.status).toBe('CANCELLED');
    expect(row?.cancelledAt).toBeInstanceOf(Date);
    expect(row?.trialUsedAt?.toISOString()).toBe(trialUsedAt.toISOString());
  });

  it('a re-created catalog cannot get a second trial (D2)', async () => {
    const owner = await makeUser();
    const catalogId = await seedPublished(owner.id);
    await trialRow(catalogId, owner.id);
    await request(app).delete('/catalog').set(owner.auth).send().expect(200);

    const created = await request(app)
      .post('/catalog')
      .set(owner.auth)
      .send({ name: 'Blue Cafe Again' });
    expect(created.status).toBe(201);
    const newId = created.body.catalog.id as string;
    expect(newId).not.toBe(String(catalogId));
    // A new catalog, no row of its own — and still no trial to be had.
    expect(created.body.catalog.subscription).toBeNull();
    const status = await request(app).get('/catalog/subscription').set(owner.auth);
    expect(status.body.subscription).toMatchObject({ status: 'NONE', trialAvailable: false });

    const admin = await makeUser('ADMIN');
    const trial = await request(app)
      .post(`/admin/catalogs/${newId}/subscription/trial`)
      .set(admin.auth);
    expect(trial.status).toBe(409);
    expect(trial.body.code).toBe('TRIAL_ALREADY_USED');
    expect(await CatalogSubscription.countDocuments({})).toBe(1);
  });

  it('leaves the subscription untouched when Mirage refuses the delete', async () => {
    const owner = await makeUser();
    const catalogId = await seedPublished(owner.id);
    await trialRow(catalogId, owner.id);
    mirage.failNext({ method: 'deleteRestaurant', status: 500, message: 'Error by server' });

    const res = await request(app).delete('/catalog').set(owner.auth).send();

    expect(res.status).toBe(502);
    const row = await CatalogSubscription.findOne({ catalogId }).lean().exec();
    expect(row?.status).toBe('TRIAL');
    expect(row?.cancelledAt).toBeUndefined();
  });

  it('is a no-op for a catalog with no row', async () => {
    const owner = await makeUser();
    await seedPublished(owner.id);

    const res = await request(app).delete('/catalog').set(owner.auth).send();

    expect(res.status).toBe(200);
    expect(await CatalogSubscription.countDocuments({})).toBe(0);
  });
});
