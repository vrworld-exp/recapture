// tests/catalog-publish-idempotency.test.ts
//
// THE GUARANTEE, end to end: publishing the same catalog twice produces exactly
// one Mirage item, and republishing an unchanged catalog writes nothing at all.
//
// These run the whole processor — planner, walk, executors, finalize — against
// the faithful Mirage fake, because the guarantee is a property of the SYSTEM
// and not of any one function. The unit suites next door prove the pieces; this
// one proves they compose.
//
// The crash-replay case is the reason the whole design looks the way it does.
// Mirage has no idempotency key, so the only thing standing between a killed
// worker and a duplicated product is (a) persisting `mirageItemId` the instant
// the create returns and (b) reconciling when even that was too late. The test
// below kills the process in exactly that window.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import mongoose from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { Catalog } from '@/models/Catalog';
import { CatalogProduct } from '@/models/CatalogProduct';
import { CatalogPublishRun } from '@/models/CatalogPublishRun';
import { resetAssetUploader } from '@/services/catalog/assetUploader';
import { categoryExecutor } from '@/services/catalog/categorySync';
import {
  resetPublishExecutors,
  setPublishExecutors,
  type PublishStepExecutor,
} from '@/services/catalog/publishExecutors';
import { productExecutor } from '@/services/catalog/productSync';
import { resetMirageClient, setMirageClient } from '@/services/mirage';
import { mirageCatalogPublishProcessor } from '@/worker/processors/mirageCatalogPublishProcessor';
import { FakeMirage } from './fixtures/mirageFake';
import {
  clearCatalogCollections,
  publishJob,
  seedCatalog,
  stubAssetUploader,
  type PublishFixture,
} from './fixtures/publishHarness';

let mongod: MongoMemoryServer;
const mirage = new FakeMirage();
let restaurantId: string;

/** The restaurant is already provisioned; B4 owns the step that mints it. */
const provisionedRestaurant: PublishStepExecutor = async (_step, context) => {
  context.mirageRestaurantId = context.snapshot.catalog.mirageRestaurantId;
  return { outcome: 'SUCCEEDED' };
};

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  mirage.reset();
  restaurantId = mirage.seedRestaurant('blue_cafe').id;
  setMirageClient(mirage);
  stubAssetUploader();
  setPublishExecutors({
    RESTAURANT: provisionedRestaurant,
    CATEGORY: categoryExecutor,
    PRODUCT: productExecutor,
  });
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'info').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
});

afterEach(async () => {
  await clearCatalogCollections();
  resetMirageClient();
  resetAssetUploader();
  resetPublishExecutors();
  vi.restoreAllMocks();
});

async function seedPublishable(): Promise<PublishFixture> {
  return seedCatalog({
    catalog: { mirageRestaurantId: restaurantId },
    products: [
      { name: 'Chair', price: 1200 },
      { name: 'Stool', price: 400 },
    ],
  });
}

/** Re-queues the catalog for a second publish, as the B4 endpoint would. */
async function queueAnotherRun(fixture: PublishFixture): Promise<PublishFixture> {
  const catalog = await Catalog.findById(fixture.catalogId).lean().exec();
  const run = await CatalogPublishRun.create({
    catalogId: fixture.catalogId,
    userId: catalog?.userId,
    jobId: new mongoose.Types.ObjectId(),
    snapshotRevision: catalog?.draftRevision ?? 0,
    state: 'QUEUED',
  });
  const runId = run._id as mongoose.Types.ObjectId;
  await Catalog.updateOne(
    { _id: fixture.catalogId },
    { $set: { activePublishRunId: runId } }
  ).exec();
  return { ...fixture, runId };
}

describe('publishing twice', () => {
  it('produces exactly one Mirage item per product', async () => {
    const fixture = await seedPublishable();

    await mirageCatalogPublishProcessor(publishJob(fixture));
    const second = await queueAnotherRun(fixture);
    await mirageCatalogPublishProcessor(publishJob(second));

    expect(mirage.items.size).toBe(2);
    expect(mirage.categories.size).toBe(1);
  });

  it('performs ZERO Mirage writes when nothing changed', async () => {
    const fixture = await seedPublishable();
    await mirageCatalogPublishProcessor(publishJob(fixture));

    const second = await queueAnotherRun(fixture);
    mirage.calls.length = 0;
    const result = (await mirageCatalogPublishProcessor(publishJob(second))) as {
      state: string;
      counts: { skipped: number; synced: number };
    };

    expect(mirage.writes).toHaveLength(0);
    expect(result.state).toBe('SUCCEEDED');
    expect(result.counts.synced).toBe(0);
    // Restaurant + category + two products, every one of them a SKIP.
    expect(result.counts.skipped).toBe(4);
  });

  it('publishes an edit on the second run without touching the untouched row', async () => {
    const fixture = await seedPublishable();
    await mirageCatalogPublishProcessor(publishJob(fixture));

    await CatalogProduct.updateOne(
      { _id: fixture.productIds[0] },
      { $set: { price: 1500 } }
    ).exec();
    await Catalog.updateOne({ _id: fixture.catalogId }, { $inc: { draftRevision: 1 } }).exec();

    const second = await queueAnotherRun(fixture);
    mirage.calls.length = 0;
    await mirageCatalogPublishProcessor(publishJob(second));

    expect(mirage.callsTo('updateItem')).toHaveLength(1);
    expect(mirage.callsTo('createItem')).toHaveLength(0);
    expect([...mirage.items.values()].find((i) => i.name === 'Chair')?.price).toBe(1500);
  });
});

