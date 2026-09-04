// tests/catalog-model-promotion.test.ts
//
// Stage 5: a dish reaches the menu before its 3D model exists, and gains its AR
// button on its own when Meshy returns.
//
// TWO ASSERTIONS HERE CARRY THE SUITE.
//
// The first is LOCK CONTENTION. Six dishes finishing within seconds of each
// other collide on the publish lock, and the loser's `requestPublish` answers
// IN_PROGRESS. If promotion treated that as a failure — or, worse, wrote its
// fields after the enqueue — the dish would silently never get its assets at
// all. The test holds the lock deliberately and asserts the rows are complete
// anyway.
//
// The second is that a PROMOTION FAILURE DOES NOT FAIL THE JOB. The generation
// it runs after has already been paid for; throwing out of promotion would fail
// a job whose retry pays Meshy a second time for a model that already exists.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import mongoose, { Types } from 'mongoose';
import axios from 'axios';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { env } from '@/config/env';
import { s3Client } from '@/config/s3';
import { Catalog } from '@/models/Catalog';
import { CatalogProduct } from '@/models/CatalogProduct';
import { CatalogPublishRun } from '@/models/CatalogPublishRun';
import { Job } from '@/models/Job';
import { Project } from '@/models/Project';
import { ProjectModel, type IProjectModel } from '@/models/ProjectModel';
import { User } from '@/models/User';
import {
  promoteModelToProducts,
  sweepPromotedProducts,
} from '@/services/catalogModelPromotionService';
import { createProduct } from '@/services/catalogProductsService';
import { buildJobKeyPrefix } from '@/utils/s3Keys';
import { meshyModelProcessor } from '@/worker/processors/meshyModelProcessor';
import {
  meshyClient,
  setMeshyClient,
  type MeshyClient,
  type MeshyTask,
} from '@/worker/engine/meshy/meshyClient';
import type { WorkerJob } from '@/worker/workerTypes';

let mongod: MongoMemoryServer;
const WORKER_ID = 'worker-test-1';

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Catalog.syncIndexes();
  await CatalogProduct.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
  setMeshyClient(meshyClient);
});

beforeEach(() => {
  // @ts-expect-error — env is a plain parsed object.
  env.MESHY_POLL_INTERVAL_MS = 1;
  // Mirage is never called by this suite: promotion's publish enqueue stops at
  // the gates, which is exactly the "publish not enqueued" path under test.
  Object.assign(env, { MIRAGE_BASE_URL: undefined, MIRAGE_API_KEY: undefined });
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'info').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
});

afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all([
    Job.deleteMany({}),
    Project.deleteMany({}),
    ProjectModel.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogProduct.deleteMany({}),
    CatalogPublishRun.deleteMany({}),
    User.deleteMany({}),
  ]);
});

// ── Fixtures ────────────────────────────────────────────────────────────────

function task(overrides: Partial<MeshyTask> = {}): MeshyTask {
  return {
    id: 'task-1',
    status: 'SUCCEEDED',
    progress: 100,
    modelUrls: { glb: 'https://meshy.example/out.glb' },
    thumbnailUrl: 'https://meshy.example/preview.jpg',
    ...overrides,
  };
}

function fakeClient(over: Partial<MeshyClient> = {}) {
  const client: MeshyClient = {
    createMultiImageTask: vi.fn().mockResolvedValue({ taskId: 'task-1' }),
    getTask: vi.fn().mockResolvedValue(task()),
    cancelTask: vi.fn().mockResolvedValue(undefined),
    ...over,
  };
  setMeshyClient(client);
  return client;
}

function mockS3(): void {
  vi.spyOn(s3Client, 'send').mockImplementation((async () => ({})) as never);
  vi.spyOn(axios, 'get').mockResolvedValue({ data: new ArrayBuffer(8) });
}

