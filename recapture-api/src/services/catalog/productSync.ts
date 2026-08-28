// src/services/catalog/productSync.ts
//
// The PRODUCT executor: create, update and delete one item on Mirage, and the
// reconciliation that substitutes for the idempotency Mirage does not have.
//
// THE GUARANTEE THIS FILE EXISTS FOR: publishing the same product twice
// produces exactly ONE Mirage item.
//
// Nothing in Mirage helps with that. There are no idempotency keys, no upserts,
// and a replayed create answers `400 "Product already exist.Product name should
// be unique"` (adminController.js:1083-1093) — a refusal that does NOT include
// the id of the thing it refused to duplicate. So the guarantee is assembled
// from two mechanisms, and both have to hold:
//
//   • `CatalogProduct.mirageItemId` IS the idempotency record, and it is
//     written IMMEDIATELY after create-item returns, before the snapshot, before
//     the counters, before anything else that could throw. The window between
//     "Mirage has the item" and "we know its id" is the only window in which a
//     crash costs a duplicate, and it is one await wide.
//
//   • RECONCILIATION closes even that window. A create that comes back
//     "already exist" means the item is on Mirage and we do not know its id;
//     the repair is to list the category's items, match the exact name, adopt
//     the id, and continue as an UPDATE. Retrying could never help — the second
//     attempt fails identically.
//
// ⚠ RECONCILIATION IS SCOPED TO ONE CATEGORY, and Mirage's uniqueness is
// per-RESTAURANT (`itemModel.findOne({name, restaurant})`). An item that exists
// under a DIFFERENT category therefore will not be found, and the row fails with
// PUBLISH_RECONCILE_FAILED whose message says exactly that. That is deliberate:
// Mirage has no admin "list every item for a restaurant" route (adminRouter.js
// exposes only get-all-items-for-cat), so the alternative is a fan-out read over
// every category on every duplicate — and adopting an item found under a tab the
// user did not choose is a worse failure than reporting one.
import { Types } from 'mongoose';

import { CatalogProduct } from '@/models/CatalogProduct';
import type { ProductPublishedSnapshot } from '@/models/types/catalog.types';
import { getMirageClient, MirageError, MirageErrorCode } from '@/services/mirage';
import type { CreateItemInput, MirageItem, UpdateItemInput } from '@/services/mirage';
import {
  getAssetUploader,
  type AssetIdentityMap,
  type AssetSlot,
  type AssetSyncResult,
} from '@/services/catalog/assetUploader';
import {
  ensureUncategorizedCategory,
  repairCascadedCategory,
} from '@/services/catalog/categorySync';
import type {
  PublishRunContext,
  PublishStepExecutor,
  PublishStepResult,
} from '@/services/catalog/publishExecutors';
import type { ProductDiffField, PublishStep } from '@/services/catalog/publishPlanner';
import {
  markProductSynced,
  markProductUnpublished,
  type RowFailure,
} from '@/services/catalog/publishRunState';
import type { CatalogSnapshotProduct } from '@/services/catalog/publishSnapshot';
import {
  CatalogSyncErrorCode,
  mapMirageFailure,
  syncFailure,
} from '@/services/catalog/publishSyncErrors';
import { toCatalogSlug } from '@/utils/catalogNames';

/** `CatalogProduct.name`'s own bound — slugging must not shorten past it. */
const PRODUCT_NAME_SLUG_MAX = 120;

/** The stored form of a product name, on either side of the boundary. */
const mirageProductName = (name: string): string =>
  toCatalogSlug(name, { maxLength: PRODUCT_NAME_SLUG_MAX });

const failed = (failure: RowFailure): PublishStepResult => ({
  outcome: 'FAILED',
  code: failure.code,
  message: failure.message,
});

/** Which Mirage file slot each diffed asset field feeds. */
const SLOT_FOR_FIELD: Partial<Record<ProductDiffField, AssetSlot>> = {
  glbUrl: 'object',
  usdzUrl: 'objectIos',
  thumbnailUrl: 'image',
  imageKey: 'image',
};

/**
 * Which asset slots this product HAS anything to put in.
 *
 * A 3D product's Mirage `image` is its generated thumbnail, not a photo — a card
 * with no picture is what a customer sees while the model streams, so the
 * thumbnail is the image slot for that product type and `imageKey` is the image
 * slot for the other. They are mutually exclusive by construction; a THREE_D
 * product does not carry an `imageKey` and an IMAGE_ONLY one carries no model.
 */
