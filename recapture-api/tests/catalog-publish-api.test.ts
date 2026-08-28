// tests/catalog-publish-api.test.ts
//
// POST /catalog/publish and /catalog/publish/retry: the gates, the lock, the
// enqueue, and the one write that can never be taken back.
//
// THE ASSERTION THIS FILE EXISTS FOR is the QR-stability one at the bottom.
// `publicUrl` is a string businesses PRINT. Once a sticker is on a table a
// rewrite is not a bug that can be fixed forward — the customer scanning it
// lands nowhere. So the suite proves the URL survives a rename, a republish,
// product churn and a second provisioning attempt, and that an attempt to
// change it throws rather than corrupting.
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
import { Project } from '@/models/Project';
import { ProjectModel } from '@/models/ProjectModel';
import { User } from '@/models/User';
import {
  assertMappingImmutable,
  CatalogMappingImmutableError,
} from '@/services/catalogPublishService';
import { resetMirageClient, setMirageClient } from '@/services/mirage';
import { FakeMirage } from './fixtures/mirageFake';

const app = createApp();
let mongod: MongoMemoryServer;
const mirage = new FakeMirage();

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Catalog.syncIndexes();
  await CatalogProduct.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  mirage.reset();
  setMirageClient(mirage);
  // Optional by schema so an API that never publishes still boots; supplied
  // here the same way tests/catalog-provisioning.test.ts does.
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
    Project.deleteMany({}),
    ProjectModel.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogCategory.deleteMany({}),
    CatalogProduct.deleteMany({}),
    CatalogPublishRun.deleteMany({}),
    Job.deleteMany({}),
    mongoose.connection.collection('ratewindows').deleteMany({}),
  ]);
});

// ── Fixtures ────────────────────────────────────────────────────────────────

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

interface SeedOptions {
  name?: string;
  products?: {
    name: string;
    type?: 'THREE_D' | 'IMAGE_ONLY';
    assets?: Record<string, string>;
    sourceModelId?: Types.ObjectId;
    sourceProjectId?: Types.ObjectId;
    syncStatus?: 'NEVER' | 'SYNCED' | 'FAILED';
  }[];
  catalog?: Record<string, unknown>;
}

async function seed(userId: string, options: SeedOptions = {}): Promise<Types.ObjectId> {
  const catalog = await Catalog.create({
    userId: new Types.ObjectId(userId),
    name: options.name ?? 'Blue Cafe',
    status: 'DRAFT',
    draftRevision: 1,
    publishedRevision: -1,
    ...options.catalog,
  });
  const catalogId = catalog._id as Types.ObjectId;

  const specs = options.products ?? [{ name: 'Chair' }];
  await Promise.all(
    specs.map((spec, index) =>
      CatalogProduct.create({
        catalogId,
        userId: new Types.ObjectId(userId),
        type: spec.type ?? 'IMAGE_ONLY',
        name: spec.name,
        position: index,
        assets: spec.assets ?? { imageKey: `dev/catalog/x/products/p/${index}.jpg` },
        ...(spec.sourceModelId ? { sourceModelId: spec.sourceModelId } : {}),
        ...(spec.sourceProjectId ? { sourceProjectId: spec.sourceProjectId } : {}),
        ...(spec.syncStatus ? { syncStatus: spec.syncStatus } : {}),
      })
    )
  );

  return catalogId;
}

/** A finished model the user owns, plus the assets a 3D product carries. */
async function makeOwnedModel(
  userId: string,
  status: 'SUCCEEDED' | 'FAILED' = 'SUCCEEDED'
): Promise<{ modelId: Types.ObjectId; projectId: Types.ObjectId }> {
  const project = await Project.create({
    userId: new Types.ObjectId(userId),
    name: 'Chair capture',
    objectSize: 'MEDIUM',
    mode: 'GUIDED',
  });
  const model = await ProjectModel.create({
    projectId: project._id,
    jobId: new Types.ObjectId(),
    source: 'meshy',
    status,
    createdByUserId: new Types.ObjectId(userId),
    createdByRole: 'ADMIN',
  });
  return {
    modelId: model._id as Types.ObjectId,
    projectId: project._id as Types.ObjectId,
  };
}

