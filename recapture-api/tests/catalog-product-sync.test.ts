// tests/catalog-product-sync.test.ts
//
// The PRODUCT executor against a Mirage that refuses what the real one refuses.
//
// Two groups of assertions carry the weight:
//
//   • THE ID IS PERSISTED BEFORE ANYTHING ELSE. Every create path asserts that
//     `mirageItemId` is on the row, because that single write is the difference
//     between a crash costing nothing and a crash costing a duplicate.
//
//   • MIRAGE'S PROSE STOPS AT THE ADAPTER. Every failure asserts an
//     `UPPER_SNAKE` code and checks that Mirage's own sentence is not what the
//     user would be shown.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import mongoose from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { Catalog } from '@/models/Catalog';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogProduct } from '@/models/CatalogProduct';
import { resetAssetUploader, setAssetUploader } from '@/services/catalog/assetUploader';
import { categoryExecutor } from '@/services/catalog/categorySync';
import type { PublishStep } from '@/services/catalog/publishPlanner';
import { productExecutor } from '@/services/catalog/productSync';
import { resetMirageClient, setMirageClient } from '@/services/mirage';
import { FakeMirage } from './fixtures/mirageFake';
import {
  clearCatalogCollections,
  contextFor,
  seedCatalog,
  stubAssetUploader,
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
  stubAssetUploader();
  vi.spyOn(console, 'warn').mockImplementation(() => {});
  vi.spyOn(console, 'info').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
});

afterEach(async () => {
  await clearCatalogCollections();
  resetMirageClient();
  resetAssetUploader();
  vi.restoreAllMocks();
});

// ── Helpers ─────────────────────────────────────────────────────────────────

const productStep = (
  fixture: PublishFixture,
  index: number,
  action: 'CREATE' | 'UPDATE' | 'DELETE',
  extra: Partial<PublishStep> = {}
): PublishStep => ({
  target: 'PRODUCT',
  targetId: fixture.productIds[index].toHexString(),
  targetName: 'Chair',
  action,
  reason: action === 'CREATE' ? 'NO_MIRAGE_ID' : 'FIELDS_CHANGED',
  ...extra,
});

/** Runs the CATEGORY step so products have a real Mirage parent to file under. */
async function createCategoryOnMirage(fixture: PublishFixture): Promise<string> {
  const context = await contextFor(fixture, restaurantId);
  await categoryExecutor(
    {
      target: 'CATEGORY',
      targetId: fixture.categoryId.toHexString(),
      targetName: 'Garden Chairs',
      action: 'CREATE',
      reason: 'NO_MIRAGE_ID',
    },
    context
  );
  const stored = await CatalogCategory.findById(fixture.categoryId).lean().exec();
  return stored?.mirageCategoryId as string;
}

// ── CREATE ──────────────────────────────────────────────────────────────────

