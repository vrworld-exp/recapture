// tests/admin-publish-unpublish.test.ts
//
// "Publish by admin" and "Unpublish by admin" — the two ADMIN buttons at the
// foot of the publish screen (Oct 2026).
//
// What this suite pins, in order of how much a mistake would cost:
//   • ONLY an ADMIN reaches either route — a rep holding the restaurant gets
//     403, not a softer door into the same thing.
//   • An admin publish lifts the SUBSCRIPTION gate and nothing else: an unpaid
//     restaurant publishes, an empty menu still does not.
//   • An admin takedown keeps the restaurant, its URL and every printed QR
//     (the feature-39 guarantee), records the reason, tells the owner, and the
//     next accepted publish clears the reason.
//   • A republish after ANY unpublish switches the page back on — the bug that
//     used to leave a "successful" republish showing a 404.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { Catalog } from '@/models/Catalog';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogDelegation } from '@/models/CatalogDelegation';
import { CatalogProduct } from '@/models/CatalogProduct';
import { CatalogPublishRun } from '@/models/CatalogPublishRun';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { ClientConfig } from '@/models/ClientConfig';
import { Job } from '@/models/Job';
import { Notification } from '@/models/Notification';
import { RateWindow } from '@/models/RateWindow';
import { User } from '@/models/User';
import { syncCatalogBranding } from '@/services/catalogProvisioningService';
import { resetMirageClient, setMirageClient } from '@/services/mirage';
import { SUBSCRIPTION_GATES_FLAG_KEY } from '@/services/subscription/subscriptionGate';
import { FakeMirage } from './fixtures/mirageFake';
import { makeUser, seedSubscription } from './helpers/subscriptionPayments';

const app = createApp();
let mongod: MongoMemoryServer;
const mirage = new FakeMirage();

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Promise.all([
    Catalog.syncIndexes(),
    CatalogDelegation.syncIndexes(),
    CatalogSubscription.syncIndexes(),
  ]);
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
  vi.spyOn(console, 'error').mockImplementation(() => {});
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
    ClientConfig.deleteMany({}),
    Job.deleteMany({}),
    Notification.deleteMany({}),
    RateWindow.deleteMany({}),
  ]);
});

/** A provisioned catalog with one publishable dish. */
async function seedCatalog(
  status: 'PUBLISHED' | 'UNPUBLISHED' | 'DRAFT' = 'PUBLISHED',
  extra: Record<string, unknown> = {}
) {
  const owner = await makeUser();
  const restaurant = mirage.seedRestaurant('blue_cafe');
  const catalog = await Catalog.create({
    userId: owner.id,
    name: 'blue_cafe',
    status,
    draftRevision: 2,
    publishedRevision: 2,
    mirageRestaurantId: restaurant.id,
    publicUrl: `https://menu.test/${restaurant.id}`,
    publicUrlScheme: 'MIRAGE_OBJECT_ID',
    lastPublishedAt: new Date(),
    ...extra,
  });
  const catalogId = catalog._id as Types.ObjectId;
  const category = await CatalogCategory.create({
    catalogId,
    userId: owner.id,
    name: 'menu',
    position: 0,
  });
  await CatalogProduct.create({
    catalogId,
    userId: owner.id,
    type: 'IMAGE_ONLY',
    name: 'dosa',
    position: 0,
    categoryId: category._id,
    assets: { imageKey: 'dev/catalog/x/products/p/0.jpg' },
    mirageItemId: 'mi-1',
    syncStatus: 'SYNCED',
  });
  return { owner, catalogId: String(catalogId), restaurantId: restaurant.id };
}

// ── Who ─────────────────────────────────────────────────────────────────────

