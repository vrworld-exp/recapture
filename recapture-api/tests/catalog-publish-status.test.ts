// tests/catalog-publish-status.test.ts
//
// GET /catalog/publish/status — features 37, 38, 52.
//
// The property under test is that this endpoint is SERVER TRUTH. Nothing in the
// payload is derived from anything the client holds, which is the only way
// "publishing… 7 of 10" can be honest on a phone and a tablet at the same time,
// and the only way `hasDraftChanges` can be trusted after a PARTIAL run.
//
// `hasDraftChanges` is the one to watch: it is `draftRevision >
// publishedRevision`, DERIVED on every read. A stored dirty flag would drift the
// first time a run half-succeeded, and the badge would lie in the direction that
// costs a business customers — telling them their edits are live when they are
// not.
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

async function seed(
  userId: string,
  catalogOverrides: Record<string, unknown> = {}
): Promise<Types.ObjectId> {
  const catalog = await Catalog.create({
    userId: new Types.ObjectId(userId),
    name: 'Blue Cafe',
    status: 'DRAFT',
    draftRevision: 1,
    publishedRevision: -1,
    ...catalogOverrides,
  });
  const catalogId = catalog._id as Types.ObjectId;
  await CatalogProduct.create({
    catalogId,
    userId: new Types.ObjectId(userId),
    type: 'IMAGE_ONLY',
    name: 'Chair',
    position: 0,
    assets: { imageKey: 'dev/catalog/x/products/p/0.jpg' },
  });
  return catalogId;
}

describe('GET /catalog/publish/status', () => {
  it('reports a never-published catalog honestly', async () => {
    const { id, auth } = await makeUser();
    await seed(id);

    const res = await request(app).get('/catalog/publish/status').set(auth);

    expect(res.status).toBe(200);
    expect(res.body.publish).toMatchObject({
      status: 'DRAFT',
      hasDraftChanges: true,
      publicUrl: null,
      lastPublishedAt: null,
      activeRunId: null,
      run: null,
    });
    expect(res.body.publish.products).toHaveLength(1);
    expect(res.body.publish.products[0]).toMatchObject({
      name: 'Chair',
      type: 'IMAGE_ONLY',
      syncStatus: 'NEVER',
    });
  });

  it('returns the per-product failure with OUR code and OUR sentence', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id);
    await CatalogProduct.updateOne(
      { catalogId },
      {
        $set: {
          syncStatus: 'FAILED',
          syncError: {
            code: 'PUBLISH_DUPLICATE_NAME',
            message: 'Another item in this catalog already uses this name.',
            at: new Date(),
          },
        },
      }
    ).exec();

    const res = await request(app).get('/catalog/publish/status').set(auth);

    const product = res.body.publish.products[0];
    expect(product.code).toBe('PUBLISH_DUPLICATE_NAME');
    expect(product.message).toMatch(/already uses this name/);
    // Mirage's own prose never reaches a response body.
    expect(JSON.stringify(res.body)).not.toContain('Product already exist');
  });

  it('projects products FIELD BY FIELD — no mapping or internal field leaks', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id);
    await CatalogProduct.updateOne(
      { catalogId },
      {
        $set: {
          mirageItemId: 'mi-secret',
          mirageCategoryIdAtSync: 'mc-secret',
          publishedSnapshot: { name: 'Chair' },
        },
      }
    ).exec();

    const res = await request(app).get('/catalog/publish/status').set(auth);

    const body = JSON.stringify(res.body);
    expect(body).not.toContain('mi-secret');
    expect(body).not.toContain('mc-secret');
    expect(body).not.toContain('publishedSnapshot');
    expect(Object.keys(res.body.publish.products[0]).sort()).toEqual([
      'id',
      'name',
      'syncStatus',
      'type',
    ]);
  });

  it('surfaces the active run id while one is in flight', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    const queued = await request(app).post('/catalog/publish').set(auth).send({});

    const res = await request(app).get('/catalog/publish/status').set(auth);

    expect(res.body.publish.activeRunId).toBe(queued.body.runId);
    expect(res.body.publish.run).toMatchObject({
      id: queued.body.runId,
      state: 'QUEUED',
      mode: 'FULL',
      counts: { total: 0, synced: 0, failed: 0, skipped: 0 },
    });
  });

  it('is identical for two callers with the same token — no client-local state', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    await request(app).post('/catalog/publish').set(auth).send({});

    const [a, b] = await Promise.all([
      request(app).get('/catalog/publish/status').set(auth),
      request(app).get('/catalog/publish/status').set(auth),
    ]);

    expect(a.body).toEqual(b.body);
  });

  it('carries the gates so the Publish button can explain itself before it is pressed', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id);
    await CatalogProduct.deleteMany({ catalogId }).exec();

    const res = await request(app).get('/catalog/publish/status').set(auth);

    expect(res.body.publish.gates.map((g: { code: string }) => g.code)).toContain(
      'CATALOG_EMPTY'
    );
  });
});