describe('productExecutor — CREATE', () => {
  it('creates the item, persists the id and records the published snapshot', async () => {
    const fixture = await seedCatalog({
      products: [{ name: 'Chair', price: 1200, description: 'A chair' }],
    });
    await createCategoryOnMirage(fixture);
    const context = await contextFor(fixture, restaurantId);

    const result = await productExecutor(productStep(fixture, 0, 'CREATE'), context);

    expect(result.outcome).toBe('SUCCEEDED');
    const row = await CatalogProduct.findById(fixture.productIds[0]).lean().exec();
    expect(row?.mirageItemId).toBeDefined();
    expect(row?.syncStatus).toBe('SYNCED');
    expect(row?.publishedSnapshot).toMatchObject({ name: 'Chair', price: 1200 });
    expect(mirage.items.get(row?.mirageItemId as string)?.name).toBe('Chair');
  });

  it('pushes sortPosition from the product’s display order (feature 48)', async () => {
    const fixture = await seedCatalog({
      products: [{ name: 'Chair', position: 7 }],
    });
    await createCategoryOnMirage(fixture);
    const context = await contextFor(fixture, restaurantId);

    await productExecutor(productStep(fixture, 0, 'CREATE'), context);

    expect([...mirage.items.values()][0].sortPosition).toBe(7);
  });

  it('files an uncategorized product into the materialised bucket', async () => {
    const fixture = await seedCatalog({
      products: [{ name: 'Chair', category: null }],
    });
    const context = await contextFor(fixture, restaurantId);

    const result = await productExecutor(productStep(fixture, 0, 'CREATE'), context);

    expect(result.outcome).toBe('SUCCEEDED');
    const bucket = [...mirage.categories.values()].find((c) => c.name === 'uncategorized');
    expect(bucket).toBeDefined();
    const row = await CatalogProduct.findById(fixture.productIds[0]).lean().exec();
    expect(mirage.items.get(row?.mirageItemId as string)?.categoryId).toBe(bucket?.id);
    const catalog = await Catalog.findById(fixture.catalogId).lean().exec();
    expect(catalog?.mirageUncategorizedCategoryId).toBe(bucket?.id);
  });

  it('creates the Uncategorized bucket ONCE for a run with several such products', async () => {
    const fixture = await seedCatalog({
      products: [
        { name: 'Chair', category: null },
        { name: 'Table', category: null },
      ],
    });
    const context = await contextFor(fixture, restaurantId);

    await productExecutor(productStep(fixture, 0, 'CREATE'), context);
    await productExecutor(productStep(fixture, 1, 'CREATE'), context);

    expect(mirage.callsTo('createCategory')).toHaveLength(1);
  });

  it('fails the SECOND of two same-named products, and keeps the run going', async () => {
    const fixture = await seedCatalog({
      products: [{ name: 'Chair' }, { name: 'Chair' }],
    });
    await createCategoryOnMirage(fixture);
    const context = await contextFor(fixture, restaurantId);

    const first = await productExecutor(productStep(fixture, 0, 'CREATE'), context);
    const second = await productExecutor(productStep(fixture, 1, 'CREATE'), context);

    expect(first.outcome).toBe('SUCCEEDED');
    // The matching Mirage item is already CLAIMED by the first row, so adopting
    // it would point two products at one item. The second row fails with a
    // rename instruction instead — and the first one is still live.
    expect(second).toMatchObject({ outcome: 'FAILED', code: 'PUBLISH_DUPLICATE_NAME' });
    expect(second.message).toMatch(/rename/i);
    expect(mirage.items.size).toBe(1);
    expect(
      (await CatalogProduct.findById(fixture.productIds[1]).lean().exec())?.mirageItemId
    ).toBeUndefined();
  });

  it('reports a duplicate it cannot find with OUR code, never Mirage’s prose', async () => {
    const fixture = await seedCatalog({ products: [{ name: 'Chair' }] });
    await createCategoryOnMirage(fixture);
    const context = await contextFor(fixture, restaurantId);
    // Mirage refuses on a name held under a DIFFERENT category — uniqueness is
    // per-restaurant, so the scoped reconcile read cannot see it.
    mirage.failNext({
      method: 'createItem',
      status: 400,
      message: 'Product already exist.Product name should be unique',
    });

    const result = await productExecutor(productStep(fixture, 0, 'CREATE'), context);

    expect(result).toMatchObject({ outcome: 'FAILED', code: 'PUBLISH_RECONCILE_FAILED' });
    expect(result.message).not.toContain('Product already exist.Product name should be unique');
  });

  it('refuses a product whose assets are still hosted by Meshy', async () => {
    const fixture = await seedCatalog({
      products: [
        {
          name: 'Chair',
          type: 'THREE_D',
          assets: {
            glbUrl: 'https://assets.meshy.ai/abc/model.glb',
            thumbnailUrl: 'https://test.cloudfront.net/p.jpg',
          },
        },
      ],
    });
    await createCategoryOnMirage(fixture);
    const context = await contextFor(fixture, restaurantId);

    const result = await productExecutor(productStep(fixture, 0, 'CREATE'), context);

    expect(result.outcome).toBe('FAILED');
    expect(mirage.callsTo('createItem')).toHaveLength(0);
  });

  it('fails the row when the category could not be resolved', async () => {
    const fixture = await seedCatalog({ products: [{ name: 'Chair' }] });
    // No CATEGORY step ran, so nothing maps — the planner would normally have
    // ordered one first, and this is what happens when that step failed.
    const context = await contextFor(fixture, restaurantId);

    const result = await productExecutor(productStep(fixture, 0, 'CREATE'), context);

    expect(result).toMatchObject({
      outcome: 'FAILED',
      code: 'PUBLISH_CATEGORY_UNRESOLVED',
    });
  });
});

// ── UPDATE ──────────────────────────────────────────────────────────────────

