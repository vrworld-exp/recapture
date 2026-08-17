// src/services/catalogCategoriesService.ts
//
// Categories inside one catalog (features 22-26, 47).
//
// Categories are not optional plumbing: Mirage's create-item rejects a missing
// or invalid category id, so nothing publishes until these exist on the Mirage
// side. The "Uncategorized" bucket is a NULL `categoryId` on the product here,
// materialised as a real Mirage category by the publish worker.
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

export type CreateCategoryResult =
  | { outcome: 'NO_CATALOG' }
  | { outcome: 'DUPLICATE_NAME' }
  | { outcome: 'CREATED'; category: CategoryDto };

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

  try {
    const created = await CatalogCategory.create({
      catalogId,
      userId: new Types.ObjectId(userId),
      name: input.name,
      position,
    });

    await bumpDraftRevision(catalogId);

    return { outcome: 'CREATED', category: toCategoryDto(created, 0) };
  } catch (err) {
    if (isDuplicateKeyError(err)) return { outcome: 'DUPLICATE_NAME' };
    throw err;
  }
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

export type DeleteCategoryResult =
  | { outcome: 'NO_CATALOG' }
  | { outcome: 'NOT_FOUND' }
  | { outcome: 'DELETED'; movedProductCount: number };

/**
 * Soft-deletes a category and moves its products to Uncategorized (feature 23b).
 *
 * Moving rather than cascading is the deliberate choice: deleting a grouping
 * must not delete the products inside it, and Uncategorized already exists as a
 * first-class destination (a null `categoryId`). The publish worker turns that
 * into the Mirage-side move on the next run.
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

  const moved = await CatalogProduct.updateMany(
    { catalogId, categoryId: id, deletedAt: null },
    { $set: { categoryId: null } }
  ).exec();

  // Conditional on still-live so a concurrent double-delete has exactly one
  // winner and the original deletedAt is never overwritten.
  await CatalogCategory.updateOne(
    { _id: id, catalogId, deletedAt: null },
    { $set: { deletedAt: new Date() } }
  ).exec();

  await bumpDraftRevision(catalogId);

  return { outcome: 'DELETED', movedProductCount: moved.modifiedCount };
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
