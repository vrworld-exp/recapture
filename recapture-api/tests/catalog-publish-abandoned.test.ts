// tests/catalog-publish-abandoned.test.ts
//
// A publish lock whose run can never finish must not wedge the catalog forever.
//
// THE FAILURE THIS PINS DOWN. `activePublishRunId` is cleared on the happy path
// in exactly one place — finalizeCatalogAfterRun, at the END of the processor.
// A job that dies BEFORE reaching that processor strands the catalog: the run
// stays QUEUED, the lock stays taken, the client polls a run that will never
// move, and every later publish is refused with 409. In production the way in
// was a stale deployment on the shared queue claiming a MIRAGE_CATALOG_PUBLISH
// job, finding no processor, and failing it terminally (UNSUPPORTED_JOB_TYPE).
//
// WHY THIS IS TESTED AT THE ENDPOINT AND NOT ONLY AS A UNIT. The repair is
// worth nothing unless it runs on the paths a stuck user actually touches —
// polling status, and pressing Publish again. Both are asserted below.
//
// THE OTHER HALF OF THE PROPERTY IS RESTRAINT. Releasing a lock under live work
// would let two runs race Mirage's non-idempotent writes, which is the exact
// thing the lock exists to prevent. The "leaves it alone" cases matter as much
// as the "clears it" ones, and a RUNNING run whose worker died mid-walk stays
// locked on purpose — its rows may be half-pushed, so a human looks first.
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
import {
  judgeAbandonedRun,
  releaseAbandonedRun,
  PUBLISH_ABANDONED_CODE,
} from '@/services/catalog/publishRunState';
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

