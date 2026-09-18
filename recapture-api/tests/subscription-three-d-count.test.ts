// tests/subscription-three-d-count.test.ts
//
// Which dishes count against the 3D cap (§3b): READY, and only READY, read
// through effectiveModelStatus. And the C1 property: the request-time gate and
// the worker's audit write count the SAME list, so on one seeded catalog the
// two numbers are equal — archived, soft-deleted and awaiting-first-model rows
// drop out of both.
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { env } from '@/config/env';
import { Catalog } from '@/models/Catalog';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogProduct } from '@/models/CatalogProduct';
import { CatalogPublishRun } from '@/models/CatalogPublishRun';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import { ClientConfig } from '@/models/ClientConfig';
import { evaluatePublishGates, PublishGateCode } from '@/services/catalogPublishService';
import { resetMirageClient, setMirageClient } from '@/services/mirage';
import { resetPublishExecutors, setPublishExecutors } from '@/services/catalog/publishExecutors';
import { countsAsThreeD, countThreeDDishes } from '@/services/subscription/threeDDishCount';
import { mirageCatalogPublishProcessor } from '@/worker/processors/mirageCatalogPublishProcessor';
import type { WorkerJob } from '@/worker/workerTypes';
import { FakeMirage } from './fixtures/mirageFake';

const GLB = 'https://test.cloudfront.net/dev/p/model.glb';

describe('countsAsThreeD', () => {
  it('counts a READY model', () => {
    expect(countsAsThreeD({ modelStatus: 'READY', assets: { glbUrl: GLB } })).toBe(true);
  });

  it('counts a legacy row with a glbUrl and no stored status (effective READY)', () => {
    expect(countsAsThreeD({ assets: { glbUrl: GLB } })).toBe(true);
    expect(countsAsThreeD({ modelStatus: 'NONE', assets: { glbUrl: GLB } })).toBe(true);
  });

  it('does NOT count a replacement still generating, even with the old glbUrl', () => {
    expect(countsAsThreeD({ modelStatus: 'PROCESSING', assets: { glbUrl: GLB } })).toBe(false);
    expect(countsAsThreeD({ modelStatus: 'QUEUED', assets: { glbUrl: GLB } })).toBe(false);
  });

  it('does NOT count a failed generation, an image dish, or a model-less 3D dish', () => {
    expect(countsAsThreeD({ modelStatus: 'FAILED', assets: { glbUrl: GLB } })).toBe(false);
    expect(countsAsThreeD({ modelStatus: 'NONE', assets: { imageKey: 'x.jpg' } as never })).toBe(
      false
    );
    expect(countsAsThreeD({})).toBe(false);
  });

  it('counts a snapshot product, whose status is already effective', () => {
    // The worker's snapshot carries no `assets`; its modelStatus was derived.
    expect(countsAsThreeD({ modelStatus: 'READY' })).toBe(true);
  });
});

describe('countThreeDDishes', () => {
  it('sums the rule over the list it is given, without filtering', () => {
    expect(
      countThreeDDishes([
        { modelStatus: 'READY' },
        { assets: { glbUrl: GLB } },
        { modelStatus: 'PROCESSING', assets: { glbUrl: GLB } },
        { modelStatus: 'NONE' },
        // Not this file's job to drop an archived row — the caller's list is
        // the list. Counted, deliberately.
        { modelStatus: 'READY', archivedAt: new Date() } as never,
      ])
    ).toBe(3);
    expect(countThreeDDishes([])).toBe(0);
  });
});

// ── C1: the gate and the audit write agree ──────────────────────────────────

