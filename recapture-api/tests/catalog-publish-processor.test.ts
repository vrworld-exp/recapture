// tests/catalog-publish-processor.test.ts
//
// The MIRAGE_CATALOG_PUBLISH processor's skeleton: the run state machine, the
// sequential walk, per-row isolation, and the §7.8 finalize rule.
//
// Hermetic: in-memory MongoDB, and the Mirage calls replaced wholesale through
// `setPublishExecutors`. That substitution is not a convenience — it is the
// seam B2/B3 land behind, so a test that reached for a live Mirage would be
// testing the wrong layer AND breaking the CI rule that nothing calls a real
// external API.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { Catalog } from '@/models/Catalog';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogProduct } from '@/models/CatalogProduct';
import { CatalogPublishRun } from '@/models/CatalogPublishRun';
import type { PublishMode } from '@/models/types/catalog.types';
import {
  resetPublishExecutors,
  setPublishExecutors,
  type PublishStepExecutor,
} from '@/services/catalog/publishExecutors';
import { hasActiveRun, markCategorySynced, markProductSynced } from '@/services/catalog/publishRunState';
import { MirageError } from '@/services/mirage';
import {
  mirageCatalogPublishProcessor,
  PublishErrorCode,
} from '@/worker/processors/mirageCatalogPublishProcessor';
import { NonRetryableJobError, type WorkerJob } from '@/worker/workerTypes';

let mongod: MongoMemoryServer;

const USER_ID = new Types.ObjectId();

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  // The analytics sink echoes to console outside prod; the worker log writes
  // one JSON line per step. Neither is under test here.
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
});

afterEach(async () => {
  await Promise.all([
    Catalog.deleteMany({}),
    CatalogCategory.deleteMany({}),
    CatalogProduct.deleteMany({}),
    CatalogPublishRun.deleteMany({}),
  ]);
  resetPublishExecutors();
  vi.restoreAllMocks();
});

// ── Fixture ─────────────────────────────────────────────────────────────────

interface Fixture {
  catalogId: Types.ObjectId;
  categoryId: Types.ObjectId;
  productIds: Types.ObjectId[];
  runId: Types.ObjectId;
}

/**
 * One catalog, one un-created category and two un-published products — the
 * shape whose plan is RESTAURANT UPDATE → CATEGORY CREATE → 2 × PRODUCT CREATE.
 */
async function seed(
  overrides: {
    catalog?: Record<string, unknown>;
    runState?: 'QUEUED' | 'RUNNING' | 'SUCCEEDED';
    runEntries?: Record<string, unknown>[];
  } = {}
): Promise<Fixture> {
  const catalog = await Catalog.create({
    userId: USER_ID,
    name: 'Blue Cafe',
    status: 'DRAFT',
    mirageRestaurantId: 'mr-1',
    draftRevision: 3,
    publishedRevision: -1,
    ...overrides.catalog,
  });
  const catalogId = catalog._id as Types.ObjectId;

  const category = await CatalogCategory.create({
    catalogId,
    userId: USER_ID,
    name: 'Chairs',
    position: 0,
  });

  const products = await CatalogProduct.create([
    {
      catalogId,
      userId: USER_ID,
      type: 'IMAGE_ONLY',
      name: 'Chair A',
      position: 0,
      categoryId: category._id,
      assets: { imageKey: 'prod/a.jpg' },
    },
    {
      catalogId,
      userId: USER_ID,
      type: 'IMAGE_ONLY',
      name: 'Chair B',
      position: 1,
      categoryId: category._id,
      assets: { imageKey: 'prod/b.jpg' },
    },
  ]);

  const run = await CatalogPublishRun.create({
    catalogId,
    userId: USER_ID,
    jobId: new Types.ObjectId(),
    snapshotRevision: catalog.draftRevision,
    state: overrides.runState ?? 'QUEUED',
    ...(overrides.runEntries ? { entries: overrides.runEntries } : {}),
  });
  const runId = run._id as Types.ObjectId;

  await Catalog.updateOne({ _id: catalogId }, { $set: { activePublishRunId: runId } }).exec();

  return {
    catalogId,
    categoryId: category._id as Types.ObjectId,
    productIds: products.map((p) => p._id as Types.ObjectId),
    runId,
  };
}