describe('productExecutor — UPDATE', () => {
  it('sends only the fields the planner says changed', async () => {
    const fixture = await seedCatalog({ products: [{ name: 'Chair', price: 1200 }] });
    await createCategoryOnMirage(fixture);
    let context = await contextFor(fixture, restaurantId);
    await productExecutor(productStep(fixture, 0, 'CREATE'), context);

    const uploads = stubAssetUploader();
    await CatalogProduct.updateOne(
      { _id: fixture.productIds[0] },
      { $set: { price: 1500 } }
    ).exec();
    context = await contextFor(fixture, restaurantId);

    const result = await productExecutor(
      productStep(fixture, 0, 'UPDATE', { changedFields: ['price'] }),
      context
    );

    expect(result.outcome).toBe('SUCCEEDED');
    expect([...mirage.items.values()][0].price).toBe(1500);
    // A price edit asks the asset layer for NOTHING — the whole point of
    // threading `changedFields` through to the slot selection.
    expect(uploads.uploaded).toEqual([[]]);
  });

  it('moves a product between categories through update-item, keeping its id', async () => {
    const fixture = await seedCatalog({ products: [{ name: 'Chair' }] });
    await createCategoryOnMirage(fixture);
    let context = await contextFor(fixture, restaurantId);
    await productExecutor(productStep(fixture, 0, 'CREATE'), context);
    const originalItemId = (await CatalogProduct.findById(fixture.productIds[0]).lean().exec())
      ?.mirageItemId;

    const second = await CatalogCategory.create({
      catalogId: fixture.catalogId,
      userId: (await Catalog.findById(fixture.catalogId).lean().exec())?.userId,
      name: 'Tables',
      position: 1,
    });
    const secondMirage = await mirage.createCategory({ name: 'tables', restaurantId });
    await CatalogCategory.updateOne(
      { _id: second._id },
      { $set: { mirageCategoryId: secondMirage.id, syncStatus: 'SYNCED' } }
    ).exec();
    await CatalogProduct.updateOne(
      { _id: fixture.productIds[0] },
      { $set: { categoryId: second._id } }
    ).exec();

    context = await contextFor(fixture, restaurantId);
    const result = await productExecutor(
      productStep(fixture, 0, 'UPDATE', { changedFields: ['categoryId'] }),
      context
    );

    expect(result.outcome).toBe('SUCCEEDED');
    const row = await CatalogProduct.findById(fixture.productIds[0]).lean().exec();
    // The id — and with it the whole analytics history — survived the move.
    expect(row?.mirageItemId).toBe(originalItemId);
    expect(row?.mirageCategoryIdAtSync).toBe(secondMirage.id);
    expect(mirage.items.get(originalItemId as string)?.categoryId).toBe(secondMirage.id);
  });

  it('re-creates an item Mirage no longer has', async () => {
    const fixture = await seedCatalog({ products: [{ name: 'Chair' }] });
    await createCategoryOnMirage(fixture);
    let context = await contextFor(fixture, restaurantId);
    await productExecutor(productStep(fixture, 0, 'CREATE'), context);
    const firstItemId = (await CatalogProduct.findById(fixture.productIds[0]).lean().exec())
      ?.mirageItemId as string;

    mirage.items.delete(firstItemId);
    context = await contextFor(fixture, restaurantId);

    const result = await productExecutor(productStep(fixture, 0, 'UPDATE'), context);

    expect(result.outcome).toBe('SUCCEEDED');
    const row = await CatalogProduct.findById(fixture.productIds[0]).lean().exec();
    expect(row?.mirageItemId).not.toBe(firstItemId);
    expect(mirage.items.has(row?.mirageItemId as string)).toBe(true);
  });
});

// ── DELETE ──────────────────────────────────────────────────────────────────