describe('who may press the admin buttons', () => {
  it('refuses a rep — even one holding the restaurant — and a plain user', async () => {
    const { catalogId } = await seedCatalog();
    const rep = await makeUser('SALES_REP');
    await CatalogDelegation.create({
      repUserId: rep.id,
      catalogId: new Types.ObjectId(catalogId),
      grantedAt: new Date(),
      revokedAt: null,
    });
    const user = await makeUser();

    for (const actor of [rep, user]) {
      const pub = await request(app)
        .post(`/rep/catalogs/${catalogId}/publish/admin`)
        .set(actor.auth);
      const unpub = await request(app)
        .post(`/rep/catalogs/${catalogId}/unpublish/admin`)
        .set(actor.auth)
        .send({ reason: 'Wrong prices on the menu' });
      expect(pub.status).toBe(403);
      expect(unpub.status).toBe(403);
    }
    expect((await Catalog.findById(catalogId).lean().exec())?.status).toBe('PUBLISHED');
  });

  it('answers 404 for a deleted catalog, a ghost and a malformed id', async () => {
    const admin = await makeUser('ADMIN');
    const { catalogId } = await seedCatalog('PUBLISHED', { deletedAt: new Date() });
    for (const id of [catalogId, new Types.ObjectId().toHexString(), 'nope']) {
      const res = await request(app).post(`/rep/catalogs/${id}/publish/admin`).set(admin.auth);
      expect(res.status).toBe(404);
    }
  });
});

// ── Publish by admin ────────────────────────────────────────────────────────

describe('POST /rep/catalogs/:id/publish/admin', () => {
  it('publishes a restaurant with NO plan while the paywall is on', async () => {
    await ClientConfig.create({ [SUBSCRIPTION_GATES_FLAG_KEY]: true });
    const admin = await makeUser('ADMIN');
    const { catalogId } = await seedCatalog();

    // The control: the ordinary rep door is refused by the paywall.
    const repDoor = await request(app).post(`/rep/catalogs/${catalogId}/publish`).set(admin.auth);
    expect(repDoor.status).toBe(422);
    expect(repDoor.body.gates.map((g: { code: string }) => g.code)).toContain(
      'SUBSCRIPTION_REQUIRED'
    );

    const res = await request(app).post(`/rep/catalogs/${catalogId}/publish/admin`).set(admin.auth);
    expect(res.status).toBe(202);
    expect(res.body.runId).toBeTruthy();
    // No pending-payment clock was started on the way.
    expect(await CatalogSubscription.findOne({ catalogId }).lean().exec()).toBeNull();
  });

  it('still refuses a menu that cannot go online (the content gates stay)', async () => {
    const admin = await makeUser('ADMIN');
    const { catalogId } = await seedCatalog();
    await CatalogProduct.deleteMany({ catalogId });

    const res = await request(app).post(`/rep/catalogs/${catalogId}/publish/admin`).set(admin.auth);
    expect(res.status).toBe(422);
    expect(res.body.gates.map((g: { code: string }) => g.code)).toContain('CATALOG_EMPTY');
  });

  it('answers 409 with the run id when a run already holds the catalog', async () => {
    const admin = await makeUser('ADMIN');
    const { catalogId } = await seedCatalog();
    const first = await request(app)
      .post(`/rep/catalogs/${catalogId}/publish/admin`)
      .set(admin.auth);
    const second = await request(app)
      .post(`/rep/catalogs/${catalogId}/publish/admin`)
      .set(admin.auth);
    expect(first.status).toBe(202);
    expect(second.status).toBe(409);
    expect(second.body.runId).toBe(first.body.runId);
  });
});

// ── Unpublish by admin ──────────────────────────────────────────────────────