describe('the request-time count and the run audit count (C1)', () => {
  let mongod: MongoMemoryServer;
  const mirage = new FakeMirage();
  const USER_ID = new Types.ObjectId();

  beforeAll(async () => {
    mongod = await MongoMemoryServer.create();
    await mongoose.connect(mongod.getUri());
    await CatalogSubscription.syncIndexes();
  });

  afterAll(async () => {
    await mongoose.disconnect();
    await mongod.stop();
  });

  afterEach(async () => {
    vi.restoreAllMocks();
    resetMirageClient();
    resetPublishExecutors();
    Object.assign(env, {
      MIRAGE_BASE_URL: undefined,
      MIRAGE_API_KEY: undefined,
      MIRAGE_ADMIN_TOKEN: undefined,
      MIRAGE_PUBLIC_BASE_URL: undefined,
    });
    await Promise.all([
      Catalog.deleteMany({}),
      CatalogCategory.deleteMany({}),
      CatalogProduct.deleteMany({}),
      CatalogPublishRun.deleteMany({}),
      CatalogSubscription.deleteMany({}),
      ClientConfig.deleteMany({}),
    ]);
  });

  it('are equal on a catalog with archived, deleted and generating rows mixed in', async () => {
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'warn').mockImplementation(() => {});

    const catalog = await Catalog.create({
      userId: USER_ID,
      name: 'blue_cafe',
      status: 'DRAFT',
      mirageRestaurantId: 'mr-1',
      draftRevision: 1,
      publishedRevision: -1,
    });
    const catalogId = catalog._id as Types.ObjectId;
    const category = await CatalogCategory.create({
      catalogId,
      userId: USER_ID,
      name: 'mains',
      position: 0,
    });
    const threeD = { glbUrl: GLB, thumbnailUrl: 'https://test.cloudfront.net/p/t.jpg' };
    const base = { catalogId, userId: USER_ID, categoryId: category._id };

    await CatalogProduct.create([
      // Two that count.
      { ...base, type: 'THREE_D', name: 'ready_a', position: 0, assets: threeD },
      { ...base, type: 'THREE_D', name: 'ready_b', position: 1, assets: threeD, modelStatus: 'READY' },
      // A replacement generating — publishes with its old model, does not count.
      { ...base, type: 'THREE_D', name: 'regen', position: 2, assets: threeD, modelStatus: 'PROCESSING' },
      // Awaiting its FIRST model — excluded from the publish entirely.
      { ...base, type: 'THREE_D', name: 'first', position: 3, modelStatus: 'QUEUED' },
      // A photo dish.
      { ...base, type: 'IMAGE_ONLY', name: 'photo', position: 4, assets: { imageKey: 'p.jpg' } },
      // Archived and soft-deleted 3D rows — in the snapshot (so their DELETEs
      // can be planned), out of the publish, out of the count.
      { ...base, type: 'THREE_D', name: 'archived', position: 5, assets: threeD, archivedAt: new Date(), mirageItemId: 'mi-1' },
      { ...base, type: 'THREE_D', name: 'deleted', position: 6, assets: threeD, deletedAt: new Date(), mirageItemId: 'mi-2' },
    ]);

    // Worker time first, with Mirage UNCONFIGURED so the processor's warm-up
    // ping is a no-op rather than a real HTTP call: a run over the snapshot,
    // executors stubbed.
    setPublishExecutors({
      RESTAURANT: async () => ({ outcome: 'SUCCEEDED' }),
      CATEGORY: async () => ({ outcome: 'SUCCEEDED' }),
      PRODUCT: async () => ({ outcome: 'SUCCEEDED' }),
    });
    const run = await CatalogPublishRun.create({
      catalogId,
      userId: USER_ID,
      jobId: new Types.ObjectId(),
      snapshotRevision: 1,
    });
    await Catalog.updateOne({ _id: catalogId }, { $set: { activePublishRunId: run._id } }).exec();
    const job: WorkerJob = {
      _id: new Types.ObjectId(),
      state: 'PROCESSING',
      jobType: 'MIRAGE_CATALOG_PUBLISH',
      payload: {
        catalogId: catalogId.toHexString(),
        publishRunId: (run._id as Types.ObjectId).toHexString(),
        mode: 'FULL',
      },
      attempts: 0,
      maxAttempts: 3,
      claimedBy: 'worker-test',
      createdAt: new Date(),
      updatedAt: new Date(),
    };
    await mirageCatalogPublishProcessor(job);

    const stored = await CatalogPublishRun.findById(run._id).lean().exec();
    expect(stored?.threeDDishCount).toBe(2);
    // Audit only — the run finished regardless of any cap.
    expect(stored?.state).toBe('SUCCEEDED');

    // Request time: the gate, switched on, with a cap of 0 so the count is
    // forced onto the wire as meta. Mirage must be configured or the gates
    // short-circuit to PUBLISHING_UNAVAILABLE.
    setMirageClient(mirage);
    Object.assign(env, {
      MIRAGE_BASE_URL: 'https://mirage.test',
      MIRAGE_API_KEY: 'k',
      MIRAGE_ADMIN_TOKEN: 't',
      MIRAGE_PUBLIC_BASE_URL: 'https://menu.test',
    });
    await ClientConfig.create({ subscriptionGatesEnabled: true });
    await CatalogSubscription.create({
      catalogId,
      status: 'TRIAL',
      source: 'TRIAL',
      periodStart: new Date(),
      periodEnd: new Date(Date.now() + 86_400_000),
      threeDDishCap: 0,
    });
    const products = await CatalogProduct.find({ catalogId, deletedAt: null }).exec();
    const fresh = await Catalog.findById(catalogId).exec();
    const gates = await evaluatePublishGates(fresh!, products);
    const capacity = gates.find((g) => g.code === PublishGateCode.SUBSCRIPTION_CAPACITY_EXCEEDED);
    expect(capacity?.meta?.threeDDishCount).toBe(2);

    expect(capacity?.meta?.threeDDishCount).toBe(stored?.threeDDishCount);
  });
});