function availableSlots(product: CatalogSnapshotProduct): AssetSlot[] {
  const slots: AssetSlot[] = [];
  if (product.glbUrl) slots.push('object');
  if (product.usdzUrl) slots.push('objectIos');
  if (product.thumbnailUrl || product.imageKey) slots.push('image');
  return slots;
}

/**
 * Which slots an UPDATE has to re-push.
 *
 * Derived from the planner's `changedFields` — this is the mechanism behind
 * "editing a price does not re-upload a 40 MB model". An UPDATE with no
 * `changedFields` (reason NO_SNAPSHOT, PREVIOUS_ATTEMPT_FAILED, CATEGORY_REFILED)
 * cannot prove what Mirage holds, so it re-pushes everything the product has.
 */
function slotsForUpdate(step: PublishStep, product: CatalogSnapshotProduct): AssetSlot[] {
  if (!step.changedFields) return availableSlots(product);
  const wanted = new Set<AssetSlot>();
  for (const field of step.changedFields) {
    const slot = SLOT_FOR_FIELD[field];
    if (slot) wanted.add(slot);
  }
  return [...wanted].filter((slot) => availableSlots(product).includes(slot));
}

/**
 * The Mirage category this product belongs under, minting the Uncategorized
 * bucket if that is what it needs.
 *
 * Reads `context.mirageCategoryIds` — the RUN's view — not the frozen
 * snapshot's, because the category may have been created by a step three
 * positions earlier in this very plan.
 */
async function resolveCategory(
  product: CatalogSnapshotProduct,
  context: PublishRunContext,
  restaurantId: string
): Promise<string | undefined> {
  if (!product.categoryId) return ensureUncategorizedCategory(context, restaurantId);
  return (
    context.mirageCategoryIds.get(product.categoryId) ??
    context.snapshot.categories.find((c) => c.id === product.categoryId)?.mirageCategoryId
  );
}

/**
 * ⚠ ONLY OUR CloudFront URLs may ever reach Mirage.
 *
 * A Meshy result URL is a time-limited link to a third party's bucket; stored on
 * a public page it becomes a product that works for an afternoon and then
 * 403s forever. The worker already re-hosts every Meshy artifact
 * (AGENTS.md §3D models), so one appearing here means that re-host was skipped
 * — which is a bug worth failing the row over rather than publishing.
 */
function hasForeignAssetUrl(product: CatalogSnapshotProduct): boolean {
  const foreign = (url: string | undefined): boolean =>
    Boolean(url) && /(^|\.)meshy\.ai/i.test(new URL(url as string).hostname);
  try {
    return foreign(product.glbUrl) || foreign(product.usdzUrl) || foreign(product.thumbnailUrl);
  } catch {
    // An unparseable URL is not a Meshy URL; the asset preflight (B3) is what
    // rejects it, with a message about the asset rather than about Meshy.
    return false;
  }
}

/** The record written to `publishedSnapshot` after a successful push. */
function snapshotOf(
  product: CatalogSnapshotProduct,
  mirageCategoryId: string,
  identities: AssetIdentityMap,
  previous: AssetIdentityMap | undefined
): ProductPublishedSnapshot {
  return {
    name: product.name,
    description: product.description,
    price: product.price,
    type: product.type,
    categoryId: product.categoryId,
    mirageCategoryId,
    position: product.position,
    glbUrl: product.glbUrl,
    usdzUrl: product.usdzUrl,
    thumbnailUrl: product.thumbnailUrl,
    imageKey: product.imageKey,
    // Merged, not replaced: an UPDATE that re-pushed only the image must not
    // erase the model's recorded identity, or the next run would treat the GLB
    // as never-pushed and re-upload it.
    assetIdentities: { ...(previous ?? {}), ...identities },
  };
}

/** Runs the asset seam and reports a preflight block as a row failure. */
async function loadAssets(
  product: CatalogSnapshotProduct,
  slots: readonly AssetSlot[],
  context: PublishRunContext
): Promise<AssetSyncResult> {
  return getAssetUploader()({ product, slots, context });
}

/**
 * URL transfer mode only: did Mirage actually FETCH what we pointed it at?
 *
 * Mirage re-hosts every asset and serves it from its own CDN, so a stored URL
 * that still points at OUR CloudFront means it ignored the URL fields and
 * stored nothing — which is precisely what the deployed handlers do today
 * (create-item computes `image`/`model` from `req.files` alone,
 * adminController.js:1163-1177). Reporting success there would leave a product
 * live with no picture and no model and nothing in the system that knows.
 *
 * Byte mode cannot hit this: the parts are the payload, so a 2xx means they
 * landed.
 */