describe('hasDraftChanges (feature 38)', () => {
  it('is false only when the published revision has caught up', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id, { draftRevision: 7, publishedRevision: 7 });

    const clean = await request(app).get('/catalog/publish/status').set(auth);
    expect(clean.body.publish.hasDraftChanges).toBe(false);

    // Any authoring write bumps the draft revision.
    await Catalog.updateOne({ _id: catalogId }, { $inc: { draftRevision: 1 } }).exec();

    const dirty = await request(app).get('/catalog/publish/status').set(auth);
    expect(dirty.body.publish.hasDraftChanges).toBe(true);
  });

  it('flips true on a real authoring write through the API', async () => {
    const { id, auth } = await makeUser();
    await seed(id, { draftRevision: 3, publishedRevision: 3 });

    expect((await request(app).get('/catalog/publish/status').set(auth)).body.publish
      .hasDraftChanges).toBe(false);

    await request(app).patch('/catalog').set(auth).send({ name: 'Green Cafe' });

    expect((await request(app).get('/catalog/publish/status').set(auth)).body.publish
      .hasDraftChanges).toBe(true);
  });

  it('STAYS true after a PARTIAL run — some products really are not live', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id, { draftRevision: 9, publishedRevision: 4 });
    await CatalogPublishRun.create({
      catalogId,
      userId: new Types.ObjectId(id),
      jobId: new Types.ObjectId(),
      snapshotRevision: 9,
      mode: 'FULL',
      state: 'PARTIAL',
      counts: { total: 3, synced: 2, failed: 1, skipped: 0 },
      startedAt: new Date(),
      finishedAt: new Date(),
    });

    const res = await request(app).get('/catalog/publish/status').set(auth);

    expect(res.body.publish.run.state).toBe('PARTIAL');
    expect(res.body.publish.hasDraftChanges).toBe(true);
  });
});

describe('status after a worker died mid-run', () => {
  it('is still readable and still names the run', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id);
    const queued = await request(app).post('/catalog/publish').set(auth).send({});

    // The lease expired; the run is RUNNING with entries and no finishedAt.
    await CatalogPublishRun.updateOne(
      { _id: queued.body.runId },
      {
        $set: {
          state: 'RUNNING',
          startedAt: new Date(),
          counts: { total: 4, synced: 2, failed: 0, skipped: 0 },
        },
      }
    ).exec();

    const res = await request(app).get('/catalog/publish/status').set(auth);

    expect(res.body.publish.run).toMatchObject({
      state: 'RUNNING',
      counts: { total: 4, synced: 2 },
      finishedAt: null,
    });
    // The lock is still held, so the client correctly shows "publishing…"
    // rather than offering a second Publish that would race the re-claim.
    expect(res.body.publish.activeRunId).toBe(queued.body.runId);
    expect((await Catalog.findById(catalogId).lean().exec())?.activePublishRunId).not.toBeNull();
  });
});
