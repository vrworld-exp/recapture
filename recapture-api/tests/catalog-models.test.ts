// tests/catalog-models.test.ts
//
// The catalog data model's load-bearing guarantees, at the schema level:
//
//   • ONE catalog per user — enforced by a unique index, not by a read-then-
//     write, so two concurrent creates cannot both win.
//   • The revision defaults that make "draft changes not yet live" true for a
//     brand-new catalog without a special case.
//   • Every compound index the architecture names for a real query path is
//     actually declared (a missing one is a silent collection scan later).
//   • Category names are unique within a catalog among LIVE rows only.
//   • Publish runs are idempotent per (user, Idempotency-Key), and runs without
//     a key never collide.
//
// Hermetic: in-memory MongoDB, no network.
import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { Catalog } from '@/models/Catalog';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogProduct } from '@/models/CatalogProduct';
import { CatalogPublishRun } from '@/models/CatalogPublishRun';

let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  // The uniqueness guarantees below ARE indexes — build them before asserting.
  await Catalog.syncIndexes();
  await CatalogCategory.syncIndexes();
  await CatalogProduct.syncIndexes();
  await CatalogPublishRun.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(async () => {
  await Promise.all([
    Catalog.deleteMany({}),
    CatalogCategory.deleteMany({}),
    CatalogProduct.deleteMany({}),
    CatalogPublishRun.deleteMany({}),
  ]);
});

/**
 * The declared index key patterns of a collection, as comparable strings.
 * Takes just the `collection` handle so it works for every model without
 * fighting `Model<T>`'s invariance in T.
 */
async function indexKeys(source: { collection: mongoose.Collection }): Promise<string[]> {
  const indexes = (await source.collection.indexes()) as { key: Record<string, number> }[];
  return indexes.map((i) => JSON.stringify(i.key));
}

describe('Catalog — one per user', () => {
  it('rejects a second catalog for the same user under a CONCURRENT create', async () => {
    const userId = new Types.ObjectId();

    // Both inserts are in flight at once: a read-then-write guard in a service
    // would let both through, which is exactly why the rule lives in the index.
    const results = await Promise.allSettled([
      Catalog.create({ userId, name: 'Cafe Mocha' }),
      Catalog.create({ userId, name: 'Cafe Mocha (2)' }),
    ]);

    const fulfilled = results.filter((r) => r.status === 'fulfilled');
    const rejected = results.filter((r) => r.status === 'rejected');

    expect(fulfilled).toHaveLength(1);
    expect(rejected).toHaveLength(1);
    expect((rejected[0] as PromiseRejectedResult).reason).toMatchObject({ code: 11000 });
    await expect(Catalog.countDocuments({ userId })).resolves.toBe(1);
  });

  it('rejects a second catalog for the same user sequentially', async () => {
    const userId = new Types.ObjectId();
    await Catalog.create({ userId, name: 'First' });
    await expect(Catalog.create({ userId, name: 'Second' })).rejects.toMatchObject({
      code: 11000,
    });
  });

  it('allows one catalog each for different users', async () => {
    await Catalog.create({ userId: new Types.ObjectId(), name: 'A' });
    await Catalog.create({ userId: new Types.ObjectId(), name: 'B' });
    await expect(Catalog.countDocuments({})).resolves.toBe(2);
  });
});

describe('Catalog — defaults and shape', () => {
  it('starts DRAFT at draftRevision 0 / publishedRevision -1, with no public URL', async () => {
    const catalog = await Catalog.create({ userId: new Types.ObjectId(), name: 'Cafe' });

    expect(catalog.status).toBe('DRAFT');
    expect(catalog.draftRevision).toBe(0);
    // -1 (not 0) so a brand-new catalog already reads as "not yet live" via
    // draftRevision > publishedRevision, with no special case.
    expect(catalog.publishedRevision).toBe(-1);
    expect(catalog.draftRevision).toBeGreaterThan(catalog.publishedRevision);
    expect(catalog.publicUrl).toBeUndefined();
    expect(catalog.publicUrlScheme).toBeUndefined();
    expect(catalog.mirageRestaurantId).toBeUndefined();
    // Explicitly null, not unset: the conditional findOneAndUpdate that claims a
    // publish run guards on `activePublishRunId: null`.
    expect(catalog.activePublishRunId).toBeNull();
  });

  it('stores the contact block, including the ReCapture-only fields', async () => {
    const catalog = await Catalog.create({
      userId: new Types.ObjectId(),
      name: 'Cafe',
      businessName: 'Cafe Mocha Pvt Ltd',
      contact: {
        phone: '9876543210',
        email: 'owner@example.com',
        address: '12 MG Road',
        website: 'https://example.com',
        socials: { instagram: '@cafemocha' },
      },
    });

    expect(catalog.contact?.phone).toBe('9876543210');
    expect(catalog.contact?.address).toBe('12 MG Road');
    expect(catalog.contact?.socials?.instagram).toBe('@cafemocha');
  });

  it('rejects a status outside the vocabulary', async () => {
    await expect(
      Catalog.create({
        userId: new Types.ObjectId(),
        name: 'Cafe',
        status: 'LIVE' as never,
      })
    ).rejects.toThrow();
  });
});