function assetsNotIngested(
  assets: AssetSyncResult & { outcome: 'READY' },
  item: MirageItem
): RowFailure | undefined {
  if (!assets.urls) return undefined;

  // The URLs we asked Mirage to go and fetch. If any of them is what Mirage
  // stored, it stored the LINK rather than a copy.
  const sent = new Set(Object.values(assets.urls).filter((url): url is string => Boolean(url)));
  const stored = [item.image, item.modelSrc, item.modelIosSrc];

  return stored.some((url) => url !== undefined && sent.has(url))
    ? syncFailure(CatalogSyncErrorCode.ASSET_NOT_INGESTED)
    : undefined;
}

// ── CREATE ──────────────────────────────────────────────────────────────────

async function createProduct(
  step: PublishStep,
  product: CatalogSnapshotProduct,
  context: PublishRunContext,
  restaurantId: string,
  mirageCategoryId: string
): Promise<PublishStepResult> {
  const assets = await loadAssets(product, availableSlots(product), context);
  if (assets.outcome === 'BLOCKED') return failed(assets.failure);

  const input: CreateItemInput = {
    name: product.name,
    categoryId: mirageCategoryId,
    restaurantId,
    ...(product.price !== undefined ? { price: product.price } : {}),
    ...(product.description !== undefined ? { description: product.description } : {}),
    sortPosition: product.position,
    ...assets.files,
    ...(assets.urls ? { assetUrls: assets.urls } : {}),
  };

  const client = getMirageClient();
  let item: MirageItem;
  try {
    item = await client.createItem(input);
  } catch (err) {
    if (err instanceof MirageError && err.code === MirageErrorCode.ALREADY_EXISTS) {
      return reconcileDuplicate(step, product, context, mirageCategoryId, assets);
    }
    throw err;
  }

  // THE WRITE THAT MAKES A CRASH FREE. Nothing goes between the line above and
  // this one — not a log, not a counter, not an analytics call.
  await persistMirageItemId(product.id, item.id);

  // Only AFTER the id is safe: a product whose assets did not transfer is a
  // row-level failure, but the item exists and losing its id would duplicate it.
  const notIngested = assetsNotIngested(assets, item);
  if (notIngested) return failed(notIngested);

  await markProductSynced(
    product.id,
    snapshotOf(product, mirageCategoryId, assets.identities, product.publishedSnapshot?.assetIdentities)
  );
  return { outcome: 'SUCCEEDED' };
}

/**
 * Adopts an item Mirage already holds under this category, then applies our
 * values to it.
 *
 * This is the crash-replay repair and the "someone made it in the admin panel"
 * repair, and they are the same repair. Once the id is adopted the step becomes
 * an UPDATE — so the item ends up carrying OUR name, price, description and
 * assets, not whatever was there before.
 */