describe('POST /rep/catalogs/:id/unpublish/admin', () => {
  it('takes the menu down, keeps the restaurant, records the reason and tells the owner', async () => {
    const admin = await makeUser('ADMIN');
    const { owner, catalogId, restaurantId } = await seedCatalog();

    const res = await request(app)
      .post(`/rep/catalogs/${catalogId}/unpublish/admin`)
      .set(admin.auth)
      .send({ reason: '  Prices are out of date  ' });

    expect(res.status).toBe(202);
    expect(res.body).toMatchObject({ unpublished: true });
    expect(mirage.restaurants.get(restaurantId)?.isPublished).toBe(false);
    expect(mirage.callsTo('deleteRestaurant')).toHaveLength(0);

    const stored = await Catalog.findById(catalogId).lean().exec();
    expect(stored?.status).toBe('UNPUBLISHED');
    expect(stored?.adminUnpublish?.reason).toBe('Prices are out of date');

    const bell = await Notification.findOne({ audienceUserIds: owner.id }).lean().exec();
    expect(bell?.message).toContain('Prices are out of date');
    // "An administrator" — never which one.
    expect(bell?.message).not.toContain(String(admin.id));

    // The owner's own status read carries it too.
    const status = await request(app).get('/catalog/publish/status').set(owner.auth);
    expect(status.body.publish.adminUnpublish).toMatchObject({
      reason: 'Prices are out of date',
    });
  });

  it('requires a real reason', async () => {
    const admin = await makeUser('ADMIN');
    const { catalogId } = await seedCatalog();
    for (const body of [{}, { reason: '   ' }, { reason: 'abc' }, { reason: 'x'.repeat(501) }]) {
      const res = await request(app)
        .post(`/rep/catalogs/${catalogId}/unpublish/admin`)
        .set(admin.auth)
        .send(body);
      expect(res.status).toBe(400);
    }
    expect((await Catalog.findById(catalogId).lean().exec())?.status).toBe('PUBLISHED');
  });

  it('refuses a menu that is not live — a draft or one already down', async () => {
    const admin = await makeUser('ADMIN');
    for (const status of ['DRAFT', 'UNPUBLISHED'] as const) {
      const { catalogId } = await seedCatalog(status);
      const res = await request(app)
        .post(`/rep/catalogs/${catalogId}/unpublish/admin`)
        .set(admin.auth)
        .send({ reason: 'Not needed any more' });
      expect(res.status).toBe(409);
      expect(res.body.code).toBe('CATALOG_NOT_LIVE');
    }
    expect(await CatalogPublishRun.countDocuments({})).toBe(0);
  });

  it('waits for a running publish rather than racing it', async () => {
    const admin = await makeUser('ADMIN');
    const { catalogId } = await seedCatalog();
    const run = await request(app).post(`/rep/catalogs/${catalogId}/publish/admin`).set(admin.auth);

    const res = await request(app)
      .post(`/rep/catalogs/${catalogId}/unpublish/admin`)
      .set(admin.auth)
      .send({ reason: 'Taking it down for review' });
    expect(res.status).toBe(409);
    expect(res.body).toMatchObject({ code: 'PUBLISH_IN_PROGRESS', runId: run.body.runId });
    expect((await Catalog.findById(catalogId).lean().exec())?.adminUnpublish).toBeUndefined();
  });

  it('the next accepted publish clears the reason', async () => {
    const admin = await makeUser('ADMIN');
    const { catalogId } = await seedCatalog('UNPUBLISHED', {
      adminUnpublish: { reason: 'Old prices', at: new Date(), byUserId: admin.id },
    });

    const res = await request(app).post(`/rep/catalogs/${catalogId}/publish/admin`).set(admin.auth);
    expect(res.status).toBe(202);
    expect((await Catalog.findById(catalogId).lean().exec())?.adminUnpublish).toBeUndefined();
  });
});

// ── Republish switches the page back on ─────────────────────────────────────

describe('a republish after an unpublish', () => {
  it('switches the Mirage page back on', async () => {
    const { catalogId, restaurantId } = await seedCatalog('UNPUBLISHED');
    mirage.restaurants.get(restaurantId)!.isPublished = false;

    await syncCatalogBranding(new Types.ObjectId(catalogId));
    expect(mirage.restaurants.get(restaurantId)?.isPublished).toBe(true);
  });

  it('but never over a page the subscription switched off for non-payment', async () => {
    const { owner, catalogId, restaurantId } = await seedCatalog('PUBLISHED');
    mirage.restaurants.get(restaurantId)!.isPublished = false;
    await seedSubscription(new Types.ObjectId(catalogId), owner.id, 'PAUSED', {
      pageDeactivatedAt: new Date(),
    });

    await syncCatalogBranding(new Types.ObjectId(catalogId));
    expect(mirage.restaurants.get(restaurantId)?.isPublished).toBe(false);
  });
});