async function seed(userId: string): Promise<Types.ObjectId> {
  const catalog = await Catalog.create({
    userId: new Types.ObjectId(userId),
    name: 'Blue Cafe',
    status: 'DRAFT',
    draftRevision: 1,
    publishedRevision: -1,
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

/**
 * Puts a catalog in the exact shape a died-before-processing publish leaves
 * behind: a run holding the lock, and a job in whatever state killed it.
 */
async function lockWith(
  userId: string,
  catalogId: Types.ObjectId,
  runState: 'QUEUED' | 'RUNNING',
  jobState: string,
  jobErrorCode?: string
): Promise<Types.ObjectId> {
  const job = await Job.create({
    userId: new Types.ObjectId(userId),
    jobType: 'MIRAGE_CATALOG_PUBLISH',
    state: jobState,
    ...(jobErrorCode
      ? { error: { code: jobErrorCode, message: 'No processor for jobType' } }
      : {}),
  });
  const run = await CatalogPublishRun.create({
    catalogId,
    userId: new Types.ObjectId(userId),
    jobId: job._id,
    snapshotRevision: 1,
    mode: 'FULL',
    state: runState,
  });
  const runId = run._id as Types.ObjectId;
  await Catalog.updateOne({ _id: catalogId }, { $set: { activePublishRunId: runId } }).exec();
  return runId;
}

describe('judgeAbandonedRun', () => {
  it('releases a QUEUED run whose job died terminally', () => {
    expect(judgeAbandonedRun('QUEUED', 'FAILED').release).toBe(true);
    expect(judgeAbandonedRun('QUEUED', 'CANCELED').release).toBe(true);
  });

  it('releases when the run or job document is gone entirely', () => {
    expect(judgeAbandonedRun(null, 'FAILED').release).toBe(true);
    expect(judgeAbandonedRun('QUEUED', null).release).toBe(true);
  });

  it('releases a terminal run that never got its lock cleared', () => {
    // finalizeRun landed, the catalog write after it did not.
    expect(judgeAbandonedRun('SUCCEEDED', 'COMPLETED').release).toBe(true);
    expect(judgeAbandonedRun('PARTIAL', 'COMPLETED').release).toBe(true);
  });

  it('LEAVES ALONE any job a worker can still claim', () => {
    for (const live of ['QUEUED', 'CLAIMED', 'PROCESSING', 'TEXTURING', 'OPTIMIZING']) {
      expect(judgeAbandonedRun('QUEUED', live).release).toBe(false);
      expect(judgeAbandonedRun('RUNNING', live).release).toBe(false);
    }
  });

  it('will not automatically release a RUNNING run — its rows may be half-pushed', () => {
    // The whole point: a worker that died mid-walk may already have written to
    // Mirage, so this one waits for a human who has read the run's entries[].
    expect(judgeAbandonedRun('RUNNING', 'FAILED').release).toBe(false);
    expect(judgeAbandonedRun('RUNNING', 'FAILED', true).release).toBe(true);
  });

  it('will not automatically release a RUNNING run whose job document is GONE', () => {
    // A missing job is the ABSENCE of evidence, not evidence that nothing
    // reached Mirage — the run got past beginRun, so a worker was walking the
    // plan. Testing null before the RUNNING guard auto-released a run that a
    // backing-off worker still owned, which catalog-publish-processor.test.ts
    // (retryable Mirage failure) catches from the other side.
    expect(judgeAbandonedRun('RUNNING', null).release).toBe(false);
    expect(judgeAbandonedRun('RUNNING', null, true).release).toBe(true);
  });
});

describe('abandoned publish locks self-heal', () => {
  it('GET /publish/status clears a lock whose job died, and says why', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id);
    const runId = await lockWith(id, catalogId, 'QUEUED', 'FAILED', 'UNSUPPORTED_JOB_TYPE');

    const res = await request(app).get('/catalog/publish/status').set(auth);

    expect(res.status).toBe(200);
    // The lock is gone, and the response does not pair a cleared lock with a
    // run still reported as QUEUED — the client would spin forever on that.
    expect(res.body.publish.activeRunId).toBeNull();
    expect(res.body.publish.run).toMatchObject({
      id: runId.toHexString(),
      state: 'FAILED',
      error: { code: PUBLISH_ABANDONED_CODE },
    });
    expect(res.body.publish.run.error.message).toMatch(/Press Publish again/);

    const catalog = await Catalog.findById(catalogId).lean().exec();
    expect(catalog?.activePublishRunId ?? null).toBeNull();
  });

  it('POST /publish stops answering 409 once the lock is abandoned', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id);
    await lockWith(id, catalogId, 'QUEUED', 'FAILED', 'UNSUPPORTED_JOB_TYPE');

    const res = await request(app).post('/catalog/publish').set(auth);

    // What it goes on to do (queue, block on a gate) is another test's business.
    // The property here is that the dead lock no longer refuses the user.
    expect(res.status).not.toBe(409);
    expect(res.body.code).not.toBe('PUBLISH_IN_PROGRESS');
  });

  it('KEEPS the lock while the job is still claimable', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id);
    const runId = await lockWith(id, catalogId, 'QUEUED', 'QUEUED');

    const status = await request(app).get('/catalog/publish/status').set(auth);
    expect(status.body.publish.activeRunId).toBe(runId.toHexString());
    expect(status.body.publish.run.state).toBe('QUEUED');

    const publish = await request(app).post('/catalog/publish').set(auth);
    expect(publish.status).toBe(409);
    expect(publish.body.code).toBe('PUBLISH_IN_PROGRESS');
  });

  it('KEEPS the lock on a RUNNING run whose worker died mid-walk', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seed(id);
    const runId = await lockWith(id, catalogId, 'RUNNING', 'FAILED', 'PROCESSING_FAILED');

    const res = await request(app).get('/catalog/publish/status').set(auth);

    // Rows may be half-pushed to Mirage. Automatic repair must not guess here —
    // scripts/release-stuck-publish.ts --force is the human-in-the-loop path.
    expect(res.body.publish.activeRunId).toBe(runId.toHexString());
    expect(res.body.publish.run.state).toBe('RUNNING');

    // …and that path does release it.
    expect(await releaseAbandonedRun(catalogId, runId, { force: true })).toBe(true);
    const catalog = await Catalog.findById(catalogId).lean().exec();
    expect(catalog?.activePublishRunId ?? null).toBeNull();
  });

  it('does not clear a lock that has already changed hands', async () => {
    const { id } = await makeUser();
    const catalogId = await seed(id);
    const deadRunId = await lockWith(id, catalogId, 'QUEUED', 'FAILED', 'UNSUPPORTED_JOB_TYPE');

    // A fresh publish took the lock between the read and the write.
    const liveRunId = new Types.ObjectId();
    await Catalog.updateOne(
      { _id: catalogId },
      { $set: { activePublishRunId: liveRunId } }
    ).exec();

    expect(await releaseAbandonedRun(catalogId, deadRunId)).toBe(false);
    const catalog = await Catalog.findById(catalogId).lean().exec();
    expect(catalog?.activePublishRunId?.toHexString()).toBe(liveRunId.toHexString());
  });
});
