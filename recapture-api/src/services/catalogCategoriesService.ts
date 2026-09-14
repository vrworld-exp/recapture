// src/services/catalogCategoriesService.ts
//
// Categories inside one catalog (features 22-26, 47).
//
// Categories are not optional plumbing: Mirage's create-item rejects a missing
// or invalid category id, so nothing publishes until these exist on the Mirage
// side. The "Uncategorized" bucket is a NULL `categoryId` on the product here,
// materialised as a real Mirage category by the publish worker.
//
// ── NOTHING SHOULD REACH THAT BUCKET ANY MORE ────────────────────────────────
// The materialised bucket surfaces on the live page as a tab called
// "uncategorized" — a slug the customer reads as a category nobody recognises.
// It was reported as exactly that. So the rule is now that a product is NEVER
// uncategorized while the catalog has a category to put it in, enforced at
// every write that could produce one:
//
//   • a product created with no category is filed into the FIRST category
//     (catalogProductsService.createProduct → firstCategoryId);
//   • the FIRST category created adopts every product that predates it
//     (createCategory → adoptedProductCount);
//   • deleting a category moves its products to the first REMAINING one, and
//     only to null when there is nothing left to move them to (deleteCategory).
//
// The one state this cannot prevent — products and no categories at all — is
// refused at publish by CATALOG_NO_CATEGORIES (catalogPublishService), and a
// stray that survives from before these rules by PRODUCT_UNCATEGORIZED. The
// bucket code in categorySync stays as the backstop for data written before
// this, not as a destination anything here still aims at.
import { Types } from 'mongoose';
import { CatalogCategory, type ICatalogCategory } from '@/models/CatalogCategory';
import { CatalogProduct } from '@/models/CatalogProduct';
import type { SyncStatus } from '@/models/types/catalog.types';
import {
  bumpDraftRevision,
  findOwnedCatalog,
  isDuplicateKeyError,
} from '@/services/catalogService';
import type { CreateCategoryInput, UpdateCategoryInput } from '@/validation/catalogSchemas';

/**
 * Owner-facing category shape. Field by field — `mirageCategoryId` and the
 * internal sync bookkeeping stay server-side; the client gets the STATUS, which
 * is what the publish screen renders, not the mapping.
 */
export interface CategoryDto {
  id: string;
  name: string;
  position: number;
  productCount: number;
  syncStatus: SyncStatus;
  /** OUR message for the last failure, never Mirage's prose. Null when fine. */
  syncError: string | null;
  updatedAt: string;
  createdAt: string;
}

function toCategoryDto(c: ICatalogCategory, productCount: number): CategoryDto {
  return {
    id: c.id as string,
    name: c.name,
    position: c.position,
    productCount,
    syncStatus: c.syncStatus,
    syncError: c.syncError?.message ?? null,
    updatedAt: c.updatedAt.toISOString(),
    createdAt: c.createdAt.toISOString(),
  };
}

/** Product counts for a set of categories, as `categoryId → count`. One
 *  aggregation for the whole list — never one query per category. */
async function productCountsByCategory(
  catalogId: Types.ObjectId
): Promise<Map<string, number>> {
  const rows = await CatalogProduct.aggregate<{ _id: Types.ObjectId | null; count: number }>([
    { $match: { catalogId, deletedAt: null, archivedAt: null } },
    { $group: { _id: '$categoryId', count: { $sum: 1 } } },
  ]).exec();

  const map = new Map<string, number>();
  for (const row of rows) {
    if (row._id) map.set(row._id.toHexString(), row.count);
  }
  return map;
}

export type ListCategoriesResult =
  | { outcome: 'NO_CATALOG' }
  | { outcome: 'OK'; categories: CategoryDto[]; uncategorizedCount: number };

/**
 * Lists the caller's categories in display order.
 *
 * `uncategorizedCount` rides alongside rather than as a synthetic category row:
 * Uncategorized is the ABSENCE of a category, and inventing a fake row with an
 * id the client could then try to rename or delete is how that leaks.
 */
export async function listCategories(userId: string): Promise<ListCategoriesResult> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NO_CATALOG' };

  const catalogId = catalog._id as Types.ObjectId;

  const [rows, counts, uncategorizedCount] = await Promise.all([
    CatalogCategory.find({ catalogId, deletedAt: null })
      .sort({ position: 1, _id: 1 })
      .exec(),
    productCountsByCategory(catalogId),
    CatalogProduct.countDocuments({
      catalogId,
      deletedAt: null,
      archivedAt: null,
      categoryId: null,
    }).exec(),
  ]);

  return {
    outcome: 'OK',
    categories: rows.map((r) => toCategoryDto(r, counts.get(r.id as string) ?? 0)),
    uncategorizedCount,
  };
}

