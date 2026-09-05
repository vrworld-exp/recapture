// tests/catalog-activity-log.test.ts
//
// GET /catalog/activity — feature 55.
//
// Three properties, and the third is the one that justifies the feature's
// design:
//
//   • PAGING IS DETERMINISTIC AND INDEX-BACKED. Two runs created in the same
//     millisecond must not be skipped or repeated, which is why the cursor
//     carries `(createdAt, _id)` and not `createdAt` alone. `explain` is
//     asserted so a future change that drops the compound index shows up here
//     rather than as a slow query on a two-year-old catalog.
//
//   • RETENTION IS ENFORCED. Unbounded growth is the thing that turns a small
//     read-only feature into an operational problem.
//
//   • A DELETED PRODUCT STILL READS SENSIBLY. `targetName` is denormalised at
//     write time precisely so the log survives the row it names — a history
//     full of "(deleted)" would be worthless, and joining back to a table that
//     no longer has the row is not an option.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { Catalog } from '@/models/Catalog';
import { CatalogProduct } from '@/models/CatalogProduct';
import { CatalogPublishRun } from '@/models/CatalogPublishRun';
import { Job } from '@/models/Job';
import { User } from '@/models/User';
import { pruneRunHistory } from '@/services/catalogActivityService';

const app = createApp();
let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Catalog.syncIndexes();
  // The compound index IS the paging guarantee — without syncIndexes the
  // explain assertion below would pass for the wrong reason.
  await CatalogPublishRun.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  vi.spyOn(console, 'log').mockImplementation(() => {});
});

afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all([
    User.deleteMany({}),
    Catalog.deleteMany({}),
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

async function seedCatalog(userId: string): Promise<Types.ObjectId> {
  const catalog = await Catalog.create({
    userId: new Types.ObjectId(userId),
    name: 'Blue Cafe',
    status: 'PUBLISHED',
    draftRevision: 1,
    publishedRevision: 1,
  });
  return catalog._id as Types.ObjectId;
}

interface RunSpec {
  createdAt?: Date;
  state?: 'QUEUED' | 'RUNNING' | 'SUCCEEDED' | 'PARTIAL' | 'FAILED';
  entries?: {
    target: 'RESTAURANT' | 'CATEGORY' | 'PRODUCT';
    targetId?: string;
    targetName?: string;
    action: 'CREATE' | 'UPDATE' | 'DELETE' | 'SKIP';
    outcome: 'SUCCEEDED' | 'FAILED' | 'SKIPPED';
    code?: string;
  }[];
}

async function makeRun(
  catalogId: Types.ObjectId,
  userId: string,
  spec: RunSpec = {}
): Promise<Types.ObjectId> {
  const run = await CatalogPublishRun.create({
    catalogId,
    userId: new Types.ObjectId(userId),
    jobId: new Types.ObjectId(),
    snapshotRevision: 1,
    mode: 'FULL',
    state: spec.state ?? 'SUCCEEDED',
    counts: { total: spec.entries?.length ?? 0, synced: 0, failed: 0, skipped: 0 },
    startedAt: new Date(),
    ...(spec.state === 'RUNNING' ? {} : { finishedAt: new Date() }),
    entries: (spec.entries ?? []).map((entry) => ({ ...entry, at: new Date() })),
  });
  const id = run._id as Types.ObjectId;
  if (spec.createdAt) {
    await CatalogPublishRun.collection.updateOne(
      { _id: id },
      { $set: { createdAt: spec.createdAt } }
    );
  }
  return id;
}

// ── Paging ──────────────────────────────────────────────────────────────────

describe('GET /catalog/activity', () => {
  it('returns an empty page — not a 404 — before anything has been published', async () => {
    const { id, auth } = await makeUser();
    await seedCatalog(id);

    const res = await request(app).get('/catalog/activity').set(auth);

    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ status: 'success', runs: [] });
    expect(res.body.nextCursor).toBeUndefined();
  });

  it('pages newest-first, with every run seen exactly once', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seedCatalog(id);
    const base = Date.UTC(2026, 0, 1);
    for (let i = 0; i < 7; i++) {
      await makeRun(catalogId, id, { createdAt: new Date(base + i * 1000) });
    }

    const seen: string[] = [];
    let cursor: string | undefined;
    do {
      const res = await request(app)
        .get(`/catalog/activity?limit=3${cursor ? `&cursor=${cursor}` : ''}`)
        .set(auth);
      expect(res.status).toBe(200);
      seen.push(...res.body.runs.map((run: { id: string }) => run.id));
      cursor = res.body.nextCursor;
    } while (cursor);

    expect(seen).toHaveLength(7);
    expect(new Set(seen).size).toBe(7);
  });

  it('does not skip or repeat runs that share a createdAt millisecond', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seedCatalog(id);
    // THE CASE A `createdAt`-ONLY CURSOR GETS WRONG. Four runs, one instant.
    const same = new Date('2026-03-01T10:00:00.000Z');
    for (let i = 0; i < 4; i++) await makeRun(catalogId, id, { createdAt: same });

    const first = await request(app).get('/catalog/activity?limit=2').set(auth);
    const second = await request(app)
      .get(`/catalog/activity?limit=2&cursor=${first.body.nextCursor}`)
      .set(auth);

    const ids = [
      ...first.body.runs.map((r: { id: string }) => r.id),
      ...second.body.runs.map((r: { id: string }) => r.id),
    ];
    expect(ids).toHaveLength(4);
    expect(new Set(ids).size).toBe(4);
  });

  it('is index-backed — no collection scan', async () => {
    const { id } = await makeUser();
    const catalogId = await seedCatalog(id);
    await makeRun(catalogId, id);

    const explained = await CatalogPublishRun.find({ catalogId })
      .sort({ createdAt: -1, _id: -1 })
      .limit(21)
      .explain('queryPlanner');

    const plan = JSON.stringify(
      (explained as { queryPlanner?: { winningPlan?: unknown } }).queryPlanner?.winningPlan ?? {}
    );
    expect(plan).toContain('IXSCAN');
    expect(plan).not.toContain('COLLSCAN');
  });

  it('rejects a tampered cursor with 400, never a 500', async () => {
    const { id, auth } = await makeUser();
    await seedCatalog(id);

    const res = await request(app).get('/catalog/activity?cursor=not-a-cursor').set(auth);

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_CURSOR');
  });

  it('caps the page size', async () => {
    const { id, auth } = await makeUser();
    await seedCatalog(id);

    const res = await request(app).get('/catalog/activity?limit=500').set(auth);

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
  });
});