function job(fixture: Fixture, mode: PublishMode = 'FULL', maxAttempts = 3): WorkerJob {
  return {
    _id: new Types.ObjectId(),
    state: 'PROCESSING',
    jobType: 'MIRAGE_CATALOG_PUBLISH',
    payload: {
      catalogId: fixture.catalogId.toHexString(),
      publishRunId: fixture.runId.toHexString(),
      mode,
    },
    attempts: 0,
    maxAttempts,
    claimedBy: 'worker-test-1',
    createdAt: new Date(),
    updatedAt: new Date(),
  };
}

/** Executors that succeed and write the row state a real one would. */
function successfulExecutors(failProductIds: string[] = []): void {
  const restaurant: PublishStepExecutor = async (_step, context) => {
    context.mirageRestaurantId = context.snapshot.catalog.mirageRestaurantId ?? 'mr-created';
    return { outcome: 'SUCCEEDED' };
  };

  const category: PublishStepExecutor = async (step, context) => {
    const mirageId = `m-${step.targetId}`;
    context.mirageCategoryIds.set(step.targetId as string, mirageId);
    await markCategorySynced(step.targetId as string, mirageId);
    return { outcome: 'SUCCEEDED' };
  };

  const product: PublishStepExecutor = async (step) => {
    if (failProductIds.includes(step.targetId as string)) {
      return {
        outcome: 'FAILED',
        code: 'PUBLISH_PRODUCT_REJECTED',
        message: 'Mirage would not accept this product.',
      };
    }
    await CatalogProduct.updateOne(
      { _id: step.targetId },
      { $set: { mirageItemId: `mi-${step.targetId}` } }
    ).exec();
    const row = await CatalogProduct.findById(step.targetId).lean().exec();
    // Mirrors productSync's snapshotOf: EVERY field the planner diffs. A stub
    // that writes a partial snapshot makes the next run re-plan an UPDATE for
    // the missing field, which is the diff doing its job and would make the
    // "republish writes nothing" assertion below fail for the wrong reason.
    await markProductSynced(step.targetId as string, {
      name: row?.name,
      type: row?.type,
      categoryId: row?.categoryId ? row.categoryId.toHexString() : null,
      position: row?.position,
      imageKey: row?.assets?.imageKey,
    });
    return { outcome: 'SUCCEEDED' };
  };

  setPublishExecutors({ RESTAURANT: restaurant, CATEGORY: category, PRODUCT: product });
}

// ── Happy path ──────────────────────────────────────────────────────────────

