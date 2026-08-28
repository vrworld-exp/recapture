// tests/catalog-category-sync.test.ts
//
// The CATEGORY executor against a Mirage that behaves like the real one.
//
// The assertions worth reading twice are the ones about NAMES. Mirage lowercases
// and underscores what it stores, and checks uniqueness against the RAW request
// name before doing so — two facts that between them can create a second
// category that collides with the first. Sending the normalised form is the fix,
// and never writing the echo back is what keeps "Garden Chairs" on the user's
// screen.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { Catalog } from '@/models/Catalog';
import { CatalogCategory } from '@/models/CatalogCategory';
import {
  categoryExecutor,
  ensureUncategorizedCategory,
  mirageCategoryName,
  repairCascadedCategory,
} from '@/services/catalog/categorySync';
import type { PublishStep } from '@/services/catalog/publishPlanner';
import { resetMirageClient, setMirageClient } from '@/services/mirage';
import { FakeMirage } from './fixtures/mirageFake';
import {
  clearCatalogCollections,
  contextFor,
  seedCatalog,
  type PublishFixture,
} from './fixtures/publishHarness';

let mongod: MongoMemoryServer;
const mirage = new FakeMirage();
let restaurantId: string;

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
  vi.spyOn(console, 'warn').mockImplementation(() => {});
  vi.spyOn(console, 'info').mockImplementation(() => {});
});

afterEach(async () => {
  await clearCatalogCollections();
  resetMirageClient();
  vi.restoreAllMocks();
});

const step = (fixture: PublishFixture, action: 'CREATE' | 'UPDATE'): PublishStep => ({
  target: 'CATEGORY',
  targetId: fixture.categoryId.toHexString(),
  targetName: 'Garden Chairs',
  action,
  reason: action === 'CREATE' ? 'NO_MIRAGE_ID' : 'EDITED_SINCE_SYNC',
});

describe('mirageCategoryName', () => {
  it('produces exactly what Mirage would store', () => {
    // adminController.js:738-739 — trim, lowercase, spaces to underscores.
    expect(mirageCategoryName('  Garden Chairs ')).toBe('garden_chairs');
  });
});

describe('categoryExecutor — CREATE', () => {
  it('creates the category and persists its Mirage id immediately', async () => {
    const fixture = await seedCatalog();
    const context = await contextFor(fixture, restaurantId);

    const result = await categoryExecutor(step(fixture, 'CREATE'), context);

    expect(result.outcome).toBe('SUCCEEDED');
    const stored = await CatalogCategory.findById(fixture.categoryId).lean().exec();
    expect(stored?.mirageCategoryId).toBeDefined();
    expect(stored?.syncStatus).toBe('SYNCED');
    // The run's own view is updated too, so a product created later this run
    // files itself under the id that was actually minted.
    expect(context.mirageCategoryIds.get(fixture.categoryId.toHexString())).toBe(
      stored?.mirageCategoryId
    );
  });

  it('sends the NORMALISED name, so Mirage’s own uniqueness check can fire', async () => {
    const fixture = await seedCatalog();
    const context = await contextFor(fixture, restaurantId);
    await categoryExecutor(step(fixture, 'CREATE'), context);

    const created = [...mirage.categories.values()][0];
    expect(created.name).toBe('garden_chairs');

    // A second create of the same display name is refused by Mirage rather than
    // silently making a twin — which is only true because we pre-normalised.
    const second = await seedCatalog({ catalog: { userId: new Types.ObjectId() } });
    const secondContext = await contextFor(second, restaurantId);
    const result = await categoryExecutor(step(second, 'CREATE'), secondContext);

    // ...and the duplicate is RECONCILED, not failed: the existing id is adopted.
    expect(result.outcome).toBe('SUCCEEDED');
    const stored = await CatalogCategory.findById(second.categoryId).lean().exec();
    expect(stored?.mirageCategoryId).toBe(created.id);
    expect(mirage.categories.size).toBe(1);
  });

  it('never writes Mirage’s mangled echo back over the display name', async () => {
    const fixture = await seedCatalog();
    const context = await contextFor(fixture, restaurantId);
    await categoryExecutor(step(fixture, 'CREATE'), context);

    const stored = await CatalogCategory.findById(fixture.categoryId).lean().exec();
    expect(stored?.name).toBe('Garden Chairs');
  });

  it('fails the row when a duplicate cannot be found to adopt', async () => {
    const fixture = await seedCatalog();
    const context = await contextFor(fixture, restaurantId);
    // Mirage claims the name exists but the reconcile list comes back empty —
    // the one case where guessing would file products under a stranger's tab.
    mirage.failNext({
      method: 'createCategory',
      status: 400,
      message: 'Category already exist.Category name should be unique',
    });

    const result = await categoryExecutor(step(fixture, 'CREATE'), context);

    expect(result).toMatchObject({
      outcome: 'FAILED',
      code: 'PUBLISH_CATEGORY_RECONCILE_FAILED',
    });
    // OUR sentence, not Mirage's — its prose stops inside the adapter.
    expect(result.message).not.toContain('Category already exist.Category name should be unique');
  });
});