// ── Content ─────────────────────────────────────────────────────────────────

describe('what a run row carries', () => {
  it('projects entries field by field, resolving the message from the code', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seedCatalog(id);
    await makeRun(catalogId, id, {
      state: 'PARTIAL',
      entries: [
        { target: 'CATEGORY', targetId: 'c1', targetName: 'Chairs', action: 'CREATE', outcome: 'SUCCEEDED' },
        {
          target: 'PRODUCT',
          targetId: 'p1',
          targetName: 'Garden Chair',
          action: 'CREATE',
          outcome: 'FAILED',
          code: 'PUBLISH_DUPLICATE_NAME',
        },
      ],
    });

    const res = await request(app).get('/catalog/activity').set(auth);

    const [run] = res.body.runs;
    expect(run.state).toBe('PARTIAL');
    expect(run.mode).toBe('FULL');
    expect(run.entries).toHaveLength(2);
    expect(Object.keys(run.entries[0]).sort()).toEqual([
      'action',
      'at',
      'outcome',
      'target',
      'targetId',
      'targetName',
    ]);
    // Stored as a code; the sentence is resolved on read, so improving the
    // wording improves history too.
    expect(run.entries[1].code).toBe('PUBLISH_DUPLICATE_NAME');
    expect(run.entries[1].message).toMatch(/already uses this name/i);
  });

  it('degrades an unrecognised code to a sentence, never the raw code', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seedCatalog(id);
    await makeRun(catalogId, id, {
      entries: [
        { target: 'PRODUCT', targetName: 'Chair', action: 'CREATE', outcome: 'FAILED', code: 'PUBLISH_FROM_AN_OLDER_BUILD' },
      ],
    });

    const res = await request(app).get('/catalog/activity').set(auth);

    const entry = res.body.runs[0].entries[0];
    expect(entry.message).toBeTruthy();
    expect(entry.message).not.toContain('PUBLISH_FROM_AN_OLDER_BUILD');
  });

  it('never carries Mirage prose', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seedCatalog(id);
    await makeRun(catalogId, id, {
      entries: [
        { target: 'PRODUCT', targetName: 'Chair', action: 'CREATE', outcome: 'FAILED', code: 'PUBLISH_DUPLICATE_NAME' },
      ],
    });

    const res = await request(app).get('/catalog/activity').set(auth);

    expect(JSON.stringify(res.body)).not.toMatch(/already exist|Only chef|Path not found/i);
  });

  it('includes a RUNNING run, with no finish time', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seedCatalog(id);
    await makeRun(catalogId, id, { state: 'RUNNING' });

    const res = await request(app).get('/catalog/activity').set(auth);

    expect(res.body.runs[0]).toMatchObject({ state: 'RUNNING', finishedAt: null });
  });

  it('still names a product that has since been deleted', async () => {
    const { id, auth } = await makeUser();
    const catalogId = await seedCatalog(id);
    const product = await CatalogProduct.create({
      catalogId,
      userId: new Types.ObjectId(id),
      type: 'IMAGE_ONLY',
      name: 'Garden Chair',
      position: 0,
      assets: { imageKey: 'dev/x.jpg' },
    });
    await makeRun(catalogId, id, {
      entries: [
        {
          target: 'PRODUCT',
          targetId: String(product._id),
          targetName: 'Garden Chair',
          action: 'CREATE',
          outcome: 'SUCCEEDED',
        },
      ],
    });
    await CatalogProduct.deleteOne({ _id: product._id }).exec();

    const res = await request(app).get('/catalog/activity').set(auth);

    // Denormalised at write time — a join would have nothing left to join to.
    expect(res.body.runs[0].entries[0].targetName).toBe('Garden Chair');
  });
});