/**
 * The category a product lands in when nobody picked one.
 *
 * The FIRST by display position, or null for a catalog with no categories yet.
 * "First" rather than "most recent" because it is the one the customer meets
 * first on the page and the one an author sees at the top of every picker — a
 * dish filed there is findable; one filed into whatever was created last is a
 * surprise.
 */
export async function firstCategoryId(
  catalogId: Types.ObjectId
): Promise<Types.ObjectId | null> {
  const first = await CatalogCategory.findOne({ catalogId, deletedAt: null })
    .sort({ position: 1, _id: 1 })
    .select('_id')
    .lean()
    .exec();
  return first ? (first._id as Types.ObjectId) : null;
}

export type CreateCategoryResult =
  | { outcome: 'NO_CATALOG' }
  | { outcome: 'DUPLICATE_NAME' }
  | {
      outcome: 'CREATED';
      category: CategoryDto;
      /**
       * Products that had no category and were filed into this one because it
       * is the catalog's FIRST. Zero for every category after the first.
       */
      adoptedProductCount: number;
    };

/**
 * Creates a category.
 *
 * Name uniqueness is enforced by the partial unique index, NOT by a preceding
 * read: two concurrent creates would both pass a read-then-write. The E11000 is
 * translated to DUPLICATE_NAME. Catching it here rather than at publish time is
 * the point — Mirage rejects a duplicate (name, restaurant) outright, and that
 * failure is far more expensive to explain once the user has walked away.
 */
export async function createCategory(
  userId: string,
  input: CreateCategoryInput
): Promise<CreateCategoryResult> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NO_CATALOG' };

  const catalogId = catalog._id as Types.ObjectId;
  const position = input.position ?? (await nextCategoryPosition(catalogId));

  // Read BEFORE the insert: whether this is the catalog's first category is
  // what decides the adoption below, and after the insert it never is.
  const hadCategories =
    (await CatalogCategory.exists({ catalogId, deletedAt: null }).exec()) !== null;

  let created: ICatalogCategory;
  try {
    created = await CatalogCategory.create({
      catalogId,
      userId: new Types.ObjectId(userId),
      name: input.name,
      position,
    });
  } catch (err) {
    if (isDuplicateKeyError(err)) return { outcome: 'DUPLICATE_NAME' };
    throw err;
  }

  // THE FIRST CATEGORY ADOPTS THE STRAYS. Products are routinely created
  // before anyone thinks to make a section (a rep photographing dishes at a
  // table, an owner importing captures), and until this they stayed
  // uncategorized until somebody reopened each one. Only the first category
  // does this: a second one called "Drinks" must not swallow every unfiled
  // starter on the menu. Two concurrent first creates both sweep, and the
  // second sweep finds nothing left — no lock needed.
  let adopted = 0;
  if (!hadCategories) {
    const swept = await CatalogProduct.updateMany(
      { catalogId, categoryId: null, deletedAt: null },
      { $set: { categoryId: created._id } }
    ).exec();
    adopted = swept.modifiedCount;
  }

  await bumpDraftRevision(catalogId);

  return {
    outcome: 'CREATED',
    category: toCategoryDto(created, adopted),
    adoptedProductCount: adopted,
  };
}

/** Appends after the current last category. Ties are broken by `_id` in the
 *  index, so an equal position is ordered deterministically rather than wrongly. */
async function nextCategoryPosition(catalogId: Types.ObjectId): Promise<number> {
  const last = await CatalogCategory.findOne({ catalogId, deletedAt: null })
    .sort({ position: -1 })
    .select('position')
    .exec();

  return last ? last.position + 1 : 0;
}

export type UpdateCategoryResult =
  | { outcome: 'NO_CATALOG' }
  | { outcome: 'NOT_FOUND' }
  | { outcome: 'DUPLICATE_NAME' }
  | { outcome: 'UPDATED'; category: CategoryDto };

/** Renames and/or repositions a category (feature 23a). */
export async function updateCategory(
  userId: string,
  categoryId: string,
  input: UpdateCategoryInput
): Promise<UpdateCategoryResult> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NO_CATALOG' };

  const catalogId = catalog._id as Types.ObjectId;

  const set: Record<string, unknown> = {};
  if (input.name !== undefined) set.name = input.name;
  if (input.position !== undefined) set.position = input.position;

  try {
    const updated = await CatalogCategory.findOneAndUpdate(
      { _id: new Types.ObjectId(categoryId), catalogId, deletedAt: null },
      { $set: set },
      { new: true, runValidators: true }
    ).exec();

    if (!updated) return { outcome: 'NOT_FOUND' };

    await bumpDraftRevision(catalogId);

    const counts = await productCountsByCategory(catalogId);
    return {
      outcome: 'UPDATED',
      category: toCategoryDto(updated, counts.get(updated.id as string) ?? 0),
    };
  } catch (err) {
    if (isDuplicateKeyError(err)) return { outcome: 'DUPLICATE_NAME' };
    throw err;
  }
}

