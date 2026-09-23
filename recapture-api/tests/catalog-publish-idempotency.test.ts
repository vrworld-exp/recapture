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

const app = createApp();
let mongod: MongoMemoryServer;
const mirage = new FakeMirage();
let restaurantId: string;

type Auth = { Authorization: string };

/** A signed-in user, for the HTTP-level describe at the bottom. */
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

/** The restaurant is already provisioned; B4 owns the step that mints it. */
const provisionedRestaurant: PublishStepExecutor = async (_step, context) => {
  context.mirageRestaurantId = context.snapshot.catalog.mirageRestaurantId;
  return { outcome: 'SUCCEEDED' };
};

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  // WITHOUT THIS the replay describe below tests nothing: the unique partial
  // index on {userId, idempotencyKey} is the race authority, and an in-memory
  // database that never built it lets a second run be created happily.
  await CatalogPublishRun.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  mirage.reset();
  restaurantId = mirage.seedRestaurant('blue_cafe').id;
  setMirageClient(mirage);
  // The HTTP describe publishes through the real route, whose gates refuse a
  // deployment with no Mirage configured.
  Object.assign(env, {
    MIRAGE_BASE_URL: 'https://mirage.test',
    MIRAGE_API_KEY: 'test-api-key',
    MIRAGE_ADMIN_TOKEN: 'test-admin-token',
    MIRAGE_PUBLIC_BASE_URL: 'https://menu.test',
  });
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
  await Promise.all([
    User.deleteMany({}),
    Job.deleteMany({}),
    mongoose.connection.collection('ratewindows').deleteMany({}),
  ]);
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

// ── The KEY, at the HTTP boundary ───────────────────────────────────────────
//
// The suite above is about Mirage's missing idempotency. This one is about
// OURS: the `{userId, idempotencyKey}` unique index whose own comment has
// always claimed "a double-tap's E11000 is resolved to a replay of the winner",
// while nothing in the code did that. A replayed key reached `create`, lost to
// the index and left the service as a 500 — and the client keeps a key across a
// 5xx on purpose, so the SAME key went back on the next press, and every press
// after that was the same 500 for the life of the screen.
describe('POST /catalog/publish — a replayed Idempotency-Key', () => {
  async function publishable(userId: string): Promise<Types.ObjectId> {
    const restaurant = mirage.seedRestaurant(`cafe_${Date.now()}`);
    const catalog = await Catalog.create({
      userId: new Types.ObjectId(userId),
      name: 'Blue Cafe',
      status: 'DRAFT',
      draftRevision: 1,
      publishedRevision: -1,
      mirageRestaurantId: restaurant.id,
      publicUrl: `https://menu.test/${restaurant.id}`,
      publicUrlScheme: 'MIRAGE_OBJECT_ID',
    });
    const catalogId = catalog._id as mongoose.Types.ObjectId;
    const category = await CatalogCategory.create({
      catalogId,
      userId: new Types.ObjectId(userId),
      name: 'menu',
      position: 0,
    });
    await CatalogProduct.create({
      catalogId,
      userId: new Types.ObjectId(userId),
      type: 'IMAGE_ONLY',
      name: 'Chair',
      position: 0,
      categoryId: category._id,
      assets: { imageKey: 'dev/catalog/x/products/p/0.jpg' },
    });
    return catalogId;
  }

  /** Finishes the run and drops the lock, as the worker's finalize would. */
  async function settle(catalogId: mongoose.Types.ObjectId, runId: string): Promise<void> {
    await CatalogPublishRun.updateOne(
      { _id: new mongoose.Types.ObjectId(runId) },
      { $set: { state: 'SUCCEEDED', finishedAt: new Date() } }
    ).exec();
    await Catalog.updateOne({ _id: catalogId }, { $set: { activePublishRunId: null } }).exec();
  }

  it('answers 200 replayed with the first run, and creates no second run', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await publishable(id);

    const first = await request(app)
      .post('/catalog/publish')
      .set(auth)
      .set('Idempotency-Key', 'k1')
      .send({});
    expect(first.status).toBe(202);
    await settle(catalogId, first.body.runId);

    const replay = await request(app)
      .post('/catalog/publish')
      .set(auth)
      .set('Idempotency-Key', 'k1')
      .send({});

    // 200, NOT 202: nothing was queued by this request.
    expect(replay.status).toBe(200);
    expect(replay.body).toMatchObject({
      status: 'success',
      runId: first.body.runId,
      queued: false,
      replayed: true,
    });
    expect(await CatalogPublishRun.countDocuments({ idempotencyKey: 'k1' })).toBe(1);
  });

  it('is what the second device sees while the first one is still watching', async () => {
    const { id, auth } = await makeUser();
    await publishable(id);

    const first = await request(app)
      .post('/catalog/publish')
      .set(auth)
      .set('Idempotency-Key', 'k2')
      .send({});
    // No settle: the run still holds the lock, so the in-progress check answers
    // first and this never reaches `create`. Either way the answer names the
    // one run, which is the property that matters.
    const second = await request(app)
      .post('/catalog/publish')
      .set(auth)
      .set('Idempotency-Key', 'k2')
      .send({});

    expect(second.body.runId).toBe(first.body.runId);
    expect(await CatalogPublishRun.countDocuments({ idempotencyKey: 'k2' })).toBe(1);
  });

  it('starts a new run when the run the key owned has been pruned away', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await publishable(id);

    const first = await request(app)
      .post('/catalog/publish')
      .set(auth)
      .set('Idempotency-Key', 'k3')
      .send({});
    await settle(catalogId, first.body.runId);
    // pruneRunHistory, or a manual clean-up.
    await CatalogPublishRun.deleteOne({
      _id: new mongoose.Types.ObjectId(first.body.runId),
    }).exec();

    const replay = await request(app)
      .post('/catalog/publish')
      .set(auth)
      .set('Idempotency-Key', 'k3')
      .send({});

    // NO WEDGE. A partial index indexes DOCUMENTS, so deleting the run frees
    // its key with it — the create simply succeeds and the user gets the
    // publish they pressed. The `!existing` rethrow in `openRun` covers only
    // the genuine race (the document deleted between our failed create and our
    // read of it), which is why the client also retires its key on a
    // pull-to-refresh: one press recovers a screen, whatever wedged it.
    expect(replay.status).toBe(202);
    expect(replay.body.runId).not.toBe(first.body.runId);
  });

  it('starts a fresh run under a different key', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await publishable(id);

    const first = await request(app)
      .post('/catalog/publish')
      .set(auth)
      .set('Idempotency-Key', 'k4')
      .send({});
    await settle(catalogId, first.body.runId);

    const second = await request(app)
      .post('/catalog/publish')
      .set(auth)
      .set('Idempotency-Key', 'k5')
      .send({});

    expect(second.status).toBe(202);
    expect(second.body.runId).not.toBe(first.body.runId);
  });
});
