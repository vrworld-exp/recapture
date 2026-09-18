// tests/subscription-gate.test.ts
//
// The subscription publish gates (§5): the pure rule table, the ops switch
// that keeps them off until Stage 5, and the wiring into POST /catalog/publish.
//
// The two properties this file most exists to pin:
//   • WITH THE FLAG ABSENT, NOTHING CHANGES. Every catalog that published
//     yesterday publishes today; the subscription collection is never read.
//   • A CONFIG OUTAGE IS "OFF", NOT "NO SUBSCRIPTION". The gate fails open —
//     an unreadable store must not invent a paywall across the fleet.
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
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { ClientConfig } from '@/models/ClientConfig';
import { Job } from '@/models/Job';
import { User } from '@/models/User';
import { DEFAULT_PLAN_CATALOG } from '@/config/subscriptionPlans';
import { UNCAPPED_THREE_D, type SubscriptionStatus } from '@/models/types/subscription.types';
import { PublishGateCode, type PublishGate } from '@/services/catalogPublishService';
import { resetMirageClient, setMirageClient } from '@/services/mirage';
import {
  evaluateSubscriptionGate,
  isSubscriptionGateEnabled,
  SUBSCRIPTION_GATES_FLAG_KEY,
  type SubscriptionGateSubscription,
} from '@/services/subscription/subscriptionGate';
import { FakeMirage } from './fixtures/mirageFake';

// ── The pure rule table ─────────────────────────────────────────────────────

function sub(
  status: SubscriptionStatus,
  threeDDishCap: number,
  plan?: 'TASTE' | 'SIGNATURE' | 'MASTERCHEF'
): SubscriptionGateSubscription {
  return {
    status,
    threeDDishCap,
    ...(plan ? { planId: plan, planSnapshot: DEFAULT_PLAN_CATALOG.plans[plan] } : {}),
  };
}

function codes(gates: PublishGate[]): string[] {
  return gates.map((g) => g.code);
}

describe('evaluateSubscriptionGate', () => {
  it('blocks a catalog with no subscription, whatever the menu holds', () => {
    expect(codes(evaluateSubscriptionGate({ subscription: null, threeDDishCount: 0 }))).toEqual([
      'SUBSCRIPTION_REQUIRED',
    ]);
    const gates = evaluateSubscriptionGate({ subscription: null, threeDDishCount: 5 });
    expect(codes(gates)).toEqual(['SUBSCRIPTION_REQUIRED']);
    expect(gates[0]?.message).toBe(
      'No subscription yet — start a free trial or activate a plan to publish.'
    );
  });

  it('PAUSED / CANCELLED: blocks a 3D menu, lets a photo-only menu through (C5)', () => {
    for (const status of ['PAUSED', 'CANCELLED'] as const) {
      const blocked = evaluateSubscriptionGate({
        subscription: sub(status, 15, 'SIGNATURE'),
        threeDDishCount: 1,
      });
      expect(codes(blocked)).toEqual(['SUBSCRIPTION_REQUIRED']);
      expect(blocked[0]?.message).toBe(
        'Your 3D menu needs an active plan. Photo-only menus can still be published.'
      );

      expect(
        evaluateSubscriptionGate({ subscription: sub(status, 15, 'SIGNATURE'), threeDDishCount: 0 })
      ).toEqual([]);
    }
  });

  it('ACTIVE over the cap → CAPACITY_EXCEEDED with the plan name and the numbers', () => {
    const gates = evaluateSubscriptionGate({
      subscription: sub('ACTIVE', 15, 'SIGNATURE'),
      threeDDishCount: 17,
    });
    expect(gates).toEqual([
      {
        code: 'SUBSCRIPTION_CAPACITY_EXCEEDED',
        message:
          'Menu has 17 3D dishes; your Signature plan covers 15. Upgrade to publish all of them.',
        meta: { threeDDishCount: 17, threeDDishCap: 15, planId: 'SIGNATURE' },
      },
    ]);
  });

  it('ACTIVE at or under the cap → no gate', () => {
    expect(
      evaluateSubscriptionGate({ subscription: sub('ACTIVE', 15, 'SIGNATURE'), threeDDishCount: 15 })
    ).toEqual([]);
    expect(
      evaluateSubscriptionGate({ subscription: sub('ACTIVE', 15, 'SIGNATURE'), threeDDishCount: 0 })
    ).toEqual([]);
  });

  it('TRIAL over the cap says "free trial" and carries no planId', () => {
    const gates = evaluateSubscriptionGate({ subscription: sub('TRIAL', 10), threeDDishCount: 11 });
    expect(gates[0]?.message).toBe(
      'Menu has 11 3D dishes; your free trial covers 10. Upgrade to publish all of them.'
    );
    expect(gates[0]?.meta).toEqual({ threeDDishCount: 11, threeDDishCap: 10 });
  });

  it('GRACE keeps access but not extra capacity — over the cap still blocks', () => {
    expect(
      codes(
        evaluateSubscriptionGate({ subscription: sub('GRACE', 10, 'TASTE'), threeDDishCount: 11 })
      )
    ).toEqual(['SUBSCRIPTION_CAPACITY_EXCEEDED']);
    // And under it, GRACE produces nothing of its own — the banner is Stage 2.
    expect(
      evaluateSubscriptionGate({ subscription: sub('GRACE', 10, 'TASTE'), threeDDishCount: 10 })
    ).toEqual([]);
  });

  it('COMPED (uncapped, -1) never trips CAPACITY_EXCEEDED', () => {
    expect(
      evaluateSubscriptionGate({
        subscription: sub('COMPED', UNCAPPED_THREE_D),
        threeDDishCount: 10_000,
      })
    ).toEqual([]);
  });

  it('returns at most ONE gate', () => {
    for (const status of ['TRIAL', 'ACTIVE', 'GRACE', 'PAUSED', 'CANCELLED', 'COMPED'] as const) {
      for (const count of [0, 1, 100]) {
        expect(
          evaluateSubscriptionGate({ subscription: sub(status, 10, 'TASTE'), threeDDishCount: count })
            .length
        ).toBeLessThanOrEqual(1);
      }
    }
  });
});