const THREE_D_ASSETS = {
  glbUrl: 'https://test.cloudfront.net/dev/p/model.glb',
  thumbnailUrl: 'https://test.cloudfront.net/dev/p/preview.jpg',
};

// ── Happy path ──────────────────────────────────────────────────────────────

describe('POST /catalog/publish', () => {
  it('returns 202 with a run id and enqueues exactly one job', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id);

    const res = await request(app).post('/catalog/publish').set(auth).send({});

    expect(res.status).toBe(202);
    expect(res.body.status).toBe('success');
    expect(res.body.runId).toMatch(/^[a-f0-9]{24}$/);

    const jobs = await Job.find({ jobType: 'MIRAGE_CATALOG_PUBLISH' }).lean().exec();
    expect(jobs).toHaveLength(1);
    expect(jobs[0].payload).toMatchObject({
      catalogId: catalogId.toHexString(),
      publishRunId: res.body.runId,
      mode: 'FULL',
    });

    const catalog = await Catalog.findById(catalogId).lean().exec();
    expect(catalog?.activePublishRunId?.toHexString()).toBe(res.body.runId);
  });

  it('provisions on the first publish and returns the frozen public URL', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id);

    const res = await request(app).post('/catalog/publish').set(auth).send({});

    expect(res.status).toBe(202);
    const catalog = await Catalog.findById(catalogId).lean().exec();
    expect(catalog?.mirageRestaurantId).toBeDefined();
    expect(catalog?.publicUrl).toBe(`https://menu.test/${catalog?.mirageRestaurantId}`);
    expect(res.body.publicUrl).toBe(catalog?.publicUrl);
  });

  it('captures the revision at RUN CREATION, so an edit just made is included', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id);
    await Catalog.updateOne({ _id: catalogId }, { $set: { draftRevision: 42 } }).exec();

    const res = await request(app).post('/catalog/publish').set(auth).send({});

    const run = await CatalogPublishRun.findById(res.body.runId).lean().exec();
    expect(run?.snapshotRevision).toBe(42);
  });

  it('gives a concurrent second publish 409 and creates no second run', async () => {
    const { id, auth } = await makeUser();
    await seed(id);

    const first = await request(app).post('/catalog/publish').set(auth).send({});
    const second = await request(app).post('/catalog/publish').set(auth).send({});

    expect(first.status).toBe(202);
    expect(second.status).toBe(409);
    expect(second.body.code).toBe('PUBLISH_IN_PROGRESS');
    expect(second.body.runId).toBe(first.body.runId);
    expect(await CatalogPublishRun.countDocuments({})).toBe(1);
    expect(await Job.countDocuments({ jobType: 'MIRAGE_CATALOG_PUBLISH' })).toBe(1);
  });
});

// ── Gates ───────────────────────────────────────────────────────────────────