describe('mirageCatalogPublishProcessor — success', () => {
  it('walks the plan, records an entry per step and advances publishedRevision', async () => {
    const fixture = await seed();
    successfulExecutors();

    const result = await mirageCatalogPublishProcessor(job(fixture));

    expect(result).toMatchObject({ state: 'SUCCEEDED' });

    const run = await CatalogPublishRun.findById(fixture.runId).lean().exec();
    expect(run?.state).toBe('SUCCEEDED');
    expect(run?.startedAt).toBeInstanceOf(Date);
    expect(run?.finishedAt).toBeInstanceOf(Date);
    expect(run?.counts).toMatchObject({ total: 4, synced: 4, failed: 0, skipped: 0 });
    expect(run?.entries.map((e) => e.target)).toEqual([
      'RESTAURANT',
      'CATEGORY',
      'PRODUCT',
      'PRODUCT',
    ]);
    // Denormalised so the activity log survives the row being deleted.
    expect(run?.entries[2]?.targetName).toBe('Chair A');

    const catalog = await Catalog.findById(fixture.catalogId).lean().exec();
    expect(catalog?.publishedRevision).toBe(3);
    expect(catalog?.status).toBe('PUBLISHED');
    expect(catalog?.lastPublishedAt).toBeInstanceOf(Date);
    expect(catalog?.activePublishRunId).toBeNull();
  });

  it('reports SUCCEEDED for a republish where every step is a SKIP', async () => {
    const fixture = await seed();
    successfulExecutors();
    await mirageCatalogPublishProcessor(job(fixture));

    // A second run over an unchanged catalog: the restaurant is up to date
    // (draftRevision === publishedRevision now) and every row matches its
    // published snapshot.
    const second = await CatalogPublishRun.create({
      catalogId: fixture.catalogId,
      userId: USER_ID,
      jobId: new Types.ObjectId(),
      snapshotRevision: 3,
      state: 'QUEUED',
    });
    const secondId = second._id as Types.ObjectId;
    await Catalog.updateOne(
      { _id: fixture.catalogId },
      { $set: { activePublishRunId: secondId } }
    ).exec();

    await mirageCatalogPublishProcessor(job({ ...fixture, runId: secondId }));

    const run = await CatalogPublishRun.findById(secondId).lean().exec();
    expect(run?.state).toBe('SUCCEEDED');
    expect(run?.counts).toMatchObject({ synced: 0, failed: 0, skipped: 4 });
    expect(run?.entries.every((e) => e.action === 'SKIP')).toBe(true);
  });
});

// ── Per-row isolation and the finalize rule ─────────────────────────────────

describe('mirageCatalogPublishProcessor — failures are isolated', () => {
  it('finishes PARTIAL when one row fails, and keeps going past it', async () => {
    const fixture = await seed();
    const failing = fixture.productIds[0].toHexString();
    successfulExecutors([failing]);

    await mirageCatalogPublishProcessor(job(fixture));

    const run = await CatalogPublishRun.findById(fixture.runId).lean().exec();
    expect(run?.state).toBe('PARTIAL');
    expect(run?.counts).toMatchObject({ total: 4, synced: 3, failed: 1 });
    // The row AFTER the failure still ran — that is the isolation guarantee.
    expect(run?.entries).toHaveLength(4);
    expect(run?.entries[3]).toMatchObject({ target: 'PRODUCT', outcome: 'SUCCEEDED' });

    const failed = await CatalogProduct.findById(fixture.productIds[0]).lean().exec();
    expect(failed?.syncStatus).toBe('FAILED');
    expect(failed?.syncError?.code).toBe('PUBLISH_PRODUCT_REJECTED');

    const succeeded = await CatalogProduct.findById(fixture.productIds[1]).lean().exec();
    expect(succeeded?.syncStatus).toBe('SYNCED');

    // PARTIAL does NOT advance the revision: "draft changes not yet live" is
    // literally true while one product is still missing from the page.
    const catalog = await Catalog.findById(fixture.catalogId).lean().exec();
    expect(catalog?.publishedRevision).toBe(-1);
    expect(catalog?.activePublishRunId).toBeNull();
  });

  it('finishes FAILED when nothing succeeded, and still releases the catalog', async () => {
    const fixture = await seed();
    setPublishExecutors({
      RESTAURANT: async () => ({ outcome: 'FAILED', code: 'PUBLISH_RESTAURANT_REJECTED' }),
    });

    await mirageCatalogPublishProcessor(job(fixture));

    const run = await CatalogPublishRun.findById(fixture.runId).lean().exec();
    expect(run?.state).toBe('FAILED');
    // A restaurant failure aborts: nothing under it could have been created.
    expect(run?.entries).toHaveLength(1);

    const catalog = await Catalog.findById(fixture.catalogId).lean().exec();
    expect(catalog?.publishedRevision).toBe(-1);
    expect(catalog?.status).toBe('DRAFT');
    expect(catalog?.activePublishRunId).toBeNull();
  });

  it('treats an unclassified executor throw as a ROW failure, not a run failure', async () => {
    const fixture = await seed();
    successfulExecutors();
    setPublishExecutors({
      PRODUCT: async (step) => {
        if (step.targetId === fixture.productIds[0].toHexString()) {
          throw new Error('boom');
        }
        return { outcome: 'SUCCEEDED' };
      },
    });

    await mirageCatalogPublishProcessor(job(fixture));

    const run = await CatalogPublishRun.findById(fixture.runId).lean().exec();
    expect(run?.state).toBe('PARTIAL');
    expect(run?.entries[2]?.code).toBe(PublishErrorCode.STEP_FAILED);
    expect(run?.entries).toHaveLength(4);
  });
});