/** An owner, their catalog, a capture project, and a QUEUED model on it. */
async function seed(recordOverrides: Partial<IProjectModel> = {}) {
  const user = await User.create({
    authProvider: 'custom',
    authUid: `test|${new Types.ObjectId().toHexString()}`,
  });
  const userId = user._id as Types.ObjectId;

  const catalog = await Catalog.create({ userId, name: 'Blue Cafe' });
  const project = await Project.create({
    userId,
    name: 'P',
    objectSize: 'MEDIUM',
    mode: 'GUIDED',
    status: 'PROCESSING',
  });

  const captureJobId = new Types.ObjectId();
  const prefix = buildJobKeyPrefix({
    projectName: project.name,
    projectId: project.id as string,
    jobId: captureJobId.toHexString(),
  });
  await Job.create({
    _id: captureJobId,
    projectId: project._id,
    userId,
    state: 'QUEUED',
    upload: {
      uploadMethod: 'S3_PRESIGNED_MULTIPART',
      expectedFilesCount: 3,
      uploadedFilesCount: 3,
      checksumAlgo: 'md5',
      rawBucket: 'recapture-test-raw',
      rawPrefix: prefix,
      manifestKey: `${prefix}capture_manifest.json`,
    },
  });

  const record = await ProjectModel.create({
    projectId: project._id,
    jobId: captureJobId,
    source: 'meshy',
    status: 'QUEUED',
    selectedKeys: ['images/EYE/a.jpg', 'images/EYE/b.jpg', 'images/TOP/c.jpg'],
    createdByUserId: new Types.ObjectId(),
    createdByRole: 'MODEL_ARTIST',
    ...recordOverrides,
  });

  return { userId, catalogId: catalog._id as Types.ObjectId, project, record, captureJobId };
}

/** The claimed generation job, as the worker loop leaves it. */
async function generationJob(
  seeded: Awaited<ReturnType<typeof seed>>
): Promise<WorkerJob> {
  const genJob = await Job.create({
    projectId: seeded.project._id,
    userId: seeded.userId,
    jobType: 'MESHY_MODEL_GENERATION',
    state: 'PROCESSING',
    claimedBy: WORKER_ID,
    claimedAt: new Date(),
    payload: { modelId: seeded.record.id as string },
  });
  return {
    _id: genJob._id as Types.ObjectId,
    projectId: seeded.project._id as Types.ObjectId,
    userId: seeded.userId,
    state: 'PROCESSING',
    jobType: 'MESHY_MODEL_GENERATION',
    claimedBy: WORKER_ID,
    attempts: 0,
    maxAttempts: 3,
    payload: { modelId: seeded.record.id as string },
    createdAt: new Date(),
    updatedAt: new Date(),
  };
}

/**
 * Takes the catalog's publish lock with a REAL run behind it.
 *
 * A bare `activePublishRunId` pointing at nothing is not a held lock: the next
 * `hasActiveRun` correctly reads it as abandoned and releases it. The run
 * document has to exist for the contention this suite is about to be real.
 */
async function holdPublishLock(
  catalogId: Types.ObjectId,
  userId: Types.ObjectId
): Promise<Types.ObjectId> {
  const run = await CatalogPublishRun.create({
    catalogId,
    userId,
    jobId: new Types.ObjectId(),
    snapshotRevision: 0,
    mode: 'FULL',
    state: 'RUNNING',
  });
  const runId = run._id as Types.ObjectId;
  await Catalog.updateOne({ _id: catalogId }, { $set: { activePublishRunId: runId } }).exec();
  return runId;
}

/** Links a dish to a model through the REAL service, not a hand-written row. */
async function linkDish(userId: Types.ObjectId, modelId: string, name = 'Chair') {
  const result = await createProduct(String(userId), {
    type: 'THREE_D',
    name,
    sourceModelId: modelId,
  } as Parameters<typeof createProduct>[1]);
  if (result.outcome !== 'CREATED') throw new Error(`link failed: ${result.outcome}`);
  return result.product;
}

// ── Linking a model that has not finished ───────────────────────────────────

