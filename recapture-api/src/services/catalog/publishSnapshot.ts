// src/services/catalog/publishSnapshot.ts
//
// The frozen picture of a catalog that ONE publish run plans and executes from.
//
// WHY A SNAPSHOT AT ALL (feature 57). Publishing is an explicit user action that
// runs as one background job, not a per-edit auto-sync. The user keeps editing
// while the run is in flight, and the run must publish what they pressed the
// button on — not a moving target. So the whole catalog is read ONCE, here, and
// every later decision (the plan, the diffs, the Mirage calls) reads this object
// and never the live rows. `draftRevision` is captured at the same instant,
// which is what makes "only a fully successful run advances publishedRevision"
// mean something precise.
//
// It is deep-frozen on the way out. That is not decoration: a planner that could
// mutate its input would make "planning the same snapshot twice yields an
// identical plan" untestable, and the freeze turns an accidental write into a
// TypeError in dev rather than a wrong plan in production.
import { Types } from 'mongoose';

import { Catalog } from '@/models/Catalog';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogProduct } from '@/models/CatalogProduct';
import { effectiveModelStatus } from '@/models/types/catalog.types';
import type {
  CatalogContact,
  CatalogStatus,
  ProductModelStatus,
  ProductPublishedSnapshot,
  ProductType,
  SyncStatus,
} from '@/models/types/catalog.types';

/** The catalog root, as the planner sees it. */
export interface CatalogSnapshotRoot {
  id: string;
  userId: string;
  name: string;
  businessName?: string;
  logoKey?: string;
  coverImageKey?: string;
  contact?: CatalogContact;
  status: CatalogStatus;
  /** Absent ⇒ the plan must open with a RESTAURANT CREATE. */
  mirageRestaurantId?: string;
  /**
   * The materialised "Uncategorized" Mirage category, if one has ever been
   * needed. Carried into the snapshot so a run with categoryless products
   * reuses the existing bucket instead of spending a doomed create + a reconcile
   * list on every publish (categorySync.ensureUncategorizedCategory).
   */
  mirageUncategorizedCategoryId?: string;
  publicUrl?: string;
  /**
   * The revision this run is publishing. Copied here so the finalize step sets
   * `publishedRevision` to what was read at plan time, not to whatever the user
   * has edited it to by the time the run ends.
   */
  draftRevision: number;
  publishedRevision: number;
}

/** One category, as the planner sees it. */
export interface CatalogSnapshotCategory {
  id: string;
  name: string;
  position: number;
  mirageCategoryId?: string;
  syncStatus: SyncStatus;
  /**
   * The pair the planner uses to detect "edited since we last pushed it".
   * Categories carry no `publishedSnapshot` — the only field Mirage stores for
   * them is a name it mangles on the way in (lowercased, spaces underscored),
   * so its echo cannot be diffed against ours. Comparing our own timestamps is
   * both exact for the fields we push and safe in the one direction that
   * matters: it can plan a redundant UPDATE, never a missed one.
   */
  updatedAt: Date;
  lastSyncedAt?: Date;
}

/** One product, as the planner sees it. */
export interface CatalogSnapshotProduct {
  id: string;
  type: ProductType;
  name: string;
  description?: string;
  price?: number;
  /** null = uncategorized (materialised as a real Mirage category in B2). */
  categoryId: string | null;
  position: number;
  glbUrl?: string;
  usdzUrl?: string;
  thumbnailUrl?: string;
  imageKey?: string;
  /**
   * Carried so the planner can tell a dish waiting on its FIRST model from an
   * ordinary one. Never diffed — see PRODUCT_DIFF_FIELDS.
   */
  modelStatus: ProductModelStatus;
  mirageItemId?: string;
  mirageCategoryIdAtSync?: string;
  syncStatus: SyncStatus;
  publishedSnapshot?: ProductPublishedSnapshot;
  /** Hidden by the user — publishes as a DELETE once it has a Mirage id. */
  archivedAt?: Date;
  /** Soft-deleted — same treatment; see the query note below. */
  deletedAt?: Date;
}

export interface CatalogSnapshot {
  readonly catalog: CatalogSnapshotRoot;
  readonly categories: readonly CatalogSnapshotCategory[];
  readonly products: readonly CatalogSnapshotProduct[];
  /** When the three reads happened. Diagnostics only — never diffed. */
  readonly takenAt: Date;
}

/** The catalog vanished (hard-deleted) between enqueue and execution. */
export class CatalogSnapshotMissingError extends Error {
  constructor(public readonly catalogId: string) {
    super(`Catalog ${catalogId} no longer exists`);
    this.name = 'CatalogSnapshotMissingError';
  }
}

const idOf = (value: Types.ObjectId | string): string =>
  typeof value === 'string' ? value : value.toHexString();