// ── Retention ───────────────────────────────────────────────────────────────

describe('retention', () => {
  it('keeps the newest N runs and deletes the rest', async () => {
    const { id } = await makeUser();
    const catalogId = await seedCatalog(id);
    const keep = env.CATALOG_ACTIVITY_RETAINED_RUNS;
    const base = Date.UTC(2026, 0, 1);
    const ids: string[] = [];
    for (let i = 0; i < keep + 5; i++) {
      ids.push(String(await makeRun(catalogId, id, { createdAt: new Date(base + i * 1000) })));
    }

    const deleted = await pruneRunHistory(catalogId);

    expect(deleted).toBe(5);
    expect(await CatalogPublishRun.countDocuments({ catalogId })).toBe(keep);
    // The five OLDEST went; the newest survived.
    const survivors = await CatalogPublishRun.find({ catalogId }).select({ _id: 1 }).lean().exec();
    const surviving = new Set(survivors.map((run) => String(run._id)));
    expect(ids.slice(0, 5).every((old) => !surviving.has(old))).toBe(true);
    expect(surviving.has(ids[ids.length - 1])).toBe(true);
  });

  it('does nothing when the history is under the bound', async () => {
    const { id } = await makeUser();
    const catalogId = await seedCatalog(id);
    await makeRun(catalogId, id);
    await makeRun(catalogId, id);

    expect(await pruneRunHistory(catalogId)).toBe(0);
    expect(await CatalogPublishRun.countDocuments({ catalogId })).toBe(2);
  });

  it('never touches another catalog’s history', async () => {
    const { id } = await makeUser();
    const mine = await seedCatalog(id);
    const stranger = await makeUser();
    const theirs = await seedCatalog(stranger.id);
    for (let i = 0; i < env.CATALOG_ACTIVITY_RETAINED_RUNS + 3; i++) {
      await makeRun(mine, id, { createdAt: new Date(Date.UTC(2026, 0, 1) + i * 1000) });
    }
    await makeRun(theirs, stranger.id);

    await pruneRunHistory(mine);

    expect(await CatalogPublishRun.countDocuments({ catalogId: theirs })).toBe(1);
  });
});

// ── Ownership ───────────────────────────────────────────────────────────────

describe('ownership', () => {
  it('never shows another user’s runs, and 404s identically', async () => {
    const { auth } = await makeUser();
    const stranger = await makeUser();
    const theirs = await seedCatalog(stranger.id);
    await makeRun(theirs, stranger.id);

    const res = await request(app).get('/catalog/activity').set(auth);

    expect(res.status).toBe(404);
    expect(res.body.code).toBe('CATALOG_NOT_FOUND');
  });

  it('rejects an unauthenticated call', async () => {
    const res = await request(app).get('/catalog/activity');
    expect(res.status).toBe(401);
  });
});
