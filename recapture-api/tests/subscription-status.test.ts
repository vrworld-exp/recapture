// tests/subscription-status.test.ts
//
// The subscription as the screens read it: the DTO's arithmetic (daysLeft is
// SERVER-computed, D6), the usage numbers (the same list the publish gate
// counts, C1), the compact summary on GET /catalog and the rep list (one query
// for the whole list), and the owner/rep bodies being payload-equal.
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
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { ClientConfig } from '@/models/ClientConfig';
import { PaymentRecord } from '@/models/PaymentRecord';
import { User, type UserRole } from '@/models/User';
import { DEFAULT_PLAN_CATALOG } from '@/config/subscriptionPlans';
import { UNCAPPED_THREE_D, type SubscriptionStatus } from '@/models/types/subscription.types';
import {
  getSubscriptionStatus,
  getSubscriptionSummaries,
  getSubscriptionSummary,
} from '@/services/subscription/subscriptionService';

const app = createApp();
let mongod: MongoMemoryServer;

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
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
});

afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all([
    User.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogCategory.deleteMany({}),
    CatalogDelegation.deleteMany({}),
    CatalogProduct.deleteMany({}),
    CatalogSubscription.deleteMany({}),
    ClientConfig.deleteMany({}),
    PaymentRecord.deleteMany({}),
  ]);
});

const NOW = new Date('2026-09-18T12:00:00.000Z');
const DAY_MS = 86_400_000;
const GLB = 'https://test.cloudfront.net/dev/p/model.glb';

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

async function seedCatalog(ownerId: Types.ObjectId): Promise<Types.ObjectId> {
  const catalog = await Catalog.create({
    userId: ownerId,
    name: `cafe_${new Types.ObjectId().toHexString()}`,
    status: 'DRAFT',
  });
  return catalog._id as Types.ObjectId;
}

async function seedDishes(
  catalogId: Types.ObjectId,
  ownerId: Types.ObjectId,
  specs: Record<string, unknown>[]
): Promise<void> {
  const category = await CatalogCategory.create({
    catalogId,
    userId: ownerId,
    name: 'menu',
    position: 0,
  });
  await CatalogProduct.create(
    specs.map((spec, index) => ({
      catalogId,
      userId: ownerId,
      categoryId: category._id,
      name: `dish_${index}`,
      position: index,
      ...spec,
    }))
  );
}

async function row(
  catalogId: Types.ObjectId,
  ownerId: Types.ObjectId,
  status: SubscriptionStatus,
  overrides: Record<string, unknown> = {}
): Promise<void> {
  await CatalogSubscription.create({
    catalogId,
    userId: ownerId,
    status,
    source: 'ONLINE',
    periodStart: new Date(NOW.getTime() - 20 * DAY_MS),
    periodEnd: new Date(NOW.getTime() + 10 * DAY_MS),
    threeDDishCap: 15,
    ...overrides,
  });
}

