// src/services/catalog/categorySync.ts
//
// The CATEGORY executor: the real Mirage calls behind the planner's CREATE /
// UPDATE category steps, plus the "Uncategorized" bucket every categoryless
// product is filed into (feature 26).
//
// THREE THINGS THIS FILE IS RESPONSIBLE FOR, and they are all about surviving a
// system with no idempotency:
//
//   1. PERSIST THE ID FIRST. `createCategory` returns an id that exists nowhere
//      else — Mirage will not hand it back a second time, it will just refuse
//      the name. So the very next thing after the call returns is the write that
//      records it. Anything between them is an opportunity to lose it.
//
//   2. RECONCILE INSTEAD OF RETRYING. A create that comes back
//      "Category already exist" means one of two things: we made it on a previous
//      attempt and crashed before persisting, or someone made it in Mirage's own
//      admin panel. Both are repaired the same way — list the restaurant's
//      categories, match the NORMALIZED name, adopt the id. A retry could never
//      succeed; it would fail identically forever.
//
//   3. THE NAME IS ALREADY THE STORED NAME. ReCapture now slugs a category name
//      at the boundary (utils/catalogNames.ts), so `CatalogCategory.name` is
//      ALREADY the "garden_chairs" form Mirage keeps — the two sides hold the
//      same string and nothing has to be reconciled across a spelling
//      difference. `mirageCategoryName` therefore normally returns its input
//      unchanged; it stays in the call path for rows written before that change
//      (and for anything seeded straight into the collection), which is exactly
//      the case where sending the raw name would create a duplicate. Mirage's
//      echo is still never written back over our row.
import { Types } from 'mongoose';

import { Catalog } from '@/models/Catalog';
import { getMirageClient, MirageError, MirageErrorCode } from '@/services/mirage';
import type { MirageCategory } from '@/services/mirage';
import {
  CatalogSyncErrorCode,
  mapMirageFailure,
  syncFailure,
} from '@/services/catalog/publishSyncErrors';
import type {
  PublishRunContext,
  PublishStepExecutor,
  PublishStepResult,
} from '@/services/catalog/publishExecutors';
import { markCategorySynced } from '@/services/catalog/publishRunState';
import type { CatalogSnapshotCategory } from '@/services/catalog/publishSnapshot';
import { CatalogCategory } from '@/models/CatalogCategory';
import { toCatalogSlug } from '@/utils/catalogNames';

/** `CatalogCategory.name`'s own bound — slugging must not shorten past it. */
const CATEGORY_NAME_SLUG_MAX = 80;

/**
 * The name of the Uncategorized bucket, in the stored slug form.
 *
 * A real category with a real name, not a sentinel: it appears as a tab on the
 * public page like any other, because Mirage has no concept of an item without
 * a category and inventing a hidden one would only mean inventing a way to hide
 * it on the client too.
 *
 * Written as the slug rather than as "Uncategorized" so it reads as what is
 * actually stored on both sides — it is a name a user can see next to their own
 * categories, and those are all slugs now.
 */
export const UNCATEGORIZED_NAME = 'uncategorized';

/**
 * The name Mirage will actually store, computed on OUR side.
 *
 * ⚠ THIS IS NOT COSMETIC. Mirage's duplicate check compares the RAW request
 * name against stored names (adminController.js:724-733) and only normalizes
 * afterwards (adminController.js:738-739). Post "Garden Chairs" against a stored
 * "garden_chairs" and the check passes — creating a SECOND category that
 * normalizes to the identical name. Sending the normalized form is what makes
 * Mirage's own uniqueness check fire, and it is also what makes our
 * reconciliation lookup able to match.
 */
export function mirageCategoryName(name: string): string {
  return toCatalogSlug(name, { maxLength: CATEGORY_NAME_SLUG_MAX });
}

/** Finds a Mirage category by the name we would have sent for it. */
function findByName(
  categories: readonly MirageCategory[],
  name: string
): MirageCategory | undefined {
  const wanted = mirageCategoryName(name);
  return categories.find((category) => mirageCategoryName(category.name) === wanted);
}

/**
 * Records a category's Mirage id everywhere the run and the database need it.
 *
 * Three writes, deliberately in this order: the durable one first, because a
 * crash after it is recoverable and a crash before it is a duplicate. The
 * context map is what makes a product created ten steps later file itself under
 * the id that was actually minted rather than the absent one the frozen
 * snapshot recorded.
 */
async function adopt(
  context: PublishRunContext,
  categoryId: string,
  mirageCategoryId: string
): Promise<void> {
  await markCategorySynced(categoryId, mirageCategoryId);
  context.mirageCategoryIds.set(categoryId, mirageCategoryId);
}