describe('categoryExecutor — UPDATE', () => {
  it('renames on Mirage and keeps the local display name', async () => {
    const fixture = await seedCatalog();
    let context = await contextFor(fixture, restaurantId);
    await categoryExecutor(step(fixture, 'CREATE'), context);

    await CatalogCategory.updateOne(
      { _id: fixture.categoryId },
      { $set: { name: 'Patio Seating' } }
    ).exec();

    context = await contextFor(fixture, restaurantId);
    const result = await categoryExecutor(
      { ...step(fixture, 'UPDATE'), targetName: 'Patio Seating' },
      context
    );

    expect(result.outcome).toBe('SUCCEEDED');
    expect([...mirage.categories.values()][0].name).toBe('patio_seating');
    const stored = await CatalogCategory.findById(fixture.categoryId).lean().exec();
    expect(stored?.name).toBe('Patio Seating');
  });

  it('re-creates a category Mirage no longer has, in the same run', async () => {
    const fixture = await seedCatalog();
    let context = await contextFor(fixture, restaurantId);
    await categoryExecutor(step(fixture, 'CREATE'), context);
    const firstId = [...mirage.categories.values()][0].id;

    // Mirage's delete-item cascade took it out from under us.
    mirage.categories.delete(firstId);

    context = await contextFor(fixture, restaurantId);
    const result = await categoryExecutor(step(fixture, 'UPDATE'), context);

    expect(result.outcome).toBe('SUCCEEDED');
    const stored = await CatalogCategory.findById(fixture.categoryId).lean().exec();
    expect(stored?.mirageCategoryId).not.toBe(firstId);
    expect(mirage.categories.has(stored?.mirageCategoryId as string)).toBe(true);
  });
});

describe('categoryExecutor — guards', () => {
  it('fails the row rather than the run when the restaurant is unresolved', async () => {
    const fixture = await seedCatalog();
    const context = await contextFor(fixture, restaurantId);
    delete (context as { mirageRestaurantId?: string }).mirageRestaurantId;

    const result = await categoryExecutor(step(fixture, 'CREATE'), context);

    expect(result).toMatchObject({
      outcome: 'FAILED',
      code: 'PUBLISH_RESTAURANT_UNRESOLVED',
    });
    expect(mirage.writes).toHaveLength(0);
  });

  it('lets a retryable Mirage failure through to the worker’s backoff', async () => {
    const fixture = await seedCatalog();
    const context = await contextFor(fixture, restaurantId);
    mirage.failNext({ method: 'createCategory', status: 503, message: 'Service Unavailable' });

    await expect(categoryExecutor(step(fixture, 'CREATE'), context)).rejects.toMatchObject({
      name: 'MirageError',
      failureClass: 'retryable',
    });
  });
});

describe('the Uncategorized bucket (feature 26)', () => {
  it('is created at most once per run and remembered on the catalog', async () => {
    const fixture = await seedCatalog();
    const context = await contextFor(fixture, restaurantId);

    const first = await ensureUncategorizedCategory(context, restaurantId);
    const second = await ensureUncategorizedCategory(context, restaurantId);

    expect(first).toBe(second);
    expect(mirage.callsTo('createCategory')).toHaveLength(1);
    const catalog = await Catalog.findById(fixture.catalogId).lean().exec();
    expect(catalog?.mirageUncategorizedCategoryId).toBe(first);
  });

  it('is not created for a catalog that never asks for it', async () => {
    await seedCatalog();
    expect(mirage.categories.size).toBe(0);
  });

  it('adopts an existing bucket instead of colliding on the name', async () => {
    const fixture = await seedCatalog();
    const context = await contextFor(fixture, restaurantId);
    const preexisting = await mirage.createCategory({ name: 'uncategorized', restaurantId });
    mirage.calls.length = 0;

    const resolved = await ensureUncategorizedCategory(context, restaurantId);

    expect(resolved).toBe(preexisting.id);
    expect(mirage.categories.size).toBe(1);
  });
});

describe('cascade repair', () => {
  it('clears the local mapping when Mirage deleted the category behind us', async () => {
    const fixture = await seedCatalog();
    const context = await contextFor(fixture, restaurantId);
    await categoryExecutor(step(fixture, 'CREATE'), context);
    const mirageCategoryId = [...mirage.categories.values()][0].id;

    await repairCascadedCategory(context, mirageCategoryId);

    const stored = await CatalogCategory.findById(fixture.categoryId).lean().exec();
    expect(stored?.mirageCategoryId).toBeUndefined();
    expect(stored?.syncStatus).toBe('NEVER');
    expect(context.mirageCategoryIds.size).toBe(0);
  });

  it('also forgets the Uncategorized bucket when that is what cascaded', async () => {
    const fixture = await seedCatalog();
    const context = await contextFor(fixture, restaurantId);
    const bucket = (await ensureUncategorizedCategory(context, restaurantId)) as string;

    await repairCascadedCategory(context, bucket);

    expect(context.uncategorizedMirageCategoryId).toBeUndefined();
    const catalog = await Catalog.findById(fixture.catalogId).lean().exec();
    expect(catalog?.mirageUncategorizedCategoryId).toBeUndefined();
  });
});
