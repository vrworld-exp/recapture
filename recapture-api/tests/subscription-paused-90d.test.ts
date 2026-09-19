// tests/subscription-paused-90d.test.ts
//
// Prompt B / E23 — the follow-up segment of the collections list.
//
// What this file exists to pin:
//   • `state=PAUSED_90D` returns ONLY rows paused at least 90 days ago; a row
//     paused 89 days ago is excluded, one paused exactly 90 days ago is in.
//   • It is sorted `pausedAt` ascending — the longest-quiet first — and its
//     cursor paginates on the same key, not on `periodEnd`.
//   • The DTO is the plain list DTO (no phone, no email), and `PAUSED` itself
//     is unchanged: it still returns every paused row.
//   • ADMIN-only, like every other segment (E39).
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { Catalog } from '@/models/Catalog';
import { CatalogDelegation } from '@/models/CatalogDelegation';
import { CatalogProduct } from '@/models/CatalogProduct';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { PaymentRecord } from '@/models/PaymentRecord';
import { User } from '@/models/User';
import { DAY_MS, makeUser, seedCatalog, seedSubscription } from './helpers/subscriptionPayments';

const app = createApp();
let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Promise.all([
    Catalog.syncIndexes(),
    CatalogSubscription.syncIndexes(),
    CatalogDelegation.syncIndexes(),
    PaymentRecord.syncIndexes(),
  ]);
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
    CatalogDelegation.deleteMany({}),
    CatalogSubscription.deleteMany({}),
    CatalogProduct.deleteMany({}),
    PaymentRecord.deleteMany({}),
  ]);
});

/** Live dishes on a catalog, by what picture each carries. */
async function seedDishes(
  catalogId: Types.ObjectId,
  specs: Record<string, unknown>[]
): Promise<void> {
  const owner = await CatalogSubscription.findOne({ catalogId }).select({ userId: 1 }).lean().exec();
  await CatalogProduct.create(
    specs.map((spec, index) => ({
      catalogId,
      userId: owner!.userId,
      name: 'dish_' + index,
      position: index,
      ...spec,
    }))
  );
}

/** A PAUSED row whose pause began `daysAgo` days ago, named after it. */
async function pausedFor(daysAgo: number, now: number): Promise<Types.ObjectId> {
  const owner = await makeUser();
  const catalogId = await seedCatalog(owner.id);
  await Catalog.updateOne({ _id: catalogId }, { $set: { name: `paused_${daysAgo}` } });
  await seedSubscription(catalogId, owner.id, 'PAUSED', {
    planId: 'TASTE',
    // The period ended before the grace that ended in the pause.
    periodEnd: new Date(now - (daysAgo + 7) * DAY_MS),
    graceEndsAt: new Date(now - daysAgo * DAY_MS),
    pausedAt: new Date(now - daysAgo * DAY_MS),
  });
  return catalogId;
}