describe('linking a pending model', () => {
  it('creates a real THREE_D product with no assets', async () => {
    const { userId, record } = await seed({ status: 'PROCESSING' });

    const product = await linkDish(userId, record.id as string);

    expect(product.modelStatus).toBe('PROCESSING');
    expect(product.glbUrl).toBeNull();
    expect(product.sourceModelId).toBe(record.id);

    const row = await CatalogProduct.findById(product.id).exec();
    expect(row!.type).toBe('THREE_D');
    expect(row!.assets?.glbUrl).toBeUndefined();
  });

  it("refuses someone else's pending model as NOT_FOUND, never NOT_READY", async () => {
    // THE OWNERSHIP CHECK MUST NOT HAVE BEEN LOOSENED along with the status
    // check. A stranger's model is not-found, exactly as before — anything
    // else would confirm that someone else's model exists.
    const owner = await seed({ status: 'PROCESSING' });
    const stranger = await seed({ status: 'PROCESSING' });

    const result = await createProduct(String(stranger.userId), {
      type: 'THREE_D',
      name: 'Chair',
      sourceModelId: owner.record.id as string,
    } as Parameters<typeof createProduct>[1]);

    expect(result.outcome).toBe('MODEL_NOT_FOUND');
  });

  it('refuses a FAILED model — nothing is coming for it', async () => {
    const { userId, record } = await seed({ status: 'FAILED' });

    const result = await createProduct(String(userId), {
      type: 'THREE_D',
      name: 'Chair',
      sourceModelId: record.id as string,
    } as Parameters<typeof createProduct>[1]);

    expect(result.outcome).toBe('MODEL_NOT_READY');
  });
});

// ── Promotion ───────────────────────────────────────────────────────────────

describe('promotion', () => {
  it('flips a waiting dish to READY through the real processor', async () => {
    const seeded = await seed({ status: 'PROCESSING' });
    const product = await linkDish(seeded.userId, seeded.record.id as string);
    const before = await Catalog.findById(seeded.catalogId).exec();

    fakeClient();
    mockS3();
    await meshyModelProcessor(await generationJob(seeded));

    const row = await CatalogProduct.findById(product.id).exec();
    expect(row!.modelStatus).toBe('READY');
    expect(row!.assets?.glbUrl).toContain('/model.glb');
    expect(row!.assets?.thumbnailUrl).toContain('/preview.jpg');
    // PENDING is what the planner reads to decide this row has something to
    // send; without it the dish would sit on the menu in 2D until some
    // unrelated edit happened to touch it.
    expect(row!.syncStatus).toBe('PENDING');

    const after = await Catalog.findById(seeded.catalogId).exec();
    expect(after!.draftRevision).toBeGreaterThan(before!.draftRevision);
  });

  it('COPIES the assets — a later change to the model does not follow', async () => {
    const seeded = await seed({ status: 'PROCESSING' });
    const product = await linkDish(seeded.userId, seeded.record.id as string);
    fakeClient();
    mockS3();
    await meshyModelProcessor(await generationJob(seeded));

    const copied = (await CatalogProduct.findById(product.id).exec())!.assets?.glbUrl;

    await ProjectModel.updateOne(
      { _id: seeded.record._id },
      { $set: { 'artifacts.cdnUrls.glb': 'https://cdn.example/REGENERATED.glb' } }
    ).exec();

    // A regeneration must not silently change what an already-published product
    // points at. The product is a snapshot of the model it was given.
    const row = await CatalogProduct.findById(product.id).exec();
    expect(row!.assets?.glbUrl).toBe(copied);
    expect(row!.assets?.glbUrl).not.toContain('REGENERATED');
  });

  it('is idempotent — a second run writes nothing', async () => {
    const seeded = await seed({ status: 'PROCESSING' });
    const product = await linkDish(seeded.userId, seeded.record.id as string);
    fakeClient();
    mockS3();
    await meshyModelProcessor(await generationJob(seeded));

    const afterFirst = await Catalog.findById(seeded.catalogId).exec();
    const assets = (await CatalogProduct.findById(product.id).exec())!.assets;

    // The worker may re-run this processor after a crash or a lease takeover.
    const second = await promoteModelToProducts(seeded.record._id as Types.ObjectId);

    // The modelStatus filter is what makes this true: a READY row matches
    // nothing, so there is no second write and no second revision bump.
    expect(second.promoted).toBe(0);
    const afterSecond = await Catalog.findById(seeded.catalogId).exec();
    expect(afterSecond!.draftRevision).toBe(afterFirst!.draftRevision);
    expect((await CatalogProduct.findById(product.id).exec())!.assets).toEqual(assets);
  });

  it('leaves a dish that linked the model AFTER it finished alone', async () => {
    // Linked at OK (not OK_PENDING), so it is already READY and is not waiting.
    const seeded = await seed({ status: 'PROCESSING' });
    fakeClient();
    mockS3();
    await meshyModelProcessor(await generationJob(seeded));

    const product = await linkDish(seeded.userId, seeded.record.id as string, 'Table');
    expect(product.modelStatus).toBe('READY');

    const result = await promoteModelToProducts(seeded.record._id as Types.ObjectId);
    expect(result.promoted).toBe(0);
  });
});