// ── Retry vs terminal ───────────────────────────────────────────────────────

describe('mirageCatalogPublishProcessor — run-level failures', () => {
  it('rethrows a retryable Mirage failure and leaves the catalog locked', async () => {
    const fixture = await seed();
    setPublishExecutors({
      RESTAURANT: async () => {
        throw new MirageError(
          'MIRAGE_UNREACHABLE',
          'retryable',
          'Mirage is unreachable.',
          'restaurant'
        );
      },
    });

    await expect(mirageCatalogPublishProcessor(job(fixture))).rejects.toBeInstanceOf(MirageError);

    // The worker will back off and re-claim; the run must still be its owner.
    const run = await CatalogPublishRun.findById(fixture.runId).lean().exec();
    expect(run?.state).toBe('RUNNING');
    expect((await hasActiveRun(fixture.catalogId)).active).toBe(true);
  });

  it('turns a rejected credential into a terminal failure and releases the catalog', async () => {
    const fixture = await seed();
    setPublishExecutors({
      RESTAURANT: async () => {
        throw new MirageError(
          'MIRAGE_AUTH_REJECTED',
          'auth',
          'Mirage rejected the admin credential.',
          'restaurant'
        );
      },
    });

    await expect(mirageCatalogPublishProcessor(job(fixture))).rejects.toBeInstanceOf(
      NonRetryableJobError
    );

    const run = await CatalogPublishRun.findById(fixture.runId).lean().exec();
    expect(run?.state).toBe('FAILED');
    expect(run?.error?.code).toBe(PublishErrorCode.AUTH_REJECTED);
    expect((await hasActiveRun(fixture.catalogId)).active).toBe(false);
  });

  it('fails terminally when the catalog is gone, and releases it anyway', async () => {
    const fixture = await seed();
    await Catalog.updateOne(
      { _id: fixture.catalogId },
      { $set: { deletedAt: new Date() } }
    ).exec();

    await expect(mirageCatalogPublishProcessor(job(fixture))).rejects.toMatchObject({
      code: PublishErrorCode.CATALOG_MISSING,
    });

    const run = await CatalogPublishRun.findById(fixture.runId).lean().exec();
    expect(run?.state).toBe('FAILED');
    const catalog = await Catalog.findById(fixture.catalogId).lean().exec();
    expect(catalog?.activePublishRunId).toBeNull();
  });

  it('rejects a malformed payload without touching anything', async () => {
    const fixture = await seed();
    const malformed = { ...job(fixture), payload: { mode: 'FULL' } };

    await expect(mirageCatalogPublishProcessor(malformed)).rejects.toMatchObject({
      code: PublishErrorCode.JOB_MALFORMED,
    });

    const run = await CatalogPublishRun.findById(fixture.runId).lean().exec();
    expect(run?.state).toBe('QUEUED');
  });
});

// ── Crash replay ────────────────────────────────────────────────────────────