/** Where a deleted category's products went, as the client says it. */
export interface MovedToCategory {
  id: string;
  name: string;
}

export type DeleteCategoryResult =
  | { outcome: 'NO_CATALOG' }
  | { outcome: 'NOT_FOUND' }
  | {
      outcome: 'DELETED';
      movedProductCount: number;
      /**
       * The category the products were moved INTO — the first remaining one —
       * or null when this was the last category and they had nowhere to go but
       * Uncategorized (which publish will then refuse, by design).
       */
      movedTo: MovedToCategory | null;
    };

/**
 * Soft-deletes a category and moves its products to the first REMAINING
 * category (feature 23b, re-decided under the no-uncategorized rule).
 *
 * Moving rather than cascading is the deliberate choice: deleting a grouping
 * must not delete the products inside it. They used to go to Uncategorized —
 * a null `categoryId` — which put a tab called "uncategorized" on the live
 * page the next time anyone published. Now they go to the first category still
 * standing, and to null ONLY when there is none, in which case the publish
 * gate says so before a customer can.
 *
 * Products are moved BEFORE the category flips to deleted. The other order
 * would leave a window where a product points at a deleted category, which the
 * publish planner would read as a category it still has to create.
 */
export async function deleteCategory(
  userId: string,
  categoryId: string
): Promise<DeleteCategoryResult> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NO_CATALOG' };

  const catalogId = catalog._id as Types.ObjectId;
  const id = new Types.ObjectId(categoryId);

  const category = await CatalogCategory.findOne({ _id: id, catalogId, deletedAt: null }).exec();
  if (!category) return { outcome: 'NOT_FOUND' };

  // The destination is decided BEFORE the delete so the doomed category can
  // never be its own destination, and read by position so it is the same
  // "first" a new product would be filed into.
  const destination = await CatalogCategory.findOne({
    catalogId,
    deletedAt: null,
    _id: { $ne: id },
  })
    .sort({ position: 1, _id: 1 })
    .select('_id name')
    .lean()
    .exec();

  const moved = await CatalogProduct.updateMany(
    { catalogId, categoryId: id, deletedAt: null },
    { $set: { categoryId: destination ? (destination._id as Types.ObjectId) : null } }
  ).exec();

  // Conditional on still-live so a concurrent double-delete has exactly one
  // winner and the original deletedAt is never overwritten.
  await CatalogCategory.updateOne(
    { _id: id, catalogId, deletedAt: null },
    { $set: { deletedAt: new Date() } }
  ).exec();

  await bumpDraftRevision(catalogId);

  return {
    outcome: 'DELETED',
    movedProductCount: moved.modifiedCount,
    movedTo: destination
      ? { id: String(destination._id), name: destination.name as string }
      : null,
  };
}

export type ReorderCategoriesResult =
  | { outcome: 'NO_CATALOG' }
  | { outcome: 'ID_SET_MISMATCH' }
  | { outcome: 'REORDERED'; categories: CategoryDto[] };

/**
 * Reorders categories (feature 23c). The request carries the full ordered id
 * list and position becomes the array index, so the result cannot have gaps,
 * collisions, or a half-applied ordering.
 *
 * The id set must match the catalog's live categories EXACTLY. A partial list
 * would silently leave the omitted rows at stale positions, interleaving them
 * unpredictably with the new ones — better to reject and let the client resend.
 * The mismatch is one opaque outcome: it never reports WHICH id was foreign,
 * which would confirm the existence of another user's row.
 */
export async function reorderCategories(
  userId: string,
  ids: string[]
): Promise<ReorderCategoriesResult> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NO_CATALOG' };

  const catalogId = catalog._id as Types.ObjectId;

  const live = await CatalogCategory.find({ catalogId, deletedAt: null }).select('_id').exec();
  const liveIds = new Set(live.map((c) => c.id as string));

  if (liveIds.size !== ids.length || !ids.every((id) => liveIds.has(id))) {
    return { outcome: 'ID_SET_MISMATCH' };
  }

  await CatalogCategory.bulkWrite(
    ids.map((id, index) => ({
      updateOne: {
        filter: { _id: new Types.ObjectId(id), catalogId, deletedAt: null },
        update: { $set: { position: index } },
      },
    }))
  );

  await bumpDraftRevision(catalogId);

  const result = await listCategories(userId);
  return result.outcome === 'OK'
    ? { outcome: 'REORDERED', categories: result.categories }
    : { outcome: 'NO_CATALOG' };
}