describe('GET /admin/subscriptions?state=PAUSED_90D', () => {
  it('returns only rows paused ≥ 90 days ago, oldest pause first; 89 days is out', async () => {
    const admin = await makeUser('ADMIN');
    const now = Date.now();
    const oldest = await pausedFor(200, now);
    const boundary = await pausedFor(90, now);
    const middle = await pausedFor(120, now);
    await pausedFor(89, now);
    await pausedFor(3, now);
    // A PAUSED row from before `pausedAt` existed is not "90 days quiet" —
    // nobody knows how long it has been paused, so it stays in PAUSED only.
    const legacyOwner = await makeUser();
    await seedSubscription(await seedCatalog(legacyOwner.id), legacyOwner.id, 'PAUSED', {
      periodEnd: new Date(now - 400 * DAY_MS),
    });

    const res = await request(app).get('/admin/subscriptions?state=PAUSED_90D').set(admin.auth);
    expect(res.status).toBe(200);
    expect(res.body.items.map((i: { catalogId: string }) => i.catalogId)).toEqual([
      oldest.toHexString(),
      middle.toHexString(),
      boundary.toHexString(),
    ]);
    expect(res.body.nextCursor).toBeNull();
    expect(res.body.items[0]).toMatchObject({
      catalogName: 'paused 200',
      status: 'PAUSED',
      planId: 'TASTE',
      daysLeft: null,
      graceEndsAt: expect.any(String),
    });
    expect(JSON.stringify(res.body)).not.toMatch(/phone|email/);

    // PAUSED itself is untouched: every paused row, the legacy one included.
    const all = await request(app).get('/admin/subscriptions?state=PAUSED').set(admin.auth);
    expect(all.body.items).toHaveLength(6);
  });

  it('paginates on pausedAt, not periodEnd', async () => {
    const admin = await makeUser('ADMIN');
    const now = Date.now();
    // periodEnd order (via `daysAgo + 7`) and pausedAt order agree here, so
    // to tell the keys apart one row gets a periodEnd that would sort it
    // FIRST by periodEnd while its pause is the most recent of the three.
    const a = await pausedFor(150, now);
    const b = await pausedFor(120, now);
    const c = await pausedFor(95, now);
    await CatalogSubscription.updateOne(
      { catalogId: c },
      { $set: { periodEnd: new Date(now - 900 * DAY_MS) } }
    );

    const page1 = await request(app)
      .get('/admin/subscriptions?state=PAUSED_90D&limit=2')
      .set(admin.auth);
    expect(page1.body.items.map((i: { catalogId: string }) => i.catalogId)).toEqual([
      a.toHexString(),
      b.toHexString(),
    ]);
    expect(page1.body.nextCursor).toBeTypeOf('string');

    const page2 = await request(app)
      .get(`/admin/subscriptions?state=PAUSED_90D&limit=2&cursor=${page1.body.nextCursor}`)
      .set(admin.auth);
    expect(page2.body.items.map((i: { catalogId: string }) => i.catalogId)).toEqual([
      c.toHexString(),
    ]);
    expect(page2.body.nextCursor).toBeNull();
  });

  it('carries photoCoverage (E46): live dishes with a card image, null for an empty menu', async () => {
    const admin = await makeUser('ADMIN');
    const now = Date.now();
    const halfCovered = await pausedFor(100, now);
    const fullyCovered = await pausedFor(110, now);
    const empty = await pausedFor(120, now);
    await seedDishes(halfCovered, [
      // A photo dish and a 3D dish with its render thumbnail: both count.
      { type: 'IMAGE_ONLY', assets: { imageKey: 'photos/a.jpg' } },
      { type: 'THREE_D', modelStatus: 'READY', assets: { glbUrl: 'https://cdn/a.glb', thumbnailUrl: 'https://cdn/a.png' } },
      // A legacy 3D row with no thumbnail: the one card that is a placeholder.
      { type: 'THREE_D', modelStatus: 'READY', assets: { glbUrl: 'https://cdn/b.glb' } },
      // Not live — must not move the number either way.
      { type: 'IMAGE_ONLY', assets: {}, deletedAt: new Date() },
      { type: 'IMAGE_ONLY', assets: {}, archivedAt: new Date() },
      { type: 'THREE_D', modelStatus: 'PROCESSING', assets: {} },
    ]);
    await seedDishes(fullyCovered, [
      { type: 'IMAGE_ONLY', assets: { imageKey: 'photos/b.jpg' } },
    ]);

    const res = await request(app).get('/admin/subscriptions?state=PAUSED_90D').set(admin.auth);
    expect(res.status).toBe(200);
    const byId = new Map(
      res.body.items.map((i: { catalogId: string; photoCoverage: number | null }) => [
        i.catalogId,
        i.photoCoverage,
      ])
    );
    expect(byId.get(halfCovered.toHexString())).toBe(66);
    expect(byId.get(fullyCovered.toHexString())).toBe(100);
    expect(byId.get(empty.toHexString())).toBeNull();

    // The same field on the plain PAUSED segment.
    const all = await request(app).get('/admin/subscriptions?state=PAUSED').set(admin.auth);
    expect(all.body.items.every((i: { photoCoverage?: unknown }) => 'photoCoverage' in i)).toBe(true);
  });

  it('is ADMIN-only', async () => {
    const artist = await makeUser('MODEL_ARTIST');
    const rep = await makeUser('SALES_REP');
    for (const who of [artist, rep]) {
      const res = await request(app).get('/admin/subscriptions?state=PAUSED_90D').set(who.auth);
      expect(res.status).toBe(403);
    }
  });
});