describe('mirageCatalogPublishProcessor — crash replay', () => {
  it('resumes a RUNNING run, keeps its entries and re-plans finished rows as SKIP', async () => {
    const fixture = await seed({
      runState: 'RUNNING',
      runEntries: [
        {
          target: 'RESTAURANT',
          targetName: 'Blue Cafe',
          action: 'UPDATE',
          outcome: 'SUCCEEDED',
          at: new Date(),
        },
      ],
    });

    // The state a worker that died mid-run leaves behind: one product already
    // pushed and recorded, the rest untouched.
    await CatalogProduct.updateOne(
      { _id: fixture.productIds[0] },
      { $set: { mirageItemId: 'mi-already-there' } }
    ).exec();
    await markProductSynced(fixture.productIds[0].toHexString(), {
      name: 'Chair A',
      type: 'IMAGE_ONLY',
      categoryId: fixture.categoryId.toHexString(),
      // EVERY diffed field, exactly as productSync's snapshotOf writes them. A
      // snapshot missing one reads as "that field changed" and re-plans an
      // UPDATE — which is the diff working, not a bug, but it makes this test
      // about the wrong thing.
      position: 0,
      imageKey: 'prod/a.jpg',
    });

    successfulExecutors();
    await mirageCatalogPublishProcessor(job(fixture));

    const run = await CatalogPublishRun.findById(fixture.runId).lean().exec();
    expect(run?.state).toBe('SUCCEEDED');

    // The dead attempt's entry is still the first one on the document.
    expect(run?.entries[0]).toMatchObject({ target: 'RESTAURANT', outcome: 'SUCCEEDED' });
    expect(run?.entries).toHaveLength(5);

    // The already-published product re-planned as SKIP — exactly one Mirage
    // item exists for it, which is the whole crash-safety claim.
    const replayed = run?.entries.filter(
      (e) => e.targetId === fixture.productIds[0].toHexString()
    );
    expect(replayed).toHaveLength(1);
    expect(replayed?.[0]).toMatchObject({ action: 'SKIP' });

    const product = await CatalogProduct.findById(fixture.productIds[0]).lean().exec();
    expect(product?.mirageItemId).toBe('mi-already-there');
  });

  it('does nothing at all when the run already finished', async () => {
    const fixture = await seed({ runState: 'SUCCEEDED' });
    const executor = vi.fn<PublishStepExecutor>(async () => ({ outcome: 'SUCCEEDED' }));
    setPublishExecutors({ RESTAURANT: executor, CATEGORY: executor, PRODUCT: executor });

    const result = await mirageCatalogPublishProcessor(job(fixture));

    expect(result).toMatchObject({ state: 'SUCCEEDED', replayed: true });
    expect(executor).not.toHaveBeenCalled();
  });
});

// ── Modes ───────────────────────────────────────────────────────────────────

describe('mirageCatalogPublishProcessor — unpublish', () => {
  it('deletes published items without advancing publishedRevision', async () => {
    const fixture = await seed();
    successfulExecutors();
    await mirageCatalogPublishProcessor(job(fixture));

    const unpublishRun = await CatalogPublishRun.create({
      catalogId: fixture.catalogId,
      userId: USER_ID,
      jobId: new Types.ObjectId(),
      snapshotRevision: 3,
      state: 'QUEUED',
    });
    const unpublishId = unpublishRun._id as Types.ObjectId;
    await Catalog.updateOne(
      { _id: fixture.catalogId },
      { $set: { activePublishRunId: unpublishId, publishedRevision: -1 } }
    ).exec();

    const deleted: string[] = [];
    setPublishExecutors({
      PRODUCT: async (step) => {
        deleted.push(step.action);
        return { outcome: 'SUCCEEDED' };
      },
    });

    await mirageCatalogPublishProcessor(
      job({ ...fixture, runId: unpublishId }, 'UNPUBLISH')
    );

    expect(deleted).toEqual(['DELETE', 'DELETE']);
    const catalog = await Catalog.findById(fixture.catalogId).lean().exec();
    expect(catalog?.publishedRevision).toBe(-1);
    expect(catalog?.activePublishRunId).toBeNull();
  });
});