// ── The lock ────────────────────────────────────────────────────────────────

describe('publish lock contention', () => {
  it('loses the enqueue race without losing the promotion', async () => {
    // THE STAGE'S HEADLINE TEST.
    const seeded = await seed({ status: 'PROCESSING' });
    const product = await linkDish(seeded.userId, seeded.record.id as string);
    const before = await Catalog.findById(seeded.catalogId).exec();

    // Somebody else's run holds the lock, exactly as a sibling dish finishing
    // two seconds earlier would.
    const heldRunId = await holdPublishLock(seeded.catalogId, seeded.userId);

    fakeClient();
    mockS3();
    await expect(meshyModelProcessor(await generationJob(seeded))).resolves.toBeDefined();

    // The rows are the source of truth and they are complete. A lost race costs
    // publish LATENCY, never a promotion.
    const row = await CatalogProduct.findById(product.id).exec();
    expect(row!.modelStatus).toBe('READY');
    expect(row!.assets?.glbUrl).toBeTruthy();
    expect(row!.syncStatus).toBe('PENDING');

    const after = await Catalog.findById(seeded.catalogId).exec();
    expect(after!.draftRevision).toBeGreaterThan(before!.draftRevision);
    // And no second run was created behind the held one.
    expect(await CatalogPublishRun.countDocuments({ catalogId: seeded.catalogId })).toBe(1);
    expect(String(after!.activePublishRunId)).toBe(String(heldRunId));
  });

  it('the finalize sweep enqueues exactly one follow-up run once the lock clears', async () => {
    // Publishing has to be genuinely available for this one, or the sweep would
    // be asserted against the gate rather than against the follow-up it exists
    // to create. Provisioned up front so requestPublish makes no Mirage call.
    Object.assign(env, {
      MIRAGE_BASE_URL: 'https://mirage.test',
      MIRAGE_API_KEY: 'test-api-key',
      MIRAGE_ADMIN_TOKEN: 'test-admin-token',
      MIRAGE_PUBLIC_BASE_URL: 'https://menu.test',
    });

    const seeded = await seed({ status: 'PROCESSING' });
    const product = await linkDish(seeded.userId, seeded.record.id as string);
    await Catalog.updateOne(
      { _id: seeded.catalogId },
      {
        $set: {
          mirageRestaurantId: '507f1f77bcf86cd799439011',
          publicUrl: 'https://menu.test/507f1f77bcf86cd799439011',
          publicUrlScheme: 'MIRAGE_OBJECT_ID',
        },
      }
    ).exec();

    const snapshotRevision = (await Catalog.findById(seeded.catalogId).exec())!.draftRevision;
    const heldRunId = await holdPublishLock(seeded.catalogId, seeded.userId);

    fakeClient();
    mockS3();
    await meshyModelProcessor(await generationJob(seeded));

    // Promotion lost the enqueue race — one run exists, and it is the held one.
    expect(await CatalogPublishRun.countDocuments({ catalogId: seeded.catalogId })).toBe(1);
    const row = await CatalogProduct.findById(product.id).exec();
    expect(row!.syncStatus).toBe('PENDING');
    expect(row!.modelStatus).toBe('READY');

    // The held run finishes: finalizeCatalogAfterRun clears the lock, and the
    // sweep runs in the one moment it is guaranteed free.
    await Catalog.updateOne(
      { _id: seeded.catalogId },
      { $set: { activePublishRunId: null } }
    ).exec();
    await CatalogPublishRun.updateOne({ _id: heldRunId }, { $set: { state: 'SUCCEEDED' } }).exec();

    expect(await sweepPromotedProducts(seeded.catalogId, snapshotRevision)).toBe(true);

    // Exactly ONE follow-up, and it holds the lock it just took.
    const runs = await CatalogPublishRun.find({ catalogId: seeded.catalogId })
      .sort({ createdAt: 1 })
      .exec();
    expect(runs).toHaveLength(2);
    expect(runs[1].state).toBe('QUEUED');
    expect(runs[1].snapshotRevision).toBeGreaterThan(snapshotRevision);
    const after = await Catalog.findById(seeded.catalogId).exec();
    expect(String(after!.activePublishRunId)).toBe(String(runs[1]._id));

    // ONE FOLLOW-UP, NOT A LOOP. A second sweep against the same revision finds
    // the lock held by the run it just created and adds nothing.
    expect(await sweepPromotedProducts(seeded.catalogId, snapshotRevision)).toBe(false);
    expect(await CatalogPublishRun.countDocuments({ catalogId: seeded.catalogId })).toBe(2);
  });

  it('the sweep does nothing when the run already covered the rows', async () => {
    const seeded = await seed({ status: 'PROCESSING' });
    await linkDish(seeded.userId, seeded.record.id as string);
    fakeClient();
    mockS3();
    await meshyModelProcessor(await generationJob(seeded));

    // A run planned from the CURRENT revision has, by definition, the promoted
    // rows in its snapshot — no follow-up is owed.
    const current = (await Catalog.findById(seeded.catalogId).exec())!.draftRevision;
    expect(await sweepPromotedProducts(seeded.catalogId, current)).toBe(false);
  });
});

