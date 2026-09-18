// tests/grandfather-comped.test.ts
//
// The launch-day grandfather (§8 D1), through the service the script wraps:
// a dry run writes nothing and counts right; a real run comps exactly the
// provisioned, live, row-less catalogs for `grandfatherDays`; and a catalog
// that already has any subscription is left alone.
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { Catalog } from '@/models/Catalog';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { ClientConfig } from '@/models/ClientConfig';
import { UNCAPPED_THREE_D } from '@/models/types/subscription.types';
import { grandfatherCatalogsComped } from '@/services/subscription/grandfatherService';
import { PLAN_CATALOG_STORE_KEY } from '@/services/subscription/planCatalogService';
import { DEFAULT_PLAN_CATALOG } from '@/config/subscriptionPlans';

let mongod: MongoMemoryServer;

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

afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all([
    Catalog.deleteMany({}),
    CatalogSubscription.deleteMany({}),
    ClientConfig.deleteMany({}),
  ]);
});

const NOW = new Date('2026-10-01T00:00:00.000Z');
const DAY_MS = 86_400_000;

async function catalog(overrides: Record<string, unknown> = {}): Promise<Types.ObjectId> {
  const row = await Catalog.create({
    userId: new Types.ObjectId(),
    name: 'cafe',
    status: 'PUBLISHED',
    mirageRestaurantId: new Types.ObjectId().toHexString(),
    ...overrides,
  });
  return row._id as Types.ObjectId;
}

describe('grandfatherCatalogsComped', () => {
  it('--dry-run lists the candidates, inserts nothing, and counts correctly', async () => {
    const live = await catalog();
    const withRow = await catalog();
    await CatalogSubscription.create({
      catalogId: withRow,
      status: 'TRIAL',
      source: 'TRIAL',
      periodStart: NOW,
      periodEnd: new Date(NOW.getTime() + 30 * DAY_MS),
      threeDDishCap: 10,
    });

    const summary = await grandfatherCatalogsComped({ dryRun: true, now: NOW });

    expect(summary).toMatchObject({ scanned: 2, comped: 0, skipped: 1 });
    expect(summary.candidates.map((c) => c.catalogId.toHexString())).toEqual([live.toHexString()]);
    expect(await CatalogSubscription.countDocuments({})).toBe(1);
  });

  it('comps every provisioned catalog for grandfatherDays, uncapped, source COMP', async () => {
    const a = await catalog();
    const b = await catalog({ status: 'UNPUBLISHED' }); // still provisioned — its QR still works

    const summary = await grandfatherCatalogsComped({ dryRun: false, now: NOW });

    expect(summary).toMatchObject({ scanned: 2, comped: 2, skipped: 0 });
    for (const id of [a, b]) {
      const row = await CatalogSubscription.findOne({ catalogId: id }).lean().exec();
      expect(row).toMatchObject({
        status: 'COMPED',
        source: 'COMP',
        threeDDishCap: UNCAPPED_THREE_D,
      });
      expect(row?.periodStart.getTime()).toBe(NOW.getTime());
      expect(row!.periodEnd.getTime() - row!.periodStart.getTime()).toBe(
        DEFAULT_PLAN_CATALOG.grandfatherDays * DAY_MS
      );
      expect(row!.periodEnd.getTime() - row!.periodStart.getTime()).toBe(30 * DAY_MS);
      expect(row?.planId).toBeUndefined();
    }
  });

  it('skips a catalog that already has a subscription of any status', async () => {
    const paused = await catalog();
    await CatalogSubscription.create({
      catalogId: paused,
      status: 'PAUSED',
      source: 'ONLINE',
      periodStart: new Date(NOW.getTime() - 60 * DAY_MS),
      periodEnd: new Date(NOW.getTime() - 30 * DAY_MS),
      threeDDishCap: 10,
    });
    const fresh = await catalog();

    const summary = await grandfatherCatalogsComped({ dryRun: false, now: NOW });

    expect(summary).toMatchObject({ scanned: 2, comped: 1, skipped: 1 });
    const untouched = await CatalogSubscription.findOne({ catalogId: paused }).lean().exec();
    expect(untouched?.status).toBe('PAUSED');
    expect(await CatalogSubscription.countDocuments({ catalogId: fresh })).toBe(1);
  });

  it('ignores DRAFT (unprovisioned) and soft-deleted catalogs', async () => {
    await catalog({ mirageRestaurantId: undefined, status: 'DRAFT' });
    await catalog({ deletedAt: new Date() });

    const summary = await grandfatherCatalogsComped({ dryRun: false, now: NOW });

    expect(summary).toMatchObject({ scanned: 0, comped: 0, skipped: 0 });
    expect(await CatalogSubscription.countDocuments({})).toBe(0);
  });

  it('is idempotent: a second run comps nothing and counts everything as skipped', async () => {
    await catalog();
    await catalog();

    await grandfatherCatalogsComped({ dryRun: false, now: NOW });
    const again = await grandfatherCatalogsComped({ dryRun: false, now: NOW });

    expect(again).toMatchObject({ scanned: 2, comped: 0, skipped: 2 });
    expect(await CatalogSubscription.countDocuments({})).toBe(2);
  });

  it('treats a row written by a concurrent run (E11000) as skipped, not as an error', async () => {
    const id = await catalog();
    await CatalogSubscription.create({
      catalogId: id,
      status: 'COMPED',
      source: 'COMP',
      periodStart: NOW,
      periodEnd: new Date(NOW.getTime() + DAY_MS),
      threeDDishCap: UNCAPPED_THREE_D,
    });
    // The race, made deterministic: the "who already has a row" read answers
    // nobody (as it would have a moment before the other run wrote), so the
    // insert runs and the unique index is what says no.
    const original = CatalogSubscription.find.bind(CatalogSubscription);
    vi.spyOn(CatalogSubscription, 'find').mockImplementationOnce(
      (() => original({ catalogId: { $in: [] } })) as never
    );

    const summary = await grandfatherCatalogsComped({ dryRun: false, now: NOW });

    expect(summary).toMatchObject({ scanned: 1, comped: 0, skipped: 1 });
    expect(await CatalogSubscription.countDocuments({ catalogId: id })).toBe(1);
  });

  it('honours a grandfatherDays override on the config document', async () => {
    await ClientConfig.create({
      [PLAN_CATALOG_STORE_KEY]: { ...structuredClone(DEFAULT_PLAN_CATALOG), grandfatherDays: 45 },
    });
    const id = await catalog();

    await grandfatherCatalogsComped({ dryRun: false, now: NOW });

    const row = await CatalogSubscription.findOne({ catalogId: id }).lean().exec();
    expect(row!.periodEnd.getTime() - NOW.getTime()).toBe(45 * DAY_MS);
  });
});