// ── The switch and the wiring ───────────────────────────────────────────────

const app = createApp();
let mongod: MongoMemoryServer;
const mirage = new FakeMirage();

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Catalog.syncIndexes();
  await CatalogSubscription.syncIndexes();
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
    CatalogSubscription.deleteMany({}),
    ClientConfig.deleteMany({}),
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

const THREE_D_ASSETS = {
  glbUrl: 'https://test.cloudfront.net/dev/p/model.glb',
  thumbnailUrl: 'https://test.cloudfront.net/dev/p/preview.jpg',
};

/** A publishable catalog: `threeD` READY-model dishes and `photos` image dishes. */
async function seed(userId: string, counts: { threeD: number; photos: number }) {
  const catalog = await Catalog.create({
    userId: new Types.ObjectId(userId),
    // Unique per catalog: Mirage adopts a restaurant by NAME, and two catalogs
    // sharing one would give the second a NAME_TAKEN 409 at provisioning.
    name: `cafe_${new Types.ObjectId().toHexString()}`,
    status: 'DRAFT',
    draftRevision: 1,
    publishedRevision: -1,
  });
  const catalogId = catalog._id as Types.ObjectId;
  const category = await CatalogCategory.create({
    catalogId,
    userId: new Types.ObjectId(userId),
    name: 'menu',
    position: 0,
  });
  const base = { catalogId, userId: new Types.ObjectId(userId), categoryId: category._id };
  const rows = [];
  for (let i = 0; i < counts.threeD; i++) {
    rows.push({ ...base, type: 'THREE_D', name: `dish_${i}`, position: i, assets: THREE_D_ASSETS });
  }
  for (let i = 0; i < counts.photos; i++) {
    rows.push({
      ...base,
      type: 'IMAGE_ONLY',
      name: `photo_${i}`,
      position: counts.threeD + i,
      assets: { imageKey: `dev/catalog/x/products/p/${i}.jpg` },
    });
  }
  await CatalogProduct.create(rows);
  return catalogId;
}

async function flag(value: boolean | undefined): Promise<void> {
  await ClientConfig.deleteMany({});
  if (value !== undefined) await ClientConfig.create({ [SUBSCRIPTION_GATES_FLAG_KEY]: value });
}

async function subscription(
  catalogId: Types.ObjectId,
  status: SubscriptionStatus,
  threeDDishCap: number,
  plan?: 'TASTE' | 'SIGNATURE' | 'MASTERCHEF'
): Promise<void> {
  await CatalogSubscription.create({
    catalogId,
    status,
    source: status === 'TRIAL' ? 'TRIAL' : status === 'COMPED' ? 'COMP' : 'ONLINE',
    periodStart: new Date(),
    periodEnd: new Date(Date.now() + 30 * 86_400_000),
    threeDDishCap,
    ...(plan ? { planId: plan, planSnapshot: DEFAULT_PLAN_CATALOG.plans[plan] } : {}),
  });
}