describe('crash-replay', () => {
  it('leaves exactly ONE Mirage item when the worker dies before persisting the id', async () => {
    const fixture = await seedPublishable();

    // THE WINDOW. Mirage accepts the create; the process dies before the id
    // reaches Mongo. This is the only state in which a duplicate is possible,
    // and reconciliation is what closes it.
    const realCreateItem = mirage.createItem.bind(mirage);
    let killed = false;
    setMirageClient({
      ...mirage,
      listRestaurants: mirage.listRestaurants.bind(mirage),
      listCategories: mirage.listCategories.bind(mirage),
      createCategory: mirage.createCategory.bind(mirage),
      updateCategory: mirage.updateCategory.bind(mirage),
      listItemsForCategory: mirage.listItemsForCategory.bind(mirage),
      updateItem: mirage.updateItem.bind(mirage),
      deleteItem: mirage.deleteItem.bind(mirage),
      createItem: async (input) => {
        const created = await realCreateItem(input);
        if (!killed) {
          killed = true;
          throw new Error('worker killed after create-item, before persisting the id');
        }
        return created;
      },
    } as unknown as typeof mirage);

    await mirageCatalogPublishProcessor(publishJob(fixture));

    // One product's create landed on Mirage but its id was never recorded.
    const orphaned = await CatalogProduct.findOne({ mirageItemId: null }).lean().exec();
    expect(orphaned).not.toBeNull();
    expect(mirage.items.size).toBe(2);

    // The replay: a second run over live state. The create is refused as a
    // duplicate, the existing item is adopted, and NO second item appears.
    setMirageClient(mirage);
    const second = await queueAnotherRun(fixture);
    await mirageCatalogPublishProcessor(publishJob(second));

    expect(mirage.items.size).toBe(2);
    const rows = await CatalogProduct.find({ catalogId: fixture.catalogId }).lean().exec();
    expect(rows.every((row) => Boolean(row.mirageItemId))).toBe(true);
    expect(new Set(rows.map((row) => row.mirageItemId)).size).toBe(2);
  });

  it('re-plans an already-synced row as a SKIP on the replay', async () => {
    const fixture = await seedPublishable();
    await mirageCatalogPublishProcessor(publishJob(fixture));

    // A dead attempt left the run RUNNING; the lease expired and it was
    // re-claimed. Everything already SYNCED must plan as SKIP.
    await CatalogPublishRun.updateOne(
      { _id: fixture.runId },
      { $set: { state: 'RUNNING' }, $unset: { finishedAt: '' } }
    ).exec();
    mirage.calls.length = 0;

    const result = (await mirageCatalogPublishProcessor(publishJob(fixture))) as {
      state: string;
    };

    expect(mirage.writes).toHaveLength(0);
    expect(result.state).toBe('SUCCEEDED');
  });

  it('does nothing at all for a run that already finished', async () => {
    const fixture = await seedPublishable();
    await mirageCatalogPublishProcessor(publishJob(fixture));
    mirage.calls.length = 0;

    const replay = (await mirageCatalogPublishProcessor(publishJob(fixture))) as {
      replayed?: boolean;
    };

    expect(replay.replayed).toBe(true);
    expect(mirage.calls).toHaveLength(0);
  });
});

describe('the whole run', () => {
  it('never lets Mirage prose reach a row, an entry or a run error', async () => {
    const fixture = await seedCatalog({
      catalog: { mirageRestaurantId: restaurantId },
      // Two products with one name: Mirage refuses the second.
      products: [{ name: 'Chair' }, { name: 'Chair' }],
    });

    await mirageCatalogPublishProcessor(publishJob(fixture));

    const run = await CatalogPublishRun.findById(fixture.runId).lean().exec();
    const rows = await CatalogProduct.find({ catalogId: fixture.catalogId }).lean().exec();

    const strings = [
      ...(run?.entries ?? []).map((entry) => entry.code ?? ''),
      run?.error?.code ?? '',
      run?.error?.message ?? '',
      ...rows.map((row) => row.syncError?.code ?? ''),
      ...rows.map((row) => row.syncError?.message ?? ''),
    ];

    for (const text of strings) {
      expect(text).not.toMatch(/Product already exist|Category already exist|Only chef/i);
    }
    // Every code that IS present is one of ours.
    const codes = [
      ...(run?.entries ?? []).flatMap((entry) => (entry.code ? [entry.code] : [])),
      ...rows.flatMap((row) => (row.syncError ? [row.syncError.code] : [])),
    ];
    expect(codes.length).toBeGreaterThan(0);
    for (const code of codes) expect(code).toMatch(/^PUBLISH_[A-Z_]+$/);
  });

  it('records PARTIAL and does not advance publishedRevision when a row fails', async () => {
    const fixture = await seedCatalog({
      catalog: { mirageRestaurantId: restaurantId, draftRevision: 9 },
      products: [{ name: 'Chair' }, { name: 'Chair' }],
    });

    await mirageCatalogPublishProcessor(publishJob(fixture));

    const run = await CatalogPublishRun.findById(fixture.runId).lean().exec();
    expect(run?.state).toBe('PARTIAL');
    const catalog = await Catalog.findById(fixture.catalogId).lean().exec();
    expect(catalog?.publishedRevision).toBe(-1);
    // The lock is released on every terminal path, PARTIAL included.
    expect(catalog?.activePublishRunId).toBeNull();
  });
});