describe('getSubscriptionStatus — the DTO', () => {
  it('answers NONE, with usage and plans, for a catalog with no row', async () => {
    const owner = await makeUser();
    const catalogId = await seedCatalog(owner.id);
    await seedDishes(catalogId, owner.id, [
      { type: 'THREE_D', assets: { glbUrl: GLB, thumbnailUrl: 't' } },
      { type: 'IMAGE_ONLY', assets: { imageKey: 'a.jpg' } },
    ]);

    const dto = await getSubscriptionStatus(catalogId, owner.id, NOW);

    expect(dto).toEqual({
      status: 'NONE',
      planId: null,
      planName: null,
      planSnapshot: null,
      billingInterval: null,
      periodEnd: null,
      graceEndsAt: null,
      daysLeft: null,
      threeDDishCount: 1,
      threeDDishCap: null,
      imageDishCount: 1,
      trialAvailable: true,
      isEntitledTo3D: false,
      standeeAllocation: null,
      plans: DEFAULT_PLAN_CATALOG,
    });
  });

  it('computes daysLeft as ceil((periodEnd - now) / day), never below 0', async () => {
    const owner = await makeUser();
    const catalogId = await seedCatalog(owner.id);
    await row(catalogId, owner.id, 'ACTIVE', {
      planId: 'SIGNATURE',
      planSnapshot: DEFAULT_PLAN_CATALOG.plans.SIGNATURE,
      billingInterval: 'MONTHLY',
      periodEnd: new Date(NOW.getTime() + 2.5 * DAY_MS),
    });

    const dto = await getSubscriptionStatus(catalogId, owner.id, NOW);
    expect(dto.daysLeft).toBe(3);
    expect(dto.planName).toBe('Signature plan');
    expect(dto.threeDDishCap).toBe(15);
    expect(dto.isEntitledTo3D).toBe(true);
    // A live row cannot take a trial, whatever its history.
    expect(dto.trialAvailable).toBe(false);

    // The period ended and the sweep (Stage 5) has not run: 0, and the stored
    // status is reported as stored — no client-side inference.
    await CatalogSubscription.updateOne(
      { catalogId },
      { $set: { periodEnd: new Date(NOW.getTime() - 3 * DAY_MS) } }
    );
    const lapsed = await getSubscriptionStatus(catalogId, owner.id, NOW);
    expect(lapsed.daysLeft).toBe(0);
    expect(lapsed.status).toBe('ACTIVE');
  });

  it('in GRACE counts down to graceEndsAt, not to the period that already ended', async () => {
    const owner = await makeUser();
    const catalogId = await seedCatalog(owner.id);
    await row(catalogId, owner.id, 'GRACE', {
      periodEnd: new Date(NOW.getTime() - 2 * DAY_MS),
      graceEndsAt: new Date(NOW.getTime() + 5 * DAY_MS),
    });

    const dto = await getSubscriptionStatus(catalogId, owner.id, NOW);
    expect(dto.daysLeft).toBe(5);
    expect(dto.graceEndsAt).toBe(new Date(NOW.getTime() + 5 * DAY_MS).toISOString());
    expect(dto.isEntitledTo3D).toBe(true);
  });

  it('PAUSED and CANCELLED count down to nothing, and are not entitled to 3D', async () => {
    for (const status of ['PAUSED', 'CANCELLED'] as const) {
      const owner = await makeUser();
      const catalogId = await seedCatalog(owner.id);
      await row(catalogId, owner.id, status);
      const dto = await getSubscriptionStatus(catalogId, owner.id, NOW);
      expect(dto.daysLeft).toBeNull();
      expect(dto.isEntitledTo3D).toBe(false);
      // Lapsed, never trialled, never paid → a trial is still on the table.
      expect(dto.trialAvailable).toBe(true);
    }
  });

  it('reports a comp as uncapped (null), not as -1', async () => {
    const owner = await makeUser();
    const catalogId = await seedCatalog(owner.id);
    await row(catalogId, owner.id, 'COMPED', { source: 'COMP', threeDDishCap: UNCAPPED_THREE_D });
    const dto = await getSubscriptionStatus(catalogId, owner.id, NOW);
    expect(dto.threeDDishCap).toBeNull();
  });

  it('counts 3D usage over the publishable list — the list the gate counts', async () => {
    const owner = await makeUser();
    const catalogId = await seedCatalog(owner.id);
    await seedDishes(catalogId, owner.id, [
      { type: 'THREE_D', assets: { glbUrl: GLB, thumbnailUrl: 't' } },
      { type: 'THREE_D', assets: { glbUrl: GLB, thumbnailUrl: 't' }, modelStatus: 'READY' },
      // A replacement generating: publishes, is not 3D for the cap.
      { type: 'THREE_D', assets: { glbUrl: GLB, thumbnailUrl: 't' }, modelStatus: 'PROCESSING' },
      // Awaiting its first model: not published at all, so neither count.
      { type: 'THREE_D', modelStatus: 'QUEUED' },
      // Archived: out of both.
      { type: 'THREE_D', assets: { glbUrl: GLB }, archivedAt: NOW },
      { type: 'IMAGE_ONLY', assets: { imageKey: 'a.jpg' } },
    ]);

    const dto = await getSubscriptionStatus(catalogId, owner.id, NOW);
    expect(dto.threeDDishCount).toBe(2);
    // The generating replacement is a photo dish for now (§3b).
    expect(dto.imageDishCount).toBe(2);
  });

  it('trialAvailable is false once the owner has used a trial anywhere, or has paid', async () => {
    const owner = await makeUser();
    const catalogId = await seedCatalog(owner.id);
    // A trial on a catalog the owner has since deleted (the row outlives it).
    await CatalogSubscription.create({
      catalogId: new Types.ObjectId(),
      userId: owner.id,
      status: 'CANCELLED',
      source: 'TRIAL',
      periodStart: NOW,
      periodEnd: NOW,
      threeDDishCap: 10,
      trialUsedAt: NOW,
    });
    expect((await getSubscriptionStatus(catalogId, owner.id, NOW)).trialAvailable).toBe(false);

    const payer = await makeUser();
    const paidCatalog = await seedCatalog(payer.id);
    await PaymentRecord.create({
      catalogId: paidCatalog,
      userId: payer.id,
      subscriptionId: new Types.ObjectId(),
      kind: 'PAID',
      amountPaise: 119_900,
      initiatedBy: { userId: payer.id, role: 'USER' },
    });
    expect((await getSubscriptionStatus(paidCatalog, payer.id, NOW)).trialAvailable).toBe(false);
  });
});