describe('CatalogCategory', () => {
  it('rejects a duplicate name within one catalog', async () => {
    const catalogId = new Types.ObjectId();
    const userId = new Types.ObjectId();
    await CatalogCategory.create({ catalogId, userId, name: 'Drinks', position: 0 });

    await expect(
      CatalogCategory.create({ catalogId, userId, name: 'Drinks', position: 1 })
    ).rejects.toMatchObject({ code: 11000 });
  });

  it('allows the same name in a different catalog', async () => {
    const userId = new Types.ObjectId();
    await CatalogCategory.create({
      catalogId: new Types.ObjectId(),
      userId,
      name: 'Drinks',
      position: 0,
    });
    await CatalogCategory.create({
      catalogId: new Types.ObjectId(),
      userId,
      name: 'Drinks',
      position: 0,
    });
    await expect(CatalogCategory.countDocuments({})).resolves.toBe(2);
  });

  it('lets a deleted name be re-created (the uniqueness is among live rows)', async () => {
    const catalogId = new Types.ObjectId();
    const userId = new Types.ObjectId();
    const first = await CatalogCategory.create({
      catalogId,
      userId,
      name: 'Drinks',
      position: 0,
    });

    first.deletedAt = new Date();
    await first.save();

    const second = await CatalogCategory.create({
      catalogId,
      userId,
      name: 'Drinks',
      position: 0,
    });
    expect(second.id).not.toBe(first.id);
    // The house exclusion form still finds exactly the live one.
    await expect(CatalogCategory.countDocuments({ catalogId, deletedAt: null })).resolves.toBe(
      1
    );
  });

  it('defaults to NEVER synced with no Mirage mapping', async () => {
    const category = await CatalogCategory.create({
      catalogId: new Types.ObjectId(),
      userId: new Types.ObjectId(),
      name: 'Drinks',
    });
    expect(category.syncStatus).toBe('NEVER');
    expect(category.mirageCategoryId).toBeUndefined();
    expect(category.position).toBe(0);
  });
});

describe('CatalogProduct', () => {
  const baseProduct = () => ({
    catalogId: new Types.ObjectId(),
    userId: new Types.ObjectId(),
    type: 'IMAGE_ONLY' as const,
    name: 'Filter Coffee',
  });

  it('defaults the ReCapture-only fields and starts unsynced', async () => {
    const product = await CatalogProduct.create(baseProduct());

    expect(product.currency).toBe('INR');
    expect(product.tags).toEqual([]);
    expect(product.availability).toBe('IN_STOCK');
    expect(product.featured).toBe(false);
    expect(product.position).toBe(0);
    expect(product.syncStatus).toBe('NEVER');
    expect(product.mirageItemId).toBeUndefined();
    expect(product.publishedSnapshot).toBeUndefined();
    // null, not unset — "uncategorized" is a real, queryable state.
    expect(product.categoryId).toBeNull();
  });

  it('keeps CloudFront URLs and the image S3 key apart on a 3D product', async () => {
    const product = await CatalogProduct.create({
      ...baseProduct(),
      type: 'THREE_D',
      sourceProjectId: new Types.ObjectId(),
      sourceModelId: new Types.ObjectId(),
      assets: {
        glbUrl: 'https://cdn.example.net/prod/p_1/j_1/models/m_1/model.glb',
        usdzUrl: 'https://cdn.example.net/prod/p_1/j_1/models/m_1/model.usdz',
        thumbnailUrl: 'https://cdn.example.net/prod/p_1/j_1/models/m_1/preview.png',
      },
    });

    expect(product.assets?.glbUrl).toContain('https://');
    expect(product.assets?.imageKey).toBeUndefined();
  });

  it('round-trips a published snapshot including fields added later', async () => {
    // Mixed on purpose: a strict sub-schema would DROP a newly diffed field,
    // and the planner would then read it back as "unchanged" and skip a real
    // change. This asserts the drop cannot happen.
    const product = await CatalogProduct.create({
      ...baseProduct(),
      publishedSnapshot: {
        name: 'Filter Coffee',
        price: 60,
        mirageCategoryId: '65f0000000000000000000aa',
        aFieldThePlannerStartedDiffingLater: 'kept',
      } as never,
    });

    const reloaded = await CatalogProduct.findById(product.id).lean();
    const snapshot = reloaded?.publishedSnapshot as Record<string, unknown> | undefined;
    expect(snapshot?.name).toBe('Filter Coffee');
    expect(snapshot?.aFieldThePlannerStartedDiffingLater).toBe('kept');
  });

  it('rejects a type outside the vocabulary', async () => {
    await expect(
      CatalogProduct.create({ ...baseProduct(), type: 'VIDEO' as never })
    ).rejects.toThrow();
  });

  it('allows the same name in two different catalogs', async () => {
    // Name uniqueness is a per-catalog PUBLISH gate (mirroring Mirage's
    // per-restaurant rule), deliberately not a unique index: two businesses
    // both selling "Regular" must not collide.
    await CatalogProduct.create({ ...baseProduct(), name: 'Regular' });
    await CatalogProduct.create({ ...baseProduct(), name: 'Regular' });
    await expect(CatalogProduct.countDocuments({ name: 'Regular' })).resolves.toBe(2);
  });
});