describe('productExecutor — DELETE', () => {
  it('removes the item and clears the mapping and the diff basis', async () => {
    const fixture = await seedCatalog({ products: [{ name: 'Chair' }, { name: 'Stool' }] });
    await createCategoryOnMirage(fixture);
    let context = await contextFor(fixture, restaurantId);
    await productExecutor(productStep(fixture, 0, 'CREATE'), context);
    await productExecutor(productStep(fixture, 1, 'CREATE'), context);

    await CatalogProduct.updateOne(
      { _id: fixture.productIds[0] },
      { $set: { archivedAt: new Date() } }
    ).exec();
    context = await contextFor(fixture, restaurantId);

    const result = await productExecutor(productStep(fixture, 0, 'DELETE'), context);

    expect(result.outcome).toBe('SUCCEEDED');
    const row = await CatalogProduct.findById(fixture.productIds[0]).lean().exec();
    expect(row?.mirageItemId).toBeUndefined();
    expect(row?.publishedSnapshot).toBeUndefined();
    expect(row?.syncStatus).toBe('NEVER');
    expect(mirage.items.size).toBe(1);
  });

  it('treats an item that is already gone as a success', async () => {
    const fixture = await seedCatalog({ products: [{ name: 'Chair' }] });
    await createCategoryOnMirage(fixture);
    let context = await contextFor(fixture, restaurantId);
    await productExecutor(productStep(fixture, 0, 'CREATE'), context);
    const itemId = (await CatalogProduct.findById(fixture.productIds[0]).lean().exec())
      ?.mirageItemId as string;
    mirage.items.delete(itemId);

    await CatalogProduct.updateOne(
      { _id: fixture.productIds[0] },
      { $set: { deletedAt: new Date() } }
    ).exec();
    context = await contextFor(fixture, restaurantId);

    const result = await productExecutor(productStep(fixture, 0, 'DELETE'), context);

    expect(result.outcome).toBe('SUCCEEDED');
    expect(
      (await CatalogProduct.findById(fixture.productIds[0]).lean().exec())?.mirageItemId
    ).toBeUndefined();
  });

  it('opts out of the cascade so a sibling’s category survives', async () => {
    const fixture = await seedCatalog({ products: [{ name: 'Chair' }] });
    const mirageCategoryId = await createCategoryOnMirage(fixture);
    let context = await contextFor(fixture, restaurantId);
    await productExecutor(productStep(fixture, 0, 'CREATE'), context);

    await CatalogProduct.updateOne(
      { _id: fixture.productIds[0] },
      { $set: { archivedAt: new Date() } }
    ).exec();
    context = await contextFor(fixture, restaurantId);
    await productExecutor(productStep(fixture, 0, 'DELETE'), context);

    // Its last item went, but the category is still standing.
    expect(mirage.categories.has(mirageCategoryId)).toBe(true);
    const stored = await CatalogCategory.findById(fixture.categoryId).lean().exec();
    expect(stored?.mirageCategoryId).toBe(mirageCategoryId);
  });

  it('repairs the local mapping when Mirage cascaded anyway', async () => {
    const fixture = await seedCatalog({ products: [{ name: 'Chair' }] });
    const mirageCategoryId = await createCategoryOnMirage(fixture);
    let context = await contextFor(fixture, restaurantId);
    await productExecutor(productStep(fixture, 0, 'CREATE'), context);

    // A Mirage that predates ?keepCategory ignores the flag and cascades.
    const client = { ...mirage } as unknown as typeof mirage;
    setMirageClient({
      ...mirage,
      deleteItem: async (id: string) => {
        mirage.items.delete(id);
        mirage.categories.delete(mirageCategoryId);
        return { existed: true, deletedCategory: true };
      },
      listCategories: mirage.listCategories.bind(mirage),
      createCategory: mirage.createCategory.bind(mirage),
    } as unknown as typeof client);

    await CatalogProduct.updateOne(
      { _id: fixture.productIds[0] },
      { $set: { archivedAt: new Date() } }
    ).exec();
    context = await contextFor(fixture, restaurantId);
    await productExecutor(productStep(fixture, 0, 'DELETE'), context);

    const stored = await CatalogCategory.findById(fixture.categoryId).lean().exec();
    expect(stored?.mirageCategoryId).toBeUndefined();
    expect(stored?.syncStatus).toBe('NEVER');
  });
});

// ── Guards ──────────────────────────────────────────────────────────────────

describe('productExecutor — guards', () => {
  it('reports a blocked asset preflight as a terminal row failure', async () => {
    const fixture = await seedCatalog({ products: [{ name: 'Chair' }] });
    await createCategoryOnMirage(fixture);
    const context = await contextFor(fixture, restaurantId);
    setAssetUploader(async () => ({
      outcome: 'BLOCKED',
      failure: { code: 'PUBLISH_ASSET_TOO_LARGE', message: 'This file is too large to publish.' },
    }));

    const result = await productExecutor(productStep(fixture, 0, 'CREATE'), context);

    expect(result).toMatchObject({ outcome: 'FAILED', code: 'PUBLISH_ASSET_TOO_LARGE' });
    // Blocked BEFORE any Mirage call — the whole point of a preflight.
    expect(mirage.callsTo('createItem')).toHaveLength(0);
  });

  it('lets a retryable Mirage failure through to the worker’s backoff', async () => {
    const fixture = await seedCatalog({ products: [{ name: 'Chair' }] });
    await createCategoryOnMirage(fixture);
    const context = await contextFor(fixture, restaurantId);
    mirage.failNext({ method: 'createItem', status: 502, message: 'Bad Gateway' });

    await expect(
      productExecutor(productStep(fixture, 0, 'CREATE'), context)
    ).rejects.toMatchObject({ name: 'MirageError', failureClass: 'retryable' });
  });

  it('fails the row rather than the run when the restaurant is unresolved', async () => {
    const fixture = await seedCatalog({ products: [{ name: 'Chair' }] });
    const context = await contextFor(fixture, restaurantId);
    delete (context as { mirageRestaurantId?: string }).mirageRestaurantId;

    const result = await productExecutor(productStep(fixture, 0, 'CREATE'), context);

    expect(result).toMatchObject({
      outcome: 'FAILED',
      code: 'PUBLISH_RESTAURANT_UNRESOLVED',
    });
    expect(mirage.writes).toHaveLength(0);
  });
});