describe('the compact summary', () => {
  it('is null for a catalog with no row, and carries the five fields otherwise', async () => {
    const owner = await makeUser();
    const catalogId = await seedCatalog(owner.id);
    expect(await getSubscriptionSummary(catalogId, owner.id, NOW)).toBeNull();

    await row(catalogId, owner.id, 'TRIAL', {
      source: 'TRIAL',
      threeDDishCap: 10,
      trialUsedAt: NOW,
      periodEnd: new Date(NOW.getTime() + 12 * DAY_MS),
    });
    expect(await getSubscriptionSummary(catalogId, owner.id, NOW)).toEqual({
      status: 'TRIAL',
      daysLeft: 12,
      planId: null,
      isEntitledTo3D: true,
      trialAvailable: false,
    });
  });

  it('resolves a whole list with ONE subscription query', async () => {
    // One catalog per user, so thirty catalogs is thirty owners.
    const owners: Types.ObjectId[] = [];
    const ids: Types.ObjectId[] = [];
    for (let i = 0; i < 30; i++) {
      const owner = await makeUser();
      owners.push(owner.id);
      ids.push(await seedCatalog(owner.id));
    }
    for (let i = 0; i < 20; i++) await row(ids[i]!, owners[i]!, 'ACTIVE');

    const find = vi.spyOn(CatalogSubscription, 'find');
    const summaries = await getSubscriptionSummaries(
      ids.map((catalogId, i) => ({ catalogId, ownerUserId: owners[i]! })),
      NOW
    );

    expect(find).toHaveBeenCalledTimes(1);
    expect(summaries.size).toBe(20);
    expect(summaries.get(String(ids[0]))?.status).toBe('ACTIVE');
    expect(summaries.has(String(ids[29]))).toBe(false);
  });
});