// ── Failure paths ───────────────────────────────────────────────────────────

describe('failures', () => {
  it('a promotion failure does not fail the generation job', async () => {
    const seeded = await seed({ status: 'PROCESSING' });
    await linkDish(seeded.userId, seeded.record.id as string);

    // The generation is already paid for. Throwing here would fail a job whose
    // retry pays Meshy a second time for a model that already exists.
    vi.spyOn(CatalogProduct, 'updateMany').mockImplementation(() => {
      throw new Error('promotion exploded');
    });

    fakeClient();
    mockS3();
    await expect(meshyModelProcessor(await generationJob(seeded))).resolves.toBeDefined();

    const model = await ProjectModel.findById(seeded.record._id).exec();
    expect(model!.status).toBe('SUCCEEDED');
    expect(model!.artifacts?.cdnUrls?.glb).toBeTruthy();
  });

  it('a failed generation marks the dish FAILED and leaves it on the menu', async () => {
    const seeded = await seed({ status: 'PROCESSING' });
    const product = await linkDish(seeded.userId, seeded.record.id as string);

    fakeClient({ getTask: vi.fn().mockResolvedValue(task({ status: 'FAILED' })) });
    mockS3();
    await expect(meshyModelProcessor(await generationJob(seeded))).rejects.toThrow();

    const row = await CatalogProduct.findById(product.id).exec();
    // The dish keeps its name, price, category and place in the order. It just
    // has no AR button — and it is NOT deleted, and the model is NOT unlinked,
    // because a human may want to retry generation against this exact product.
    expect(row!.modelStatus).toBe('FAILED');
    expect(row!.deletedAt).toBeUndefined();
    expect(String(row!.sourceModelId)).toBe(seeded.record.id);
    expect(row!.assets?.glbUrl).toBeUndefined();
  });

  it('moves a QUEUED dish to PROCESSING when generation starts', async () => {
    const seeded = await seed({ status: 'QUEUED' });
    const product = await linkDish(seeded.userId, seeded.record.id as string);
    expect(product.modelStatus).toBe('QUEUED');

    // A dish linked at QUEUED would otherwise read QUEUED for the whole
    // generation, and a client polling it has nothing to show.
    let seen: string | undefined;
    fakeClient({
      getTask: vi.fn().mockImplementation(async () => {
        seen = (await CatalogProduct.findById(product.id).exec())!.modelStatus;
        return task();
      }),
    });
    mockS3();
    await meshyModelProcessor(await generationJob(seeded));

    expect(seen).toBe('PROCESSING');
    expect((await CatalogProduct.findById(product.id).exec())!.modelStatus).toBe('READY');
  });
});