describe('CatalogPublishRun', () => {
  const baseRun = (userId: Types.ObjectId) => ({
    catalogId: new Types.ObjectId(),
    userId,
    jobId: new Types.ObjectId(),
    snapshotRevision: 3,
  });

  it('starts QUEUED with zeroed counts and no entries', async () => {
    const run = await CatalogPublishRun.create(baseRun(new Types.ObjectId()));
    expect(run.state).toBe('QUEUED');
    expect(run.counts.total).toBe(0);
    expect(run.counts.failed).toBe(0);
    expect(run.entries).toEqual([]);
  });

  it('records per-target entries as the activity log', async () => {
    const run = await CatalogPublishRun.create({
      ...baseRun(new Types.ObjectId()),
      entries: [
        {
          target: 'PRODUCT',
          targetId: new Types.ObjectId().toString(),
          targetName: 'Filter Coffee',
          action: 'CREATE',
          outcome: 'FAILED',
          code: 'PRODUCT_NAME_CONFLICT',
          at: new Date(),
        },
      ],
    });

    expect(run.entries).toHaveLength(1);
    expect(run.entries[0].code).toBe('PRODUCT_NAME_CONFLICT');
    expect(run.entries[0].outcome).toBe('FAILED');
  });

  it('rejects a replayed Idempotency-Key for the same user', async () => {
    const userId = new Types.ObjectId();
    await CatalogPublishRun.create({ ...baseRun(userId), idempotencyKey: 'pub-1' });

    await expect(
      CatalogPublishRun.create({ ...baseRun(userId), idempotencyKey: 'pub-1' })
    ).rejects.toMatchObject({ code: 11000 });
  });

  it('lets the same key be used by a different user, and no key never collides', async () => {
    await CatalogPublishRun.create({
      ...baseRun(new Types.ObjectId()),
      idempotencyKey: 'pub-1',
    });
    await CatalogPublishRun.create({
      ...baseRun(new Types.ObjectId()),
      idempotencyKey: 'pub-1',
    });

    const userId = new Types.ObjectId();
    await CatalogPublishRun.create(baseRun(userId));
    await CatalogPublishRun.create(baseRun(userId));

    await expect(CatalogPublishRun.countDocuments({})).resolves.toBe(4);
  });
});

describe('Indexes — every named query path is index-backed', () => {
  it('declares the catalog indexes', async () => {
    const keys = await indexKeys(Catalog);
    expect(keys).toContain(JSON.stringify({ userId: 1 }));
    expect(keys).toContain(JSON.stringify({ status: 1, updatedAt: -1 }));
  });

  it('declares the product indexes', async () => {
    const keys = await indexKeys(CatalogProduct);
    expect(keys).toContain(JSON.stringify({ catalogId: 1, position: 1, _id: 1 }));
    expect(keys).toContain(JSON.stringify({ catalogId: 1, categoryId: 1, deletedAt: 1 }));
    expect(keys).toContain(JSON.stringify({ catalogId: 1, syncStatus: 1 }));
    expect(keys).toContain(JSON.stringify({ catalogId: 1, name: 1 }));
    expect(keys).toContain(JSON.stringify({ mirageItemId: 1 }));
  });

  it('declares the category indexes', async () => {
    const keys = await indexKeys(CatalogCategory);
    expect(keys).toContain(JSON.stringify({ catalogId: 1, position: 1, _id: 1 }));
    expect(keys).toContain(JSON.stringify({ catalogId: 1, name: 1 }));
  });

  it('declares the publish-run indexes', async () => {
    const keys = await indexKeys(CatalogPublishRun);
    expect(keys).toContain(JSON.stringify({ catalogId: 1, createdAt: -1 }));
    expect(keys).toContain(JSON.stringify({ userId: 1, idempotencyKey: 1 }));
  });
});