/** The snapshot row a step points at. */
function categoryOf(
  context: PublishRunContext,
  categoryId: string | undefined
): CatalogSnapshotCategory | undefined {
  if (!categoryId) return undefined;
  return context.snapshot.categories.find((category) => category.id === categoryId);
}

/**
 * Creates the category, adopting an existing one when Mirage says the name is
 * taken.
 *
 * The reconcile read is `listCategories(restaurantId)`, which is scoped to this
 * restaurant — so a name matching some OTHER business's category cannot be
 * adopted by accident. When nothing matches, the row fails with
 * RECONCILE_FAILED rather than guessing: Mirage's containment-free equality
 * check means "already exists" and "nothing here has that name" cannot both be
 * true unless something outside this run changed underneath us, and adopting an
 * unrelated id would publish products into a stranger's tab.
 */
async function createCategory(
  context: PublishRunContext,
  category: CatalogSnapshotCategory,
  restaurantId: string
): Promise<PublishStepResult> {
  const client = getMirageClient();
  try {
    const created = await client.createCategory({
      name: mirageCategoryName(category.name),
      restaurantId,
      sortPosition: category.position,
    });
    await adopt(context, category.id, created.id);
    return { outcome: 'SUCCEEDED' };
  } catch (err) {
    if (!(err instanceof MirageError) || err.code !== MirageErrorCode.ALREADY_EXISTS) throw err;

    const existing = await client.listCategories(restaurantId);
    const match = findByName(existing, category.name);
    if (!match) {
      const failure = syncFailure(CatalogSyncErrorCode.CATEGORY_RECONCILE_FAILED);
      return { outcome: 'FAILED', code: failure.code, message: failure.message };
    }

    await adopt(context, category.id, match.id);
    return { outcome: 'SUCCEEDED' };
  }
}

/**
 * Renames/reorders the category, re-creating it when Mirage no longer has it.
 *
 * The 404 path is not an edge case, it is the normal consequence of Mirage's
 * delete-item cascade removing a category behind our back. Falling through to a
 * create is what converges the two systems in ONE run instead of failing the row
 * and asking the user to press Publish again.
 */
async function updateCategory(
  context: PublishRunContext,
  category: CatalogSnapshotCategory,
  restaurantId: string,
  mirageCategoryId: string
): Promise<PublishStepResult> {
  const client = getMirageClient();
  try {
    await client.updateCategory(mirageCategoryId, {
      name: mirageCategoryName(category.name),
      sortPosition: category.position,
    });
    // Mirage's echo (`garden_chairs`) is deliberately DROPPED here — only the
    // id and the sync timestamps are ours to write.
    await adopt(context, category.id, mirageCategoryId);
    return { outcome: 'SUCCEEDED' };
  } catch (err) {
    if (err instanceof MirageError && err.code === MirageErrorCode.NOT_FOUND) {
      return createCategory(context, category, restaurantId);
    }
    if (err instanceof MirageError && err.code === MirageErrorCode.ALREADY_EXISTS) {
      const failure = syncFailure(CatalogSyncErrorCode.DUPLICATE_NAME);
      return { outcome: 'FAILED', code: failure.code, message: failure.message };
    }
    throw err;
  }
}

/**
 * The CATEGORY executor.
 *
 * A retryable MirageError propagates: Mirage being asleep is not this category's
 * fault, and the processor turns the throw into the worker's existing backoff
 * with the run left RUNNING and resumable.
 */
export const categoryExecutor: PublishStepExecutor = async (step, context) => {
  const category = categoryOf(context, step.targetId);
  if (!step.targetId || !category) {
    // The row vanished between the snapshot and now. Nothing to publish and
    // nothing broken — the next run simply will not plan it.
    return { outcome: 'SKIPPED' };
  }

  const restaurantId = context.mirageRestaurantId;
  if (!restaurantId) {
    const failure = syncFailure(CatalogSyncErrorCode.RESTAURANT_UNRESOLVED);
    return { outcome: 'FAILED', code: failure.code, message: failure.message };
  }

  try {
    const known = context.mirageCategoryIds.get(category.id) ?? category.mirageCategoryId;
    return step.action === 'CREATE' || !known
      ? await createCategory(context, category, restaurantId)
      : await updateCategory(context, category, restaurantId, known);
  } catch (err) {
    if (!(err instanceof MirageError) || err.isRetryable) throw err;
    const failure = mapMirageFailure(
      err,
      step.action === 'CREATE' ? 'CREATE_CATEGORY' : 'UPDATE_CATEGORY'
    );
    return { outcome: 'FAILED', code: failure.code, message: failure.message };
  }
};