describe('publish gates', () => {
  it('refuses an empty catalog WITHOUT provisioning it', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id, { products: [] });

    const res = await request(app).post('/catalog/publish').set(auth).send({});

    expect(res.status).toBe(422);
    expect(res.body.code).toBe('PUBLISH_BLOCKED');
    expect(res.body.gates.map((g: { code: string }) => g.code)).toContain('CATALOG_EMPTY');

    // THE POINT of gating before Mirage: a user who tapped Publish too early
    // does not permanently own a restaurant and a public URL for nothing.
    const catalog = await Catalog.findById(catalogId).lean().exec();
    expect(catalog?.mirageRestaurantId).toBeUndefined();
    expect(catalog?.publicUrl).toBeUndefined();
    expect(mirage.calls).toHaveLength(0);
  });

  it('returns EVERY failing gate at once, not just the first', async () => {
    const { id, auth } = await makeUser();
    const { modelId } = await makeOwnedModel(id, 'FAILED');
    await seed(id, {
      products: [
        // No photo.
        { name: 'Stool', type: 'IMAGE_ONLY', assets: {} },
        // No model, no thumbnail, and its source model never finished.
        { name: 'Table', type: 'THREE_D', assets: {}, sourceModelId: modelId },
        // Duplicate name.
        { name: 'Stool', type: 'IMAGE_ONLY', assets: { imageKey: 'dev/x.jpg' } },
      ],
    });

    const res = await request(app).post('/catalog/publish').set(auth).send({});

    expect(res.status).toBe(422);
    const codes = new Set(res.body.gates.map((g: { code: string }) => g.code));
    expect(codes).toContain('PRODUCT_ASSET_MISSING');
    expect(codes).toContain('PRODUCT_THUMBNAIL_MISSING');
    expect(codes).toContain('PRODUCT_MODEL_NOT_READY');
    expect(codes).toContain('PRODUCT_NAME_DUPLICATE');
  });

  it('blocks a 3D product whose preview has not been generated', async () => {
    const { id, auth } = await makeUser();
    const { modelId } = await makeOwnedModel(id);
    await seed(id, {
      products: [
        {
          name: 'Chair',
          type: 'THREE_D',
          sourceModelId: modelId,
          assets: { glbUrl: THREE_D_ASSETS.glbUrl },
        },
      ],
    });

    const res = await request(app).post('/catalog/publish').set(auth).send({});

    expect(res.status).toBe(422);
    expect(res.body.gates.map((g: { code: string }) => g.code)).toContain(
      'PRODUCT_THUMBNAIL_MISSING'
    );
  });

  it('blocks a 3D product whose model belongs to somebody else', async () => {
    const { id, auth } = await makeUser();
    const stranger = await makeUser();
    const { modelId } = await makeOwnedModel(stranger.id);
    await seed(id, {
      products: [
        { name: 'Chair', type: 'THREE_D', sourceModelId: modelId, assets: THREE_D_ASSETS },
      ],
    });

    const res = await request(app).post('/catalog/publish').set(auth).send({});

    expect(res.status).toBe(422);
    expect(res.body.gates.map((g: { code: string }) => g.code)).toContain(
      'PRODUCT_MODEL_NOT_READY'
    );
  });

  it('passes a fully-formed 3D product', async () => {
    const { id, auth } = await makeUser();
    const { modelId, projectId } = await makeOwnedModel(id);
    await seed(id, {
      products: [
        {
          name: 'Chair',
          type: 'THREE_D',
          sourceModelId: modelId,
          sourceProjectId: projectId,
          assets: THREE_D_ASSETS,
        },
      ],
    });

    const res = await request(app).post('/catalog/publish').set(auth).send({});

    expect(res.status).toBe(202);
  });

  it('does not gate on an ARCHIVED product that is missing its assets', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id, {
      products: [
        { name: 'Chair' },
        { name: 'Ghost', type: 'IMAGE_ONLY', assets: {} },
      ],
    });
    await CatalogProduct.updateOne(
      { catalogId, name: 'Ghost' },
      { $set: { archivedAt: new Date() } }
    ).exec();

    const res = await request(app).post('/catalog/publish').set(auth).send({});

    // An archived product is on its way OFF the public page; blocking the
    // publish over its missing photo would trap the user with no way out.
    expect(res.status).toBe(202);
  });

  // ── Categories ───────────────────────────────────────────────────────────
  //
  // A category is a TAB on the public page, so a wrong one is not a silent
  // data problem — it is a label a customer reads. These three prove the check
  // runs before anything reaches Mirage.

  it('blocks a product filed under a category this catalog no longer has', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id, { products: [{ name: 'Chair' }] });
    const category = await CatalogCategory.create({
      catalogId,
      userId: new Types.ObjectId(id),
      name: 'seating',
      position: 0,
    });
    await CatalogProduct.updateOne(
      { catalogId, name: 'Chair' },
      { $set: { categoryId: category._id } }
    ).exec();
    // Straight to deleted, WITHOUT the service's move-to-Uncategorized step —
    // the dangling state a race, a restore or a hand-edited document leaves.
    await CatalogCategory.updateOne(
      { _id: category._id },
      { $set: { deletedAt: new Date() } }
    ).exec();

    const res = await request(app).post('/catalog/publish').set(auth).send({});

    expect(res.status).toBe(422);
    expect(res.body.code).toBe('PUBLISH_BLOCKED');
    const gate = res.body.gates.find(
      (g: { code: string }) => g.code === 'PRODUCT_CATEGORY_UNKNOWN'
    );
    expect(gate.productName).toBe('Chair');

    // Blocked BEFORE Mirage, like every other gate: no restaurant, no URL, and
    // above all no tab created for a category that does not exist here.
    const catalog = await Catalog.findById(catalogId).lean().exec();
    expect(catalog?.mirageRestaurantId).toBeUndefined();
    expect(mirage.calls).toHaveLength(0);
    expect(await CatalogPublishRun.countDocuments({})).toBe(0);
  });

  it('blocks a category whose name would reach Mirage as nothing at all', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id, { products: [{ name: 'Chair' }] });
    // No letters or digits: `toCatalogSlug` returns ''. The validation layer
    // refuses this today, so it can only be a row written before it or seeded
    // straight into the collection — and a FULL publish pushes EVERY live
    // category, product under it or not.
    await CatalogCategory.create({
      catalogId,
      userId: new Types.ObjectId(id),
      name: '!!!',
      position: 0,
    });

    const res = await request(app).post('/catalog/publish').set(auth).send({});

    expect(res.status).toBe(422);
    expect(res.body.gates.map((g: { code: string }) => g.code)).toContain(
      'CATEGORY_NAME_INVALID'
    );
    expect(mirage.calls).toHaveLength(0);
  });

  it('passes a product filed under a live category of the same catalog', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id, { products: [{ name: 'Chair' }] });
    const category = await CatalogCategory.create({
      catalogId,
      userId: new Types.ObjectId(id),
      name: 'seating',
      position: 0,
    });
    await CatalogProduct.updateOne(
      { catalogId, name: 'Chair' },
      { $set: { categoryId: category._id } }
    ).exec();

    const res = await request(app).post('/catalog/publish').set(auth).send({});

    expect(res.status).toBe(202);
  });
});