async function reconcileDuplicate(
  step: PublishStep,
  product: CatalogSnapshotProduct,
  context: PublishRunContext,
  mirageCategoryId: string,
  assets: AssetSyncResult & { outcome: 'READY' }
): Promise<PublishStepResult> {
  const client = getMirageClient();
  const existing = await client.listItemsForCategory(mirageCategoryId);
  // Compared through the slug on BOTH sides, not by raw equality: Mirage slugs
  // every name it stores, and a product row written before ReCapture did the
  // same (or seeded straight into the collection) still carries the spaced form
  // — which would never equal Mirage's echo, turning a perfectly reconcilable
  // orphan into a RECONCILE_FAILED the user has no way to act on.
  const wanted = mirageProductName(product.name);
  const match = existing.find((item) => mirageProductName(item.name) === wanted);

  // ⚠ IS IT OURS, OR A SIBLING'S? Mirage's uniqueness is per-restaurant, so a
  // catalog holding two products called "Chair" produces this same refusal — and
  // adopting there would point TWO ReCapture rows at ONE Mirage item, so
  // deleting one would silently take the other off the public page.
  //
  // The test is ownership: an item already claimed by another row of this
  // catalog is not an orphan of our own crashed create, it is the sibling's.
  // That row FAILS with a rename instruction, which is also what B4's
  // pre-publish gate refuses before a run ever starts.
  if (match) {
    const claimedBy = await CatalogProduct.findOne({
      mirageItemId: match.id,
      catalogId: new Types.ObjectId(context.catalogId),
      _id: { $ne: new Types.ObjectId(product.id) },
    })
      .select({ _id: 1 })
      .lean()
      .exec();

    if (claimedBy) return failed(syncFailure(CatalogSyncErrorCode.DUPLICATE_NAME));
  }

  if (!match) {
    // Mirage says the name is taken but this category does not hold it — it is
    // under another tab (uniqueness is per-restaurant), or it was created
    // between the create and this read. Either way, adopting anything here would
    // be a guess about which item the user meant.
    // Server-side only, once, with the row id — never stored, never returned.
    console.warn(
      `[catalog] publish ${context.runId}: duplicate name not reconcilable for product ${product.id}`
    );
    return failed(syncFailure(CatalogSyncErrorCode.RECONCILE_FAILED));
  }

  await persistMirageItemId(product.id, match.id);

  const applied = await applyUpdate(product, match.id, mirageCategoryId, assets, {
    // Nothing is known about what the adopted item holds, so every field goes.
    fullRewrite: true,
  });
  if (applied.outcome !== 'SUCCEEDED') return applied;

  console.info(
    `[catalog] publish ${context.runId}: adopted existing Mirage item for product ${product.id} (${step.action})`
  );
  return { outcome: 'SUCCEEDED' };
}

/**
 * The single write that turns a Mirage create into something a replay can see.
 *
 * `timestamps: false`, like every other sync write: this is a mapping, not an
 * authoring edit, and bumping `updatedAt` would make the row read as edited on
 * every publish.
 */
async function persistMirageItemId(productId: string, mirageItemId: string): Promise<void> {
  await CatalogProduct.updateOne(
    { _id: new Types.ObjectId(productId) },
    { $set: { mirageItemId } },
    { timestamps: false }
  ).exec();
}

// ── UPDATE ──────────────────────────────────────────────────────────────────

/**
 * Applies our values to an existing Mirage item.
 *
 * ⚠ `name` is ALWAYS sent, changed or not. Mirage builds the S3 key for any
 * uploaded file as `{slug}/imgs/{Date.now()}-{name}.{ext}` from the REQUEST's
 * name (adminController.js:1421-1424), so an upload without one stores an object
 * literally called `…-undefined.jpg`.
 *
 * ⚠ A CATEGORY MOVE IS AN UPDATE NOW. update-item repoints both back-references
 * (adminController.js:1452-1481), so the Mirage item id — and with it the whole
 * analytics history hanging off `props.productId` — survives a re-filing. The
 * old delete-and-recreate would have thrown that away. Mirage's response is
 * checked: if it comes back still filed under the old category, the row FAILS
 * with CATEGORY_MOVE_REJECTED rather than reporting a move that did not happen.
 */
async function applyUpdate(
  product: CatalogSnapshotProduct,
  mirageItemId: string,
  mirageCategoryId: string,
  assets: AssetSyncResult & { outcome: 'READY' },
  options: { fullRewrite: boolean; changedFields?: readonly ProductDiffField[] }
): Promise<PublishStepResult> {
  const changed = (field: ProductDiffField): boolean =>
    options.fullRewrite || !options.changedFields || options.changedFields.includes(field);

  const input: UpdateItemInput = {
    name: product.name,
    ...(changed('price') && product.price !== undefined ? { price: product.price } : {}),
    ...(changed('description') && product.description !== undefined
      ? { description: product.description }
      : {}),
    ...(product.mirageCategoryIdAtSync !== mirageCategoryId || options.fullRewrite
      ? { categoryId: mirageCategoryId }
      : {}),
    ...(changed('position') ? { sortPosition: product.position } : {}),
    ...assets.files,
    ...(assets.urls ? { assetUrls: assets.urls } : {}),
  };

  const updated = await getMirageClient().updateItem(mirageItemId, input);

  if (input.categoryId && updated.categoryId && updated.categoryId !== mirageCategoryId) {
    return failed(syncFailure(CatalogSyncErrorCode.CATEGORY_MOVE_REJECTED));
  }

  const notIngested = assetsNotIngested(assets, updated);
  if (notIngested) return failed(notIngested);

  await markProductSynced(
    product.id,
    snapshotOf(product, mirageCategoryId, assets.identities, product.publishedSnapshot?.assetIdentities)
  );
  return { outcome: 'SUCCEEDED' };
}