function subscriptionGates(body: { gates?: PublishGate[] }): PublishGate[] {
  return (body.gates ?? []).filter(
    (g) =>
      g.code === PublishGateCode.SUBSCRIPTION_REQUIRED ||
      g.code === PublishGateCode.SUBSCRIPTION_CAPACITY_EXCEEDED
  );
}

describe('isSubscriptionGateEnabled', () => {
  it('is off when the flag is absent, false, or not a boolean', async () => {
    await flag(undefined);
    expect(await isSubscriptionGateEnabled()).toBe(false);
    await flag(false);
    expect(await isSubscriptionGateEnabled()).toBe(false);
    await ClientConfig.deleteMany({});
    await ClientConfig.create({ [SUBSCRIPTION_GATES_FLAG_KEY]: 'true' });
    expect(await isSubscriptionGateEnabled()).toBe(false);
  });

  it('is on only when the flag is literally true', async () => {
    await flag(true);
    expect(await isSubscriptionGateEnabled()).toBe(true);
  });

  it('fails OPEN when the store throws, and says so', async () => {
    vi.spyOn(ClientConfig, 'findOne').mockImplementationOnce(() => {
      throw new Error('store down');
    });
    expect(await isSubscriptionGateEnabled()).toBe(false);
    const warned = vi.mocked(console.warn).mock.calls.map((c) => String(c[0]));
    expect(warned.some((line) => line.includes('store down'))).toBe(true);
  });
});

describe('POST /catalog/publish with the gates OFF', () => {
  it('publishes a catalog with no subscription row when the flag is absent', async () => {
    const { id, auth } = await makeUser();
    await seed(id, { threeD: 3, photos: 1 });
    await flag(undefined);

    const res = await request(app).post('/catalog/publish').set(auth).send({});

    expect(res.status).toBe(202);
  });

  it('publishes when the flag is explicitly false', async () => {
    const { id, auth } = await makeUser();
    await seed(id, { threeD: 3, photos: 1 });
    await flag(false);

    expect((await request(app).post('/catalog/publish').set(auth).send({})).status).toBe(202);
  });

  it('publishes when the config store is unreadable — an outage is not a paywall', async () => {
    const { id, auth } = await makeUser();
    await seed(id, { threeD: 3, photos: 1 });
    vi.spyOn(ClientConfig, 'findOne').mockImplementation(() => {
      throw new Error('store down');
    });

    const res = await request(app).post('/catalog/publish').set(auth).send({});

    expect(res.status).toBe(202);
  });
});