// ── Retry ───────────────────────────────────────────────────────────────────

describe('POST /catalog/publish/retry', () => {
  it('enqueues a RETRY_FAILED run when something failed', async () => {
    const { id, auth } = await makeUser();
    await seed(id, {
      products: [{ name: 'Chair', syncStatus: 'FAILED' }],
      catalog: { mirageRestaurantId: 'mr-1', publicUrl: 'https://menu.test/mr-1' },
    });

    const res = await request(app).post('/catalog/publish/retry').set(auth).send({});

    expect(res.status).toBe(202);
    const job = await Job.findOne({ jobType: 'MIRAGE_CATALOG_PUBLISH' }).lean().exec();
    expect(job?.payload).toMatchObject({ mode: 'RETRY_FAILED' });
  });

  it('succeeds with nothing queued when no row failed', async () => {
    const { id, auth } = await makeUser();
    await seed(id, { products: [{ name: 'Chair', syncStatus: 'SYNCED' }] });

    const res = await request(app).post('/catalog/publish/retry').set(auth).send({});

    // The user asked for "make the failures go away" and there are none — that
    // is the state they wanted, not an error.
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ status: 'success', runId: null, queued: false });
    expect(await Job.countDocuments({})).toBe(0);
  });

  it('gets the same 409 while a publish is running', async () => {
    const { id, auth } = await makeUser();
    await seed(id, { products: [{ name: 'Chair', syncStatus: 'FAILED' }] });
    await request(app).post('/catalog/publish').set(auth).send({});

    const res = await request(app).post('/catalog/publish/retry').set(auth).send({});

    expect(res.status).toBe(409);
    expect(res.body.code).toBe('PUBLISH_IN_PROGRESS');
  });

  it('is rate limited so a repeated tap cannot queue a job each time', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id, { products: [{ name: 'Chair', syncStatus: 'FAILED' }] });

    let limited = false;
    for (let i = 0; i < env.PUBLISH_RETRY_MAX_PER_WINDOW + 2; i++) {
      // Release the lock each time so the limiter, not the lock, is under test.
      await Catalog.updateOne({ _id: catalogId }, { $set: { activePublishRunId: null } }).exec();
      const res = await request(app).post('/catalog/publish/retry').set(auth).send({});
      if (res.status === 429) {
        limited = true;
        expect(res.body.code).toBe('RATE_LIMITED');
        expect(res.body.retryAfter).toBeGreaterThan(0);
        break;
      }
    }
    expect(limited).toBe(true);
  });
});