describe('over the wire', () => {
  it('GET /catalog carries subscription: null for a new catalog (AC-2.1)', async () => {
    const owner = await makeUser();
    const created = await request(app).post('/catalog').set(owner.auth).send({ name: 'Blue Cafe' });
    expect(created.status).toBe(201);
    expect(created.body.catalog.subscription).toBeNull();

    const res = await request(app).get('/catalog').set(owner.auth);
    expect(res.status).toBe(200);
    expect(res.body.catalog.subscription).toBeNull();
    expect(await CatalogSubscription.countDocuments({})).toBe(0);
  });

  it('GET /catalog carries the summary once a row exists', async () => {
    const owner = await makeUser();
    const catalogId = await seedCatalog(owner.id);
    await row(catalogId, owner.id, 'ACTIVE', { planId: 'TASTE' });

    const res = await request(app).get('/catalog').set(owner.auth);
    expect(res.body.catalog.subscription).toMatchObject({
      status: 'ACTIVE',
      planId: 'TASTE',
      isEntitledTo3D: true,
      trialAvailable: false,
    });
    expect(typeof res.body.catalog.subscription.daysLeft).toBe('number');
  });

  it('owner and rep read PAYLOAD-EQUAL subscription bodies for one catalog', async () => {
    const owner = await makeUser();
    const rep = await makeUser('SALES_REP');
    const catalogId = await seedCatalog(owner.id);
    await CatalogDelegation.create({
      repUserId: rep.id,
      catalogId,
      grantedAt: new Date(),
      revokedAt: null,
    });
    await row(catalogId, owner.id, 'TRIAL', { source: 'TRIAL', threeDDishCap: 10, trialUsedAt: NOW });
    await seedDishes(catalogId, owner.id, [
      { type: 'THREE_D', assets: { glbUrl: GLB, thumbnailUrl: 't' } },
    ]);

    const ownerRes = await request(app).get('/catalog/subscription').set(owner.auth);
    const repRes = await request(app).get(`/rep/catalogs/${catalogId}/subscription`).set(rep.auth);

    expect(ownerRes.status).toBe(200);
    expect(repRes.status).toBe(200);
    // The DTO is identical; the rep's body carries ONE extra sibling, the
    // nudge cooldown (stage-04), which the owner's route never has.
    expect(repRes.body.subscription).toEqual(ownerRes.body.subscription);
    expect(repRes.body).toEqual({ ...ownerRes.body, nudge: { nextAllowedAt: null } });
    expect(ownerRes.body).not.toHaveProperty('nudge');
    expect(ownerRes.body.subscription).toMatchObject({
      status: 'TRIAL',
      threeDDishCount: 1,
      threeDDishCap: 10,
    });
    expect(ownerRes.body.subscription.plans.plans.MASTERCHEF.priceMonthlyPaise).toBe(249_900);
  });

  it('a rep without a delegation gets the same 404 as a nonexistent catalog', async () => {
    const owner = await makeUser();
    const rep = await makeUser('SALES_REP');
    const catalogId = await seedCatalog(owner.id);

    const notMine = await request(app).get(`/rep/catalogs/${catalogId}/subscription`).set(rep.auth);
    const notThere = await request(app)
      .get(`/rep/catalogs/${new Types.ObjectId().toHexString()}/subscription`)
      .set(rep.auth);

    expect(notMine.status).toBe(404);
    expect(notMine.body).toEqual(notThere.body);
    expect(notMine.body.code).toBe('CATALOG_NOT_FOUND');
  });

  it('GET /rep/catalogs decorates every row with its summary in one subscription query', async () => {
    const rep = await makeUser('SALES_REP');
    const ids: Types.ObjectId[] = [];
    const owners: Types.ObjectId[] = [];
    for (let i = 0; i < 30; i++) {
      const owner = await makeUser();
      owners.push(owner.id);
      const id = await seedCatalog(owner.id);
      ids.push(id);
      await CatalogDelegation.create({
        repUserId: rep.id,
        catalogId: id,
        grantedAt: new Date(NOW.getTime() + i * 1000),
        revokedAt: null,
      });
    }
    await row(ids[0]!, owners[0]!, 'TRIAL', {
      source: 'TRIAL',
      threeDDishCap: 10,
      trialUsedAt: NOW,
      periodEnd: new Date(Date.now() + 12 * DAY_MS + 60_000),
    });

    const find = vi.spyOn(CatalogSubscription, 'find');
    const res = await request(app).get('/rep/catalogs').set(rep.auth);

    expect(res.status).toBe(200);
    expect(res.body.catalogs).toHaveLength(30);
    expect(find).toHaveBeenCalledTimes(1);
    const first = res.body.catalogs.find((c: { id: string }) => c.id === String(ids[0]));
    expect(first.subscription).toMatchObject({ status: 'TRIAL', daysLeft: 13 });
    const bare = res.body.catalogs.find((c: { id: string }) => c.id === String(ids[1]));
    expect(bare.subscription).toBeNull();
  });

  it('GET /catalog/subscription answers the no-catalog 404', async () => {
    const owner = await makeUser();
    const res = await request(app).get('/catalog/subscription').set(owner.auth);
    expect(res.status).toBe(404);
    expect(res.body.code).toBe('CATALOG_NOT_FOUND');
  });
});