describe('POST /catalog/publish with the gates ON', () => {
  it('returns 422 with exactly one SUBSCRIPTION_REQUIRED when there is no row', async () => {
    const { id, auth } = await makeUser();
    await seed(id, { threeD: 0, photos: 2 });
    await flag(true);

    const res = await request(app).post('/catalog/publish').set(auth).send({});

    expect(res.status).toBe(422);
    expect(res.body).toMatchObject({ status: 'error', code: 'PUBLISH_BLOCKED' });
    expect(subscriptionGates(res.body).map((g) => g.code)).toEqual(['SUBSCRIPTION_REQUIRED']);
    expect(await CatalogPublishRun.countDocuments({})).toBe(0);
    // Not provisioned: blocked before Mirage, like every other gate.
    expect(mirage.restaurants.size).toBe(0);
  });

  it('keeps the subscription gate LAST, after every other row', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id, { threeD: 1, photos: 0 });
    // Break an existing gate too: a 3D product without its preview image.
    await CatalogProduct.updateMany({ catalogId }, { $unset: { 'assets.thumbnailUrl': 1 } });
    await flag(true);

    const res = await request(app).post('/catalog/publish').set(auth).send({});

    expect(res.status).toBe(422);
    const all = (res.body.gates as PublishGate[]).map((g) => g.code);
    expect(all).toEqual(['PRODUCT_THUMBNAIL_MISSING', 'SUBSCRIPTION_REQUIRED']);
  });

  it('returns CAPACITY_EXCEEDED with meta when 17 READY dishes meet a cap of 15', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id, { threeD: 17, photos: 3 });
    await subscription(catalogId, 'ACTIVE', 15, 'SIGNATURE');
    await flag(true);

    const res = await request(app).post('/catalog/publish').set(auth).send({});

    expect(res.status).toBe(422);
    expect(subscriptionGates(res.body)).toEqual([
      {
        code: 'SUBSCRIPTION_CAPACITY_EXCEEDED',
        message:
          'Menu has 17 3D dishes; your Signature plan covers 15. Upgrade to publish all of them.',
        meta: { threeDDishCount: 17, threeDDishCap: 15, planId: 'SIGNATURE' },
      },
    ]);
  });

  it('does not block a PAUSED catalog whose menu has no 3D dish', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id, { threeD: 0, photos: 4 });
    await subscription(catalogId, 'PAUSED', 10, 'TASTE');
    await flag(true);

    const res = await request(app).post('/catalog/publish').set(auth).send({});

    expect(res.status).toBe(202);
  });

  it('blocks a PAUSED catalog with one 3D dish', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id, { threeD: 1, photos: 4 });
    await subscription(catalogId, 'PAUSED', 10, 'TASTE');
    await flag(true);

    const res = await request(app).post('/catalog/publish').set(auth).send({});

    expect(res.status).toBe(422);
    expect(subscriptionGates(res.body).map((g) => g.code)).toEqual(['SUBSCRIPTION_REQUIRED']);
  });

  it('publishes an ACTIVE catalog within its cap, and a COMPED one with any count', async () => {
    const active = await makeUser();
    await subscription(await seed(active.id, { threeD: 15, photos: 0 }), 'ACTIVE', 15, 'SIGNATURE');
    await flag(true);
    expect(
      (await request(app).post('/catalog/publish').set(active.auth).send({})).status
    ).toBe(202);

    const comped = await makeUser();
    await subscription(await seed(comped.id, { threeD: 40, photos: 0 }), 'COMPED', UNCAPPED_THREE_D);
    expect(
      (await request(app).post('/catalog/publish').set(comped.auth).send({})).status
    ).toBe(202);
  });

  it('surfaces the same gate on GET /catalog/publish/status', async () => {
    const { id, auth } = await makeUser();
    await seed(id, { threeD: 1, photos: 0 });
    await flag(true);

    const res = await request(app).get('/catalog/publish/status').set(auth);

    expect(res.status).toBe(200);
    expect(subscriptionGates(res.body.publish).map((g) => g.code)).toEqual([
      'SUBSCRIPTION_REQUIRED',
    ]);
  });
});

describe('publish_blocked_by_subscription', () => {
  function emitted(): Record<string, unknown>[] {
    return vi
      .mocked(console.log)
      .mock.calls.filter((c) => String(c[0]).includes('[analytics] publish_blocked_by_subscription'))
      .map((c) => JSON.parse(String(c[1])) as Record<string, unknown>);
  }

  it('fires once per subscription gate on a publish ATTEMPT, with the numbers', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id, { threeD: 17, photos: 0 });
    await subscription(catalogId, 'ACTIVE', 15, 'SIGNATURE');
    await flag(true);

    await request(app).post('/catalog/publish').set(auth).send({});

    expect(emitted()).toEqual([
      {
        catalog_id: catalogId.toHexString(),
        gate: 'SUBSCRIPTION_CAPACITY_EXCEEDED',
        subscription_status: 'ACTIVE',
        three_d_dish_count: 17,
        three_d_dish_cap: 15,
      },
    ]);
  });

  it('reports NONE and -1 for a catalog with no row', async () => {
    const { id, auth } = await makeUser();
    await seed(id, { threeD: 2, photos: 0 });
    await flag(true);

    await request(app).post('/catalog/publish').set(auth).send({});

    expect(emitted()).toMatchObject([
      { gate: 'SUBSCRIPTION_REQUIRED', subscription_status: 'NONE', three_d_dish_cap: -1 },
    ]);
  });

  it('does NOT fire on the status poll, which runs the same gates', async () => {
    const { id, auth } = await makeUser();
    await seed(id, { threeD: 2, photos: 0 });
    await flag(true);

    await request(app).get('/catalog/publish/status').set(auth);
    await request(app).get('/catalog/publish/status').set(auth);

    expect(emitted()).toEqual([]);
  });

  it('does not fire when the publish is blocked by something else', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id, { threeD: 1, photos: 0 });
    await subscription(catalogId, 'ACTIVE', 15, 'SIGNATURE');
    await CatalogProduct.updateMany({ catalogId }, { $unset: { 'assets.thumbnailUrl': 1 } });
    await flag(true);

    const res = await request(app).post('/catalog/publish').set(auth).send({});

    expect(res.status).toBe(422);
    expect(emitted()).toEqual([]);
  });
});