// ── The Uncategorized bucket (feature 26) ───────────────────────────────────

/**
 * The Mirage category a product with no ReCapture category is filed under,
 * materialised on demand.
 *
 * ON DEMAND is the whole design. Mirage's create-item rejects a missing or
 * invalid category ObjectId outright (adminController.js:1068-1073), so a
 * categoryless product needs a real one — but a catalog whose products are all
 * categorised must not grow an empty "uncategorized" tab on its public page just
 * because the code could create one. So this is called from exactly one place:
 * the product executor, when it finds a product with `categoryId: null`.
 *
 * ONCE PER RUN is the second half. `context.uncategorizedMirageCategoryId` short-
 * circuits every call after the first, and the id is also written to the catalog
 * so the NEXT run reuses it instead of colliding on the name — which would work
 * (reconciliation adopts it) but would spend a wasted create + list on every
 * publish forever.
 *
 * Returns undefined when the bucket could not be established; the caller turns
 * that into a row failure rather than a thrown run failure.
 */
export async function ensureUncategorizedCategory(
  context: PublishRunContext,
  restaurantId: string
): Promise<string | undefined> {
  if (context.uncategorizedMirageCategoryId) return context.uncategorizedMirageCategoryId;

  const remembered = context.snapshot.catalog.mirageUncategorizedCategoryId;
  if (remembered) {
    context.uncategorizedMirageCategoryId = remembered;
    return remembered;
  }

  const client = getMirageClient();
  const name = mirageCategoryName(UNCATEGORIZED_NAME);

  let mirageCategoryId: string | undefined;
  try {
    const created = await client.createCategory({ name, restaurantId, sortPosition: 9_999 });
    mirageCategoryId = created.id;
  } catch (err) {
    if (!(err instanceof MirageError) || err.code !== MirageErrorCode.ALREADY_EXISTS) throw err;
    // Either a previous run created it and crashed before recording it, or the
    // business made one by hand. Same repair either way.
    const existing = await client.listCategories(restaurantId);
    mirageCategoryId = findByName(existing, UNCATEGORIZED_NAME)?.id;
  }

  if (!mirageCategoryId) return undefined;

  await rememberUncategorizedCategory(context.catalogId, mirageCategoryId);
  context.uncategorizedMirageCategoryId = mirageCategoryId;
  return mirageCategoryId;
}

/**
 * Persists the bucket's id on the catalog.
 *
 * `timestamps: false` for the same reason every other sync write uses it: this
 * is a projection record, not an authoring edit, and bumping `updatedAt` would
 * make the catalog look edited on every publish.
 */
async function rememberUncategorizedCategory(
  catalogId: string,
  mirageCategoryId: string
): Promise<void> {
  await Catalog.updateOne(
    { _id: new Types.ObjectId(catalogId) },
    { $set: { mirageUncategorizedCategoryId: mirageCategoryId } },
    { timestamps: false }
  ).exec();
}

/**
 * CASCADE REPAIR — the other half of the delete-item story.
 *
 * Mirage deletes a category when the item removed from it was its last one
 * (adminController.js:1658-1672). We pass `keepCategory: true` to opt out, but
 * the flag is newer than some deployments and Mirage reports what it actually
 * did in `deletedCategory`. When it says it cascaded, the local mapping now
 * points at nothing, and the next create-item under it would fail with
 * "Category not found". Clearing it makes the next run re-create the category
 * instead.
 *
 * `mirageCategoryId` is matched rather than a ReCapture category id because the
 * cascade is reported against the MIRAGE id — and the product being deleted may
 * be the only thing that still remembers which local row that was.
 */
export async function repairCascadedCategory(
  context: PublishRunContext,
  mirageCategoryId: string
): Promise<void> {
  if (context.uncategorizedMirageCategoryId === mirageCategoryId) {
    delete context.uncategorizedMirageCategoryId;
    await Catalog.updateOne(
      { _id: new Types.ObjectId(context.catalogId), mirageUncategorizedCategoryId: mirageCategoryId },
      { $unset: { mirageUncategorizedCategoryId: '' } },
      { timestamps: false }
    ).exec();
  }

  for (const [categoryId, mapped] of context.mirageCategoryIds) {
    if (mapped === mirageCategoryId) context.mirageCategoryIds.delete(categoryId);
  }

  await CatalogCategory.updateMany(
    { catalogId: new Types.ObjectId(context.catalogId), mirageCategoryId },
    {
      $unset: { mirageCategoryId: '', lastSyncedAt: '' },
      $set: { syncStatus: 'NEVER' },
    },
    { timestamps: false }
  ).exec();
}