async function updateProduct(
  step: PublishStep,
  product: CatalogSnapshotProduct,
  context: PublishRunContext,
  restaurantId: string,
  mirageCategoryId: string,
  mirageItemId: string
): Promise<PublishStepResult> {
  const assets = await loadAssets(product, slotsForUpdate(step, product), context);
  if (assets.outcome === 'BLOCKED') return failed(assets.failure);

  try {
    return await applyUpdate(product, mirageItemId, mirageCategoryId, assets, {
      fullRewrite: false,
      ...(step.changedFields ? { changedFields: step.changedFields } : {}),
    });
  } catch (err) {
    // The item is gone on Mirage's side — deleted from its admin panel, or
    // swept with its category. Re-create it, which also mints a fresh id.
    if (err instanceof MirageError && err.code === MirageErrorCode.NOT_FOUND) {
      await CatalogProduct.updateOne(
        { _id: new Types.ObjectId(product.id) },
        { $unset: { mirageItemId: '' } },
        { timestamps: false }
      ).exec();
      return createProduct(step, product, context, restaurantId, mirageCategoryId);
    }
    if (err instanceof MirageError && err.code === MirageErrorCode.ALREADY_EXISTS) {
      return failed(syncFailure(CatalogSyncErrorCode.DUPLICATE_NAME));
    }
    throw err;
  }
}

// ── DELETE ──────────────────────────────────────────────────────────────────

/**
 * Takes the item off the public page.
 *
 * "Already gone" is a SUCCESS (the adapter resolves Mirage's 404 to
 * `existed: false`): a replayed run has to converge, and the state the user
 * asked for — this product is not on the public page — is exactly the state that
 * holds.
 *
 * `keepCategory: true` opts out of Mirage's last-item cascade, because a
 * category disappearing as a side effect of archiving one product is
 * destructive and re-creating it costs a round trip and a new id. Deployments
 * that predate the flag cascade anyway and say so in `deletedCategory`, which is
 * why the repair below still runs.
 */
async function deleteProduct(
  product: CatalogSnapshotProduct,
  context: PublishRunContext,
  mirageItemId: string
): Promise<PublishStepResult> {
  const result = await getMirageClient().deleteItem(mirageItemId, { keepCategory: true });

  await markProductUnpublished(product.id);

  if (result.deletedCategory) {
    const orphaned = product.mirageCategoryIdAtSync;
    if (orphaned) await repairCascadedCategory(context, orphaned);
  }

  return { outcome: 'SUCCEEDED' };
}

// ── The executor ────────────────────────────────────────────────────────────

export const productExecutor: PublishStepExecutor = async (step, context) => {
  const product = context.snapshot.products.find((p) => p.id === step.targetId);
  if (!step.targetId || !product) return { outcome: 'SKIPPED' };

  const restaurantId = context.mirageRestaurantId;
  if (!restaurantId) return failed(syncFailure(CatalogSyncErrorCode.RESTAURANT_UNRESOLVED));

  try {
    if (step.action === 'DELETE') {
      if (!product.mirageItemId) return { outcome: 'SKIPPED' };
      return await deleteProduct(product, context, product.mirageItemId);
    }

    if (hasForeignAssetUrl(product)) {
      console.error(
        `[catalog] publish ${context.runId}: refused product ${product.id} — third-party asset URL`
      );
      return failed(
        syncFailure(
          CatalogSyncErrorCode.REJECTED,
          "This product's 3D files are not hosted by us yet. Regenerate the model, then publish again."
        )
      );
    }

    const mirageCategoryId = await resolveCategory(product, context, restaurantId);
    if (!mirageCategoryId) return failed(syncFailure(CatalogSyncErrorCode.CATEGORY_UNRESOLVED));

    return product.mirageItemId
      ? await updateProduct(
          step,
          product,
          context,
          restaurantId,
          mirageCategoryId,
          product.mirageItemId
        )
      : await createProduct(step, product, context, restaurantId, mirageCategoryId);
  } catch (err) {
    if (!(err instanceof MirageError) || err.isRetryable) throw err;
    const operation =
      step.action === 'DELETE'
        ? 'DELETE_ITEM'
        : product.mirageItemId
          ? 'UPDATE_ITEM'
          : 'CREATE_ITEM';
    const failure = mapMirageFailure(err, operation);
    return failed(failure);
  }
};
