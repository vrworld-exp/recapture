// tests/fixtures/publishHarness.ts
//
// Seeding and wiring shared by the publish-executor suites.
//
// It exists so the three B2/B3 suites assert on BEHAVIOUR rather than each
// re-deriving how a catalog, a category, a product and a run fit together — and
// so a change to those shapes breaks one file, not four.
import { Types } from 'mongoose';

import { Catalog } from '@/models/Catalog';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogProduct } from '@/models/CatalogProduct';
import { CatalogPublishRun } from '@/models/CatalogPublishRun';
import type { PublishMode } from '@/models/types/catalog.types';
import { setAssetUploader, type AssetUploader } from '@/services/catalog/assetUploader';
import type { PublishRunContext } from '@/services/catalog/publishExecutors';
import { takeCatalogSnapshot } from '@/services/catalog/publishSnapshot';
import type { WorkerJob } from '@/worker/workerTypes';

export const TEST_USER_ID = new Types.ObjectId();

export interface SeedProduct {
  name: string;
  type?: 'THREE_D' | 'IMAGE_ONLY';
  position?: number;
  /** `null` seeds an UNCATEGORIZED product (feature 26). */
  category?: 'default' | null;
  price?: number;
  description?: string;
  assets?: Record<string, string>;
  mirageItemId?: string;
  mirageCategoryIdAtSync?: string;
  syncStatus?: 'NEVER' | 'PENDING' | 'SYNCED' | 'FAILED';
  publishedSnapshot?: Record<string, unknown>;
  archivedAt?: Date;
  deletedAt?: Date;
}

export interface SeedOptions {
  catalog?: Record<string, unknown>;
  categoryName?: string;
  categoryOverrides?: Record<string, unknown>;
  products?: SeedProduct[];
  runState?: 'QUEUED' | 'RUNNING';
}

export interface PublishFixture {
  catalogId: Types.ObjectId;
  categoryId: Types.ObjectId;
  productIds: Types.ObjectId[];
  runId: Types.ObjectId;
}

/** One catalog, one category, and whatever products the caller asked for. */
export async function seedCatalog(options: SeedOptions = {}): Promise<PublishFixture> {
  const catalog = await Catalog.create({
    userId: TEST_USER_ID,
    name: 'Blue Cafe',
    status: 'DRAFT',
    draftRevision: 3,
    publishedRevision: -1,
    ...options.catalog,
  });
  const catalogId = catalog._id as Types.ObjectId;

  const category = await CatalogCategory.create({
    catalogId,
    userId: TEST_USER_ID,
    name: options.categoryName ?? 'Garden Chairs',
    position: 0,
    ...options.categoryOverrides,
  });
  const categoryId = category._id as Types.ObjectId;

  const specs = options.products ?? [];
  const products = await Promise.all(
    specs.map((spec, index) =>
      CatalogProduct.create({
        catalogId,
        userId: TEST_USER_ID,
        type: spec.type ?? 'IMAGE_ONLY',
        name: spec.name,
        position: spec.position ?? index,
        categoryId: spec.category === null ? null : categoryId,
        ...(spec.price !== undefined ? { price: spec.price } : {}),
        ...(spec.description !== undefined ? { description: spec.description } : {}),
        assets: spec.assets ?? { imageKey: `prod/${spec.name}.jpg` },
        ...(spec.mirageItemId ? { mirageItemId: spec.mirageItemId } : {}),
        ...(spec.mirageCategoryIdAtSync
          ? { mirageCategoryIdAtSync: spec.mirageCategoryIdAtSync }
          : {}),
        ...(spec.syncStatus ? { syncStatus: spec.syncStatus } : {}),
        ...(spec.publishedSnapshot ? { publishedSnapshot: spec.publishedSnapshot } : {}),
        ...(spec.archivedAt ? { archivedAt: spec.archivedAt } : {}),
        ...(spec.deletedAt ? { deletedAt: spec.deletedAt } : {}),
      })
    )
  );

  const run = await CatalogPublishRun.create({
    catalogId,
    userId: TEST_USER_ID,
    jobId: new Types.ObjectId(),
    snapshotRevision: catalog.draftRevision,
    state: options.runState ?? 'QUEUED',
  });
  const runId = run._id as Types.ObjectId;
  await Catalog.updateOne({ _id: catalogId }, { $set: { activePublishRunId: runId } }).exec();

  return {
    catalogId,
    categoryId,
    productIds: products.map((p) => p._id as Types.ObjectId),
    runId,
  };
}

/** A run context over the CURRENT database state — re-read it after any write. */
export async function contextFor(
  fixture: PublishFixture,
  mirageRestaurantId: string,
  mode: PublishMode = 'FULL'
): Promise<PublishRunContext> {
  const snapshot = await takeCatalogSnapshot(fixture.catalogId);
  const mirageCategoryIds = new Map<string, string>();
  for (const category of snapshot.categories) {
    if (category.mirageCategoryId) mirageCategoryIds.set(category.id, category.mirageCategoryId);
  }
  return {
    runId: fixture.runId.toHexString(),
    catalogId: fixture.catalogId.toHexString(),
    userId: TEST_USER_ID.toHexString(),
    mode,
    snapshot,
    mirageRestaurantId,
    mirageCategoryIds,
    loggedOnce: new Set<string>(),
  };
}

export function publishJob(
  fixture: PublishFixture,
  mode: PublishMode = 'FULL',
  maxAttempts = 3
): WorkerJob {
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

/**
 * A stand-in for B3 that hands back one tiny byte buffer per requested slot.
 *
 * B2's executors must be exercised against a Mirage that REFUSES a product with
 * neither an image nor a model (adminController.js:1060-1066), so "no assets at
 * all" is not a usable baseline for these suites. What the uploader does NOT do
 * is anything B3 owns — no S3, no preflight, no size rules.
 */
export function stubAssetUploader(): { uploaded: string[][] } {
  const uploaded: string[][] = [];
  const uploader: AssetUploader = async ({ slots }) => {
    uploaded.push([...slots]);
    const files = Object.fromEntries(
      slots.map((slot) => [
        slot,
        { filename: `${slot}.bin`, contentType: 'application/octet-stream', bytes: Buffer.from([1]) },
      ])
    );
    return { outcome: 'READY', files, identities: {} };
  };
  setAssetUploader(uploader);
  return { uploaded };
}

export async function clearCatalogCollections(): Promise<void> {
  await Promise.all([
    Catalog.deleteMany({}),
    CatalogCategory.deleteMany({}),
    CatalogProduct.deleteMany({}),
    CatalogPublishRun.deleteMany({}),
  ]);
}