/** Drops undefined keys so two snapshots of equal rows are structurally equal. */
function compact<T extends Record<string, unknown>>(value: T): T {
  for (const key of Object.keys(value)) {
    if (value[key] === undefined) delete value[key];
  }
  return value;
}

/** Freezes an object graph one level past the arrays it holds. */
function deepFreeze<T>(value: T): T {
  if (Array.isArray(value)) {
    value.forEach(deepFreeze);
    return Object.freeze(value);
  }
  if (value && typeof value === 'object' && !(value instanceof Date)) {
    Object.values(value as Record<string, unknown>).forEach(deepFreeze);
    return Object.freeze(value);
  }
  return value;
}

/**
 * Reads one catalog, its categories and its products, ONCE, and returns the
 * frozen plain-object view the run is planned and executed from.
 *
 * ⚠ THE PRODUCT QUERY IS DELIBERATELY NOT `deletedAt: null`. A soft-deleted or
 * archived product that still carries a `mirageItemId` is exactly the row that
 * needs a Mirage DELETE — filtering it out here would leave it live on the
 * public page forever, with nothing left in the system that remembers it should
 * not be. So the query is "live rows, plus dead rows Mirage still knows about",
 * which is still one round trip.
 *
 * Categories are read live-only: the planner has no CATEGORY DELETE action
 * (Mirage cascade-deletes a category when its last item goes, so the mapping is
 * cleaned up from the product side in B2), and a dead category with no products
 * left under it is already gone on Mirage's side.
 */
export async function takeCatalogSnapshot(catalogId: Types.ObjectId): Promise<CatalogSnapshot> {
  const catalog = await Catalog.findOne({ _id: catalogId, deletedAt: null }).lean().exec();
  if (!catalog) throw new CatalogSnapshotMissingError(catalogId.toHexString());

  const [categories, products] = await Promise.all([
    CatalogCategory.find({ catalogId, deletedAt: null })
      .sort({ position: 1, _id: 1 })
      .lean()
      .exec(),
    CatalogProduct.find({
      catalogId,
      $or: [{ deletedAt: null }, { mirageItemId: { $exists: true, $ne: null } }],
    })
      .sort({ position: 1, _id: 1 })
      .lean()
      .exec(),
  ]);

  const snapshot: CatalogSnapshot = {
    catalog: compact({
      id: idOf(catalog._id as Types.ObjectId),
      userId: idOf(catalog.userId),
      name: catalog.name,
      businessName: catalog.businessName,
      logoKey: catalog.logoKey,
      coverImageKey: catalog.coverImageKey,
      // Field-by-field, like every other normaliser in this codebase — a spread
      // would carry Mongoose internals into a structure the planner diffs.
      contact: catalog.contact
        ? compact({
            phone: catalog.contact.phone,
            email: catalog.contact.email,
            address: catalog.contact.address,
            website: catalog.contact.website,
            socials: catalog.contact.socials
              ? compact({
                  instagram: catalog.contact.socials.instagram,
                  facebook: catalog.contact.socials.facebook,
                  youtube: catalog.contact.socials.youtube,
                  whatsapp: catalog.contact.socials.whatsapp,
                })
              : undefined,
          })
        : undefined,
      status: catalog.status,
      mirageRestaurantId: catalog.mirageRestaurantId,
      mirageUncategorizedCategoryId: catalog.mirageUncategorizedCategoryId,
      publicUrl: catalog.publicUrl,
      draftRevision: catalog.draftRevision,
      publishedRevision: catalog.publishedRevision,
    }),
    categories: categories.map((category) =>
      compact({
        id: idOf(category._id as Types.ObjectId),
        name: category.name,
        position: category.position,
        mirageCategoryId: category.mirageCategoryId,
        syncStatus: category.syncStatus,
        updatedAt: category.updatedAt,
        lastSyncedAt: category.lastSyncedAt,
      })
    ),
    products: products.map((product) =>
      compact({
        id: idOf(product._id as Types.ObjectId),
        type: product.type,
        name: product.name,
        description: product.description,
        price: product.price,
        categoryId: product.categoryId ? idOf(product.categoryId) : null,
        position: product.position,
        glbUrl: product.assets?.glbUrl,
        usdzUrl: product.assets?.usdzUrl,
        thumbnailUrl: product.assets?.thumbnailUrl,
        imageKey: product.assets?.imageKey,
        // Derived, so a legacy row reads READY rather than NONE — the planner
        // must not mistake a long-published 3D dish for one awaiting a model.
        modelStatus: effectiveModelStatus(product),
        mirageItemId: product.mirageItemId,
        mirageCategoryIdAtSync: product.mirageCategoryIdAtSync,
        syncStatus: product.syncStatus,
        publishedSnapshot: product.publishedSnapshot as ProductPublishedSnapshot | undefined,
        archivedAt: product.archivedAt,
        deletedAt: product.deletedAt,
      })
    ),
    takenAt: new Date(),
  };

  return deepFreeze(snapshot);
}