// ── Ownership ───────────────────────────────────────────────────────────────

describe('ownership', () => {
  it('gives a user with no catalog the same 404 as a nonexistent one', async () => {
    const { auth } = await makeUser();
    const stranger = await makeUser();
    await seed(stranger.id);

    const publish = await request(app).post('/catalog/publish').set(auth).send({});
    const status = await request(app).get('/catalog/publish/status').set(auth);

    expect(publish.status).toBe(404);
    expect(publish.body.code).toBe('CATALOG_NOT_FOUND');
    expect(status.status).toBe(404);
    expect(status.body.code).toBe('CATALOG_NOT_FOUND');
  });

  it('rejects an unauthenticated call', async () => {
    const res = await request(app).post('/catalog/publish').send({});
    expect(res.status).toBe(401);
  });
});

// ── The frozen URL (feature 32) ─────────────────────────────────────────────

describe('the public URL is frozen once written', () => {
  it('survives a rename, a republish and product churn', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id);

    await request(app).post('/catalog/publish').set(auth).send({});
    const minted = (await Catalog.findById(catalogId).lean().exec())?.publicUrl;
    expect(minted).toBeDefined();

    // Rename.
    await request(app).patch('/catalog').set(auth).send({ name: 'Green Cafe' });
    // Product churn.
    await CatalogProduct.create({
      catalogId,
      userId: new Types.ObjectId(id),
      type: 'IMAGE_ONLY',
      name: 'Stool',
      position: 1,
      assets: { imageKey: 'dev/x.jpg' },
    });
    await CatalogProduct.deleteOne({ catalogId, name: 'Chair' }).exec();
    // Republish.
    await Catalog.updateOne({ _id: catalogId }, { $set: { activePublishRunId: null } }).exec();
    await request(app).post('/catalog/publish').set(auth).send({});

    expect((await Catalog.findById(catalogId).lean().exec())?.publicUrl).toBe(minted);
  });

  it('is not repointed by a later change to MIRAGE_PUBLIC_BASE_URL', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id);
    await request(app).post('/catalog/publish').set(auth).send({});
    const minted = (await Catalog.findById(catalogId).lean().exec())?.publicUrl;

    // The host moves. Already-printed QR codes must keep resolving.
    Object.assign(env, { MIRAGE_PUBLIC_BASE_URL: 'https://different.test' });
    await Catalog.updateOne({ _id: catalogId }, { $set: { activePublishRunId: null } }).exec();
    await request(app).post('/catalog/publish').set(auth).send({});

    expect((await Catalog.findById(catalogId).lean().exec())?.publicUrl).toBe(minted);
    expect(minted).toContain('https://menu.test/');
  });

  it('throws when any code path tries to overwrite the mapping', () => {
    const stored = { mirageRestaurantId: 'mr-1', publicUrl: 'https://menu.test/mr-1' };

    expect(() => assertMappingImmutable(stored, { mirageRestaurantId: 'mr-2' })).toThrow(
      CatalogMappingImmutableError
    );
    expect(() => assertMappingImmutable(stored, { publicUrl: 'https://other.test/x' })).toThrow(
      CatalogMappingImmutableError
    );

    // Writing the SAME value is not a rewrite, and a first write is not either.
    expect(() => assertMappingImmutable(stored, { mirageRestaurantId: 'mr-1' })).not.toThrow();
    expect(() => assertMappingImmutable({}, { mirageRestaurantId: 'mr-9' })).not.toThrow();
  });
});
