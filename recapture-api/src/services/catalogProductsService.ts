// src/services/catalogProductsService.ts
//
// Products inside one catalog (features 6-21, 27-30, 43-46).
//
// Three rules hold throughout this file:
//   • Ownership is ALWAYS token-resolved. Every query is scoped to the caller's
//     catalog, so a foreign id is an ordinary NOT_FOUND — never a 403, which
//     would confirm the row exists (the enumeration-safe rule).
//   • Every authoring write bumps the catalog's draftRevision. That counter is
//     the entire "unpublished changes" signal.
//   • Nothing here talks to Mirage. Products are drafts until the publish worker
//     projects them; the `mirage*` and `sync*` fields are worker-owned and this
//     service never writes them.
import { randomUUID } from 'crypto';
import { Types, type FilterQuery } from 'mongoose';
import { CatalogProduct, type ICatalogProduct } from '@/models/CatalogProduct';
import { CatalogCategory } from '@/models/CatalogCategory';
import { Project } from '@/models/Project';
import { ProjectModel } from '@/models/ProjectModel';
import type {
  ProductAssets,
  ProductAvailability,
  ProductType,
  SyncStatus,
} from '@/models/types/catalog.types';
import { encodePositionCursor, type PositionCursor } from '@/utils/cursor';
import { bumpDraftRevision, findOwnedCatalog } from '@/services/catalogService';
import { BUCKET_ARTIFACTS, CLOUDFRONT_BASE } from '@/config/s3';
import { env } from '@/config/env';
import { presignObjectPutUrl, putObjectBytes } from '@/services/s3ObjectStore';
import { checkCatalogImageKey, sweepSupersededImages } from '@/services/catalogImages';
import {
  buildProductImageKey,
  productImageExtensionFor,
  type ProductImageContentType,
} from '@/utils/productImageKeys';
import type {
  BulkProductsInput,
  CreateProductInput,
  DuplicateProductInput,
  ListProductsQuery,
  ProductImageUploadUrlInput,
  UpdateProductInput,
} from '@/validation/catalogSchemas';

/**
 * Owner-facing product shape. Built field by field — never a spread of the
 * document. `mirageItemId`, `mirageCategoryIdAtSync` and `publishedSnapshot`
 * are internal projection bookkeeping and must not reach a client.
 */
export interface ProductDto {
  id: string;
  type: ProductType;
  name: string;
  description: string | null;
  price: number | null;
  currency: string;
  categoryId: string | null;
  tags: string[];
  availability: ProductAvailability;
  featured: boolean;
  position: number;
  /** OUR CloudFront URLs, frozen at create time. Null for an image-only row. */
  glbUrl: string | null;
  usdzUrl: string | null;
  thumbnailUrl: string | null;
  syncStatus: SyncStatus;
  /** OUR message for the last failure, never Mirage's prose. */
  syncError: string | null;
  isArchived: boolean;
  updatedAt: string;
  createdAt: string;
}

/**
 * The public CDN URL for a stored product-image key, or null when there is none.
 *
 * Never `${CLOUDFRONT_BASE}/undefined` — an absent key is an absent image, and a
 * broken URL on a customer-facing card is worse than no card image at all.
 */
function productImageUrl(imageKey: string | undefined): string | null {
  return imageKey ? `${CLOUDFRONT_BASE}/${imageKey}` : null;
}

/** The ONE product DTO mapper — every product response serializes through here. */
export function toProductDto(p: ICatalogProduct): ProductDto {
  return {
    id: p.id as string,
    type: p.type,
    name: p.name,
    description: p.description ?? null,
    price: p.price ?? null,
    currency: p.currency,
    categoryId: p.categoryId ? p.categoryId.toHexString() : null,
    tags: p.tags ?? [],
    availability: p.availability,
    featured: p.featured,
    position: p.position,
    glbUrl: p.assets?.glbUrl ?? null,
    usdzUrl: p.assets?.usdzUrl ?? null,
    // The card image: a 3D product's is the model's generated preview, an
    // image-only product's is DERIVED from its stored key. Derived rather than
    // stored so the key stays the single truth — a stored URL would be a second
    // copy to keep in step every time the image is replaced.
    thumbnailUrl: p.assets?.thumbnailUrl ?? productImageUrl(p.assets?.imageKey),
    syncStatus: p.syncStatus,
    syncError: p.syncError?.message ?? null,
    isArchived: Boolean(p.archivedAt),
    updatedAt: p.updatedAt.toISOString(),
    createdAt: p.createdAt.toISOString(),
  };
}

// ── List ────────────────────────────────────────────────────────────────────

export type ListProductsResult =
  | { outcome: 'NO_CATALOG' }
  | { outcome: 'OK'; items: ProductDto[]; nextCursor: string | null };

/**
 * Lists the caller's products in display order (features 27-29).
 *
 * Ordered by `(position ASC, _id ASC)` to match the
 * `{ catalogId, position, _id }` index, with `_id` in the key so equal
 * positions still page deterministically — without that tie-break, two products
 * sharing a position could appear on both pages or on neither.
 *
 * Fetches `limit + 1` rows to detect a next page without a second count query.
 */
export async function listProducts(
  userId: string,
  query: ListProductsQuery,
  cursor?: PositionCursor
): Promise<ListProductsResult> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NO_CATALOG' };

  const filter: FilterQuery<ICatalogProduct> = {
    catalogId: catalog._id as Types.ObjectId,
    deletedAt: null,
  };

  // Archived rows are hidden unless explicitly asked for (feature 19): they are
  // still real products, just not part of the working catalog.
  if (!query.includeArchived) filter.archivedAt = null;

  // `none` is the Uncategorized bucket — a null categoryId, which a query string
  // cannot express directly.
  if (query.categoryId === 'none') {
    filter.categoryId = null;
  } else if (query.categoryId !== undefined) {
    filter.categoryId = new Types.ObjectId(query.categoryId);
  }

  if (query.type !== undefined) filter.type = query.type;
  if (query.availability !== undefined) filter.availability = query.availability;

  // Case-insensitive substring search on name. The user's text is escaped, so a
  // name containing regex metacharacters is matched literally instead of being
  // interpreted as a pattern.
  if (query.q !== undefined) {
    filter.name = { $regex: escapeRegex(query.q), $options: 'i' };
  }

  // Keyset predicate: everything strictly after the cursor under
  // (position ASC, _id ASC).
  if (cursor) {
    filter.$or = [
      { position: { $gt: cursor.position } },
      { position: cursor.position, _id: { $gt: new Types.ObjectId(cursor.id) } },
    ];
  }

  const rows = await CatalogProduct.find(filter)
    .sort({ position: 1, _id: 1 })
    .limit(query.limit + 1)
    .exec();

  const hasMore = rows.length > query.limit;
  const page = hasMore ? rows.slice(0, query.limit) : rows;
  const last = page[page.length - 1];

  return {
    outcome: 'OK',
    items: page.map(toProductDto),
    nextCursor:
      hasMore && last ? encodePositionCursor(last.position, last.id as string) : null,
  };
}

/** Escapes regex metacharacters so user text is matched literally. */
function escapeRegex(input: string): string {
  return input.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

export type GetProductResult =
  | { outcome: 'NO_CATALOG' }
  | { outcome: 'NOT_FOUND' }
  | { outcome: 'OK'; product: ProductDto };

export async function getProduct(
  userId: string,
  productId: string
): Promise<GetProductResult> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NO_CATALOG' };

  const product = await CatalogProduct.findOne({
    _id: new Types.ObjectId(productId),
    catalogId: catalog._id as Types.ObjectId,
    deletedAt: null,
  }).exec();

  return product
    ? { outcome: 'OK', product: toProductDto(product) }
    : { outcome: 'NOT_FOUND' };
}

// ── Create ──────────────────────────────────────────────────────────────────

export type CreateProductResult =
  | { outcome: 'NO_CATALOG' }
  | { outcome: 'CATEGORY_NOT_FOUND' }
  | { outcome: 'MODEL_NOT_FOUND' }
  | { outcome: 'MODEL_NOT_READY' }
  | { outcome: 'DUPLICATE_NAME' }
  | { outcome: 'INVALID_KEY' }
  | { outcome: 'FORBIDDEN' }
  | { outcome: 'OBJECT_NOT_FOUND' }
  | { outcome: 'TOO_LARGE' }
  | { outcome: 'CREATED'; product: ProductDto };

/**
 * Creates a product (features 6, 7, 11, 13).
 *
 * For THREE_D the source model's artifact URLs are COPIED onto the product
 * rather than resolved on read. A later regeneration or optimization of that
 * project must not silently change what an already-published product points at
 * — the product is a snapshot of the model the user picked.
 */
export async function createProduct(
  userId: string,
  input: CreateProductInput
): Promise<CreateProductResult> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NO_CATALOG' };

  const catalogId = catalog._id as Types.ObjectId;
  const ownerId = new Types.ObjectId(userId);

  // Category, when given, must be a live category of THIS catalog. Scoping the
  // lookup to the catalog is what stops a product being filed under someone
  // else's category.
  if (input.categoryId) {
    const category = await CatalogCategory.findOne({
      _id: new Types.ObjectId(input.categoryId),
      catalogId,
      deletedAt: null,
    }).exec();
    if (!category) return { outcome: 'CATEGORY_NOT_FOUND' };
  }

  let assets: ProductAssets | undefined;
  let sourceProjectId: Types.ObjectId | undefined;
  let sourceModelId: Types.ObjectId | undefined;

  if (input.type === 'THREE_D') {
    // `sourceModelId` is guaranteed present by the schema's superRefine.
    const resolved = await resolveOwnedModel(ownerId, input.sourceModelId as string);
    if (resolved.outcome !== 'OK') return resolved;

    assets = resolved.assets;
    sourceProjectId = resolved.projectId;
    sourceModelId = resolved.modelId;
  } else {
    // IMAGE_ONLY. `imageKey` is guaranteed present by the schema's superRefine,
    // and it is CLIENT-SUPPLIED — so it goes through the same containment guard
    // as a later replacement rather than being trusted because it arrived with a
    // create. The upload happened first (there was no product to scope it to),
    // which is exactly why the key carries the catalog id.
    const check = await checkCatalogImageKey(catalogId, input.imageKey as string);
    if (check.outcome !== 'OK') return check;

    assets = { imageKey: input.imageKey as string };
  }

  // Mirage enforces unique item names per restaurant, so a duplicate is caught
  // HERE — while the user is still looking at the product — instead of at
  // publish time. This is a read-then-write and therefore racy under concurrent
  // creates of the same name; the loser would surface at publish instead. A
  // unique partial index would close it, but it is a model change and existing
  // rows would have to be de-duplicated first.
  const clash = await CatalogProduct.findOne({
    catalogId,
    name: input.name,
    deletedAt: null,
  })
    .select('_id')
    .exec();
  if (clash) return { outcome: 'DUPLICATE_NAME' };

  const position = input.position ?? (await nextProductPosition(catalogId));

  const created = await CatalogProduct.create({
    catalogId,
    userId: ownerId,
    type: input.type,
    name: input.name,
    ...(input.description !== undefined ? { description: input.description } : {}),
    ...(input.price !== undefined ? { price: input.price } : {}),
    categoryId: input.categoryId ? new Types.ObjectId(input.categoryId) : null,
    ...(input.tags !== undefined ? { tags: input.tags } : {}),
    ...(input.availability !== undefined ? { availability: input.availability } : {}),
    ...(input.featured !== undefined ? { featured: input.featured } : {}),
    position,
    ...(sourceProjectId ? { sourceProjectId } : {}),
    ...(sourceModelId ? { sourceModelId } : {}),
    ...(assets ? { assets } : {}),
    // syncStatus defaults to NEVER — nothing has been projected yet.
  });

  await bumpDraftRevision(catalogId);

  return { outcome: 'CREATED', product: toProductDto(created) };
}

type ResolveModelResult =
  | { outcome: 'MODEL_NOT_FOUND' }
  | { outcome: 'MODEL_NOT_READY' }
  | {
      outcome: 'OK';
      assets: ProductAssets;
      projectId: Types.ObjectId;
      modelId: Types.ObjectId;
    };

/**
 * Resolves a ProjectModel the caller owns and is allowed to publish.
 *
 * Ownership is proven through the model's PROJECT (`Project.userId`), not by
 * trusting the model row: models carry no owner of their own. A model belonging
 * to someone else returns the same MODEL_NOT_FOUND as one that does not exist.
 *
 * Queries the two collections directly rather than going through
 * projectModelsService, which imports adminProjectsService → projectsService;
 * routing through it would pull an import cycle into the catalog feature. Same
 * reasoning as `countSucceededModelsByProject`.
 */
async function resolveOwnedModel(
  ownerId: Types.ObjectId,
  modelId: string
): Promise<ResolveModelResult> {
  const model = await ProjectModel.findById(new Types.ObjectId(modelId)).exec();
  if (!model) return { outcome: 'MODEL_NOT_FOUND' };

  const project = await Project.findOne({
    _id: model.projectId,
    userId: ownerId,
    deletedAt: null,
  })
    .select('_id')
    .exec();
  // Not owned reads exactly as not found — no existence leak.
  if (!project) return { outcome: 'MODEL_NOT_FOUND' };

  // Only a finished model can back a product. A QUEUED/PROCESSING/FAILED record
  // has no artifacts, and a product pointing at one would publish a broken page.
  if (model.status !== 'SUCCEEDED' || !model.artifacts?.cdnUrls?.glb) {
    return { outcome: 'MODEL_NOT_READY' };
  }

  return {
    outcome: 'OK',
    assets: {
      glbUrl: model.artifacts.cdnUrls.glb,
      ...(model.artifacts.cdnUrls.usdz ? { usdzUrl: model.artifacts.cdnUrls.usdz } : {}),
      ...(model.artifacts.cdnUrls.preview
        ? { thumbnailUrl: model.artifacts.cdnUrls.preview }
        : {}),
    },
    projectId: model.projectId,
    modelId: model._id as Types.ObjectId,
  };
}

/** Appends after the current last product. */
async function nextProductPosition(catalogId: Types.ObjectId): Promise<number> {
  const last = await CatalogProduct.findOne({ catalogId, deletedAt: null })
    .sort({ position: -1 })
    .select('position')
    .exec();

  return last ? last.position + 1 : 0;
}

// ── Update ──────────────────────────────────────────────────────────────────

export type UpdateProductResult =
  | { outcome: 'NO_CATALOG' }
  | { outcome: 'NOT_FOUND' }
  | { outcome: 'CATEGORY_NOT_FOUND' }
  | { outcome: 'DUPLICATE_NAME' }
  | { outcome: 'MODEL_NOT_FOUND' }
  | { outcome: 'MODEL_NOT_READY' }
  | { outcome: 'INVALID_KEY' }
  | { outcome: 'FORBIDDEN' }
  | { outcome: 'OBJECT_NOT_FOUND' }
  | { outcome: 'TOO_LARGE' }
  | { outcome: 'UPDATED'; product: ProductDto };

/**
 * Updates a product (features 14, 25). `type` is deliberately not patchable —
 * see updateProductSchema.
 *
 * `price` and `categoryId` accept an explicit null to CLEAR them (no price /
 * Uncategorized). `undefined` means "not sent" and leaves the field alone; the
 * two are kept distinct throughout, because collapsing them is how "remove the
 * price" silently becomes a no-op.
 */
export async function updateProduct(
  userId: string,
  productId: string,
  input: UpdateProductInput
): Promise<UpdateProductResult> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NO_CATALOG' };

  const catalogId = catalog._id as Types.ObjectId;
  const id = new Types.ObjectId(productId);

  const existing = await CatalogProduct.findOne({ _id: id, catalogId, deletedAt: null }).exec();
  if (!existing) return { outcome: 'NOT_FOUND' };

  if (input.categoryId) {
    const category = await CatalogCategory.findOne({
      _id: new Types.ObjectId(input.categoryId),
      catalogId,
      deletedAt: null,
    }).exec();
    if (!category) return { outcome: 'CATEGORY_NOT_FOUND' };
  }

  if (input.name !== undefined && input.name !== existing.name) {
    const clash = await CatalogProduct.findOne({
      catalogId,
      name: input.name,
      deletedAt: null,
      _id: { $ne: id },
    })
      .select('_id')
      .exec();
    if (clash) return { outcome: 'DUPLICATE_NAME' };
  }

  const set: Record<string, unknown> = {};
  if (input.name !== undefined) set.name = input.name;
  if (input.description !== undefined) set.description = input.description;
  if (input.price !== undefined) set.price = input.price; // null clears it
  if (input.categoryId !== undefined) {
    set.categoryId = input.categoryId ? new Types.ObjectId(input.categoryId) : null;
  }
  if (input.tags !== undefined) set.tags = input.tags;
  if (input.availability !== undefined) set.availability = input.availability;
  if (input.featured !== undefined) set.featured = input.featured;
  if (input.position !== undefined) set.position = input.position;

  // ── Assets: replace a model (15), replace an image (16), convert a type (17)
  //
  // The resulting type is whatever the request asks for, defaulting to the
  // current one. The schema guarantees a conversion arrives WITH its asset, so
  // by here "which asset was sent" already determines a consistent end state.
  const nextType = input.type ?? existing.type;

  if (input.sourceModelId !== undefined) {
    const resolved = await resolveOwnedModel(existing.userId, input.sourceModelId);
    if (resolved.outcome !== 'OK') return resolved;

    // The card image comes with the model — a 3D product shows its generated
    // preview, so a leftover uploaded image would compete with it.
    set.assets = resolved.assets;
    set.sourceProjectId = resolved.projectId;
    set.sourceModelId = resolved.modelId;
    set.type = 'THREE_D';
  } else if (input.imageKey !== undefined) {
    const check = await checkCatalogImageKey(catalogId, input.imageKey);
    if (check.outcome !== 'OK') return check;

    if (nextType === 'IMAGE_ONLY') {
      // Converting away from 3D: the model URLs go with it, or the product would
      // still render in a viewer it no longer has a model for.
      set.assets = { imageKey: input.imageKey };
      set.type = 'IMAGE_ONLY';
      set.sourceProjectId = null;
      set.sourceModelId = null;
    } else {
      set['assets.imageKey'] = input.imageKey;
    }
  } else if (input.type !== undefined && input.type !== existing.type) {
    // Unreachable through the route (the schema requires the asset), but a
    // direct service caller must not be able to leave a product typed for an
    // asset it does not have.
    return { outcome: 'MODEL_NOT_FOUND' };
  }

  const previousImageKey = existing.assets?.imageKey;

  const updated = await CatalogProduct.findOneAndUpdate(
    { _id: id, catalogId, deletedAt: null },
    { $set: set },
    { new: true, runValidators: true }
  ).exec();

  if (!updated) return { outcome: 'NOT_FOUND' };

  await bumpDraftRevision(catalogId);

  // The pointer has already flipped, so a sweep failure is an orphan rather than
  // a broken product. Only sweep when the image actually moved.
  const nextImageKey = updated.assets?.imageKey;
  if (previousImageKey && previousImageKey !== nextImageKey) {
    await sweepSupersededImages(nextImageKey ?? previousImageKey, previousImageKey);
  }

  return { outcome: 'UPDATED', product: toProductDto(updated) };
}

// ── Duplicate (feature 18) ──────────────────────────────────────────────────

export type DuplicateProductResult =
  | { outcome: 'NO_CATALOG' }
  | { outcome: 'NOT_FOUND' }
  | { outcome: 'DUPLICATE_NAME' }
  | { outcome: 'CREATED'; product: ProductDto };

/**
 * Duplicates a product.
 *
 * The copy carries every AUTHORING field and none of the identity, mapping or
 * sync state: mirageItemId, publishedSnapshot, syncStatus and syncError all
 * start fresh, because the copy is a different Mirage item that has never been
 * published. Copying mirageItemId would make two ReCapture products claim the
 * same Mirage item, and the next publish would have them overwrite each other.
 *
 * The image KEY is shared rather than copied: objects here are immutable (a
 * replacement writes a NEW key), so two products pointing at one object is safe,
 * and a sweep only ever runs against the key a product currently holds.
 */
export async function duplicateProduct(
  userId: string,
  productId: string,
  input: DuplicateProductInput
): Promise<DuplicateProductResult> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NO_CATALOG' };

  const catalogId = catalog._id as Types.ObjectId;
  const source = await CatalogProduct.findOne({
    _id: new Types.ObjectId(productId),
    catalogId,
    deletedAt: null,
  }).exec();
  if (!source) return { outcome: 'NOT_FOUND' };

  const name = input.name ?? (await nextCopyName(catalogId, source.name));
  if (!name) return { outcome: 'DUPLICATE_NAME' };

  const clash = await CatalogProduct.findOne({ catalogId, name, deletedAt: null })
    .select('_id')
    .exec();
  if (clash) return { outcome: 'DUPLICATE_NAME' };

  const created = await CatalogProduct.create({
    catalogId,
    userId: source.userId,
    type: source.type,
    name,
    ...(source.description !== undefined ? { description: source.description } : {}),
    ...(source.price !== undefined ? { price: source.price } : {}),
    currency: source.currency,
    categoryId: source.categoryId ?? null,
    tags: source.tags ?? [],
    availability: source.availability,
    featured: source.featured,
    position: await nextProductPosition(catalogId),
    ...(source.sourceProjectId ? { sourceProjectId: source.sourceProjectId } : {}),
    ...(source.sourceModelId ? { sourceModelId: source.sourceModelId } : {}),
    ...(source.assets ? { assets: { ...source.assets } } : {}),
    // syncStatus defaults to NEVER — deliberately NOT copied. See above.
  });

  await bumpDraftRevision(catalogId);

  return { outcome: 'CREATED', product: toProductDto(created) };
}

/**
 * The first free copy name, or null when there is no room.
 *
 * Auto-renaming is not cosmetic: Mirage keys items by name within a restaurant,
 * so two products sharing a name would collide at publish — long after the user
 * pressed Duplicate and stopped thinking about it.
 */
async function nextCopyName(
  catalogId: Types.ObjectId,
  sourceName: string
): Promise<string | null> {
  const MAX_COPIES = 50;
  // Leave room for the suffix inside the model's 120-char name bound.
  const base = sourceName.slice(0, 100);
  for (let n = 1; n <= MAX_COPIES; n++) {
    const candidate = n === 1 ? base + ' (copy)' : base + ' (copy ' + n + ')';
    const taken = await CatalogProduct.findOne({ catalogId, name: candidate, deletedAt: null })
      .select('_id')
      .exec();
    if (!taken) return candidate;
  }
  return null;
}

// ── Archive / restore / delete ──────────────────────────────────────────────

export type ProductStateChangeResult =
  | { outcome: 'NO_CATALOG' }
  | { outcome: 'NOT_FOUND' }
  | { outcome: 'OK'; product: ProductDto };

/**
 * Archives (19) or restores (20) a product.
 *
 * Archiving is what removes a published product from Mirage on the next run —
 * Mirage's own `isDeleted` is never written by any of its endpoints, so a
 * hard delete-item is the only removal primitive it has. Restoring re-creates
 * it, which mints a NEW Mirage item id; the worker re-points the mapping.
 */
export async function setProductArchived(
  userId: string,
  productId: string,
  archived: boolean
): Promise<ProductStateChangeResult> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NO_CATALOG' };

  const catalogId = catalog._id as Types.ObjectId;

  const updated = await CatalogProduct.findOneAndUpdate(
    { _id: new Types.ObjectId(productId), catalogId, deletedAt: null },
    { $set: { archivedAt: archived ? new Date() : null } },
    { new: true }
  ).exec();

  if (!updated) return { outcome: 'NOT_FOUND' };

  await bumpDraftRevision(catalogId);

  return { outcome: 'OK', product: toProductDto(updated) };
}

export type DeleteProductResult =
  | { outcome: 'NO_CATALOG' }
  | { outcome: 'NOT_FOUND' }
  | { outcome: 'DELETED'; id: string; wasAlreadyDeleted: boolean };

/**
 * Soft-deletes a product (feature 21). The lookup deliberately includes
 * already-deleted rows so a repeat delete is idempotent rather than a confusing
 * 404, and the flip is conditional on `deletedAt: null` so a concurrent double
 * delete has exactly one winner.
 *
 * The row is KEPT rather than removed because `mirageItemId` lives on it: the
 * publish worker still needs to know which Mirage item to delete.
 */
export async function deleteProduct(
  userId: string,
  productId: string
): Promise<DeleteProductResult> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NO_CATALOG' };

  const catalogId = catalog._id as Types.ObjectId;
  const id = new Types.ObjectId(productId);

  const existing = await CatalogProduct.findOne({ _id: id, catalogId }).exec();
  if (!existing) return { outcome: 'NOT_FOUND' };

  if (existing.deletedAt) {
    return { outcome: 'DELETED', id: existing.id as string, wasAlreadyDeleted: true };
  }

  const updated = await CatalogProduct.findOneAndUpdate(
    { _id: id, catalogId, deletedAt: null },
    { $set: { deletedAt: new Date() } },
    { new: true }
  ).exec();

  await bumpDraftRevision(catalogId);

  return {
    outcome: 'DELETED',
    id: existing.id as string,
    wasAlreadyDeleted: updated === null,
  };
}

// ── Reorder ─────────────────────────────────────────────────────────────────

export type ReorderProductsResult =
  | { outcome: 'NO_CATALOG' }
  | { outcome: 'ID_SET_MISMATCH' }
  | { outcome: 'REORDERED'; count: number };

/**
 * Reorders products (feature 10). Position becomes the array index, so the
 * result cannot have gaps or collisions.
 *
 * Unlike categories this accepts a SUBSET: a product list is paginated, and
 * requiring every id would make reordering impossible on a catalog larger than
 * one page. Every id must still be a live product of this catalog — the ids are
 * renumbered 0..n-1 among themselves, which is why the client should send a
 * contiguous visible block rather than an arbitrary scatter.
 */
export async function reorderProducts(
  userId: string,
  ids: string[]
): Promise<ReorderProductsResult> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NO_CATALOG' };

  const catalogId = catalog._id as Types.ObjectId;

  const owned = await CatalogProduct.find({
    _id: { $in: ids.map((id) => new Types.ObjectId(id)) },
    catalogId,
    deletedAt: null,
  })
    .select('_id')
    .exec();

  // Any id we could not account for is rejected wholesale — a partial apply
  // would leave the client's optimistic order silently wrong. One opaque
  // outcome, never naming the offending id.
  if (owned.length !== ids.length) return { outcome: 'ID_SET_MISMATCH' };

  await CatalogProduct.bulkWrite(
    ids.map((id, index) => ({
      updateOne: {
        filter: { _id: new Types.ObjectId(id), catalogId, deletedAt: null },
        update: { $set: { position: index } },
      },
    }))
  );

  await bumpDraftRevision(catalogId);

  return { outcome: 'REORDERED', count: ids.length };
}

// ── Bulk actions ────────────────────────────────────────────────────────────

export type BulkProductsResult =
  | { outcome: 'NO_CATALOG' }
  | { outcome: 'CATEGORY_NOT_FOUND' }
  | { outcome: 'ID_SET_MISMATCH' }
  | { outcome: 'OK'; affected: number };

/**
 * Applies one action to many products (feature 30).
 *
 * This is the AUTHORING half only. Mirage has no batch endpoints, so the
 * corresponding projection is still N sequential requests inside one publish
 * run — batching here does not batch there, and the publish screen says so.
 *
 * All-or-nothing on validation: if any id is not a live product of this
 * catalog, nothing is applied.
 */
export async function bulkProducts(
  userId: string,
  input: BulkProductsInput
): Promise<BulkProductsResult> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NO_CATALOG' };

  const catalogId = catalog._id as Types.ObjectId;
  const objectIds = input.ids.map((id) => new Types.ObjectId(id));

  if (input.action === 'SET_CATEGORY' && input.categoryId) {
    const category = await CatalogCategory.findOne({
      _id: new Types.ObjectId(input.categoryId),
      catalogId,
      deletedAt: null,
    }).exec();
    if (!category) return { outcome: 'CATEGORY_NOT_FOUND' };
  }

  const owned = await CatalogProduct.countDocuments({
    _id: { $in: objectIds },
    catalogId,
    deletedAt: null,
  }).exec();

  if (owned !== input.ids.length) return { outcome: 'ID_SET_MISMATCH' };

  const now = new Date();
  const update =
    input.action === 'ARCHIVE'
      ? { $set: { archivedAt: now } }
      : input.action === 'RESTORE'
        ? { $set: { archivedAt: null } }
        : input.action === 'DELETE'
          ? { $set: { deletedAt: now } }
          : {
              $set: {
                categoryId: input.categoryId
                  ? new Types.ObjectId(input.categoryId)
                  : null,
              },
            };

  const result = await CatalogProduct.updateMany(
    { _id: { $in: objectIds }, catalogId, deletedAt: null },
    update
  ).exec();

  await bumpDraftRevision(catalogId);

  return { outcome: 'OK', affected: result.modifiedCount };
}

// ── Product images (features 13, 16) ────────────────────────────────────────
//
// The same three-step shape as the avatar flow — presign → PUT to S3 → commit —
// for the same reason: image bytes never pass through this API, and the commit
// is a pointer flip that only happens once the object demonstrably exists.
//
// The one structural difference is WHERE the bytes land. An avatar goes to the
// private raw bucket behind short-lived presigned GETs because it is a
// photograph of a person; a product image goes to BUCKET_ARTIFACTS behind
// CloudFront because it is public catalog content a customer's browser loads
// directly. Opposite decision, opposite reason.

/** What a presigned upload slot hands back to the client. */
export interface ProductImageSlotDto {
  /** The key to PUT to, and then to send back at commit. */
  key: string;
  /** A WRITE bearer credential for exactly that key until `expiresAt`. */
  url: string;
  expiresAt: string;
}

export type ProductImageSlotResult =
  | { outcome: 'NO_CATALOG' }
  | { outcome: 'NOT_FOUND' }
  | { outcome: 'OK'; slot: ProductImageSlotDto };

/**
 * Mints one presigned PUT slot for a product image.
 *
 * `productId` is optional on purpose. An image-only product is created WITH its
 * committed key (feature 13), so at upload time the product does not exist yet
 * and the slot segment is a fresh uuid. When a product IS named, the slot is its
 * id — and the caller's ownership of it is checked here, so a presigned URL can
 * never be minted against another business's product.
 */
export async function createProductImageSlot(
  userId: string,
  input: ProductImageUploadUrlInput
): Promise<ProductImageSlotResult> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NO_CATALOG' };

  const catalogId = catalog._id as Types.ObjectId;

  let slotId: string;
  if (input.productId) {
    const product = await CatalogProduct.findOne({
      _id: new Types.ObjectId(input.productId),
      catalogId,
      deletedAt: null,
    })
      .select('_id')
      .exec();
    // Foreign or missing are indistinguishable — the enumeration-safe rule.
    if (!product) return { outcome: 'NOT_FOUND' };
    slotId = input.productId;
  } else {
    // A staging slot. It is only ever a grouping, never an authorization claim:
    // the commit re-derives ownership from the key's catalogId segment.
    slotId = randomUUID();
  }

  const key = buildProductImageKey(
    catalogId.toHexString(),
    slotId,
    randomUUID(),
    productImageExtensionFor(input.contentType)
  );

  // The declared content type is part of the SIGNATURE, so the uploader can only
  // ever store an object of that type at that key.
  const url = await presignObjectPutUrl(
    BUCKET_ARTIFACTS,
    key,
    env.PRODUCT_IMAGE_UPLOAD_URL_TTL_SECONDS,
    input.contentType
  );

  return {
    outcome: 'OK',
    slot: {
      key,
      url,
      expiresAt: new Date(
        Date.now() + env.PRODUCT_IMAGE_UPLOAD_URL_TTL_SECONDS * 1000
      ).toISOString(),
    },
  };
}

export type ProductImageBytesResult =
  | { outcome: 'NO_CATALOG' }
  | { outcome: 'NOT_FOUND' }
  | { outcome: 'OK'; key: string };

/**
 * Stores product-image bytes SERVER-SIDE and returns the key they landed on —
 * the one-call alternative to presign → PUT → commit.
 *
 * WHY THIS EXISTS ALONGSIDE createProductImageSlot. The presigned flow keeps
 * image bytes off this API and works from a native client, but it cannot work
 * from the BROWSER build at all: the PUT is cross-origin to the artifacts
 * bucket, which serves no CORS policy. `POST /auth/me/avatar/bytes` hit the
 * identical wall and resolved it the identical way — one path for web and
 * native beats two that diverge. A product image is a single ≤5 MiB file, so
 * proxying it costs little; this reasoning still does NOT extend to capture
 * uploads, which must stay direct-to-S3.
 *
 * The key space, the ownership boundary and the slot semantics are EXACTLY
 * those of [createProductImageSlot] — same builder, same optional `productId`
 * meaning — so an image uploaded through either route is indistinguishable
 * afterwards and `commitProductImage` accepts both without knowing which ran.
 *
 * The caller must have already sniffed `contentType` from the bytes themselves;
 * the route does that, so a mislabelled body cannot store an object whose
 * stored type lies about its content.
 */
export async function storeProductImageBytes(
  userId: string,
  input: { bytes: Buffer; contentType: ProductImageContentType; productId?: string }
): Promise<ProductImageBytesResult> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NO_CATALOG' };

  const catalogId = catalog._id as Types.ObjectId;

  let slotId: string;
  if (input.productId) {
    const product = await CatalogProduct.findOne({
      _id: new Types.ObjectId(input.productId),
      catalogId,
      deletedAt: null,
    })
      .select('_id')
      .exec();
    // Foreign or missing are indistinguishable — the enumeration-safe rule.
    if (!product) return { outcome: 'NOT_FOUND' };
    slotId = input.productId;
  } else {
    slotId = randomUUID();
  }

  const key = buildProductImageKey(
    catalogId.toHexString(),
    slotId,
    randomUUID(),
    productImageExtensionFor(input.contentType)
  );

  await putObjectBytes(BUCKET_ARTIFACTS, key, input.bytes, input.contentType);

  return { outcome: 'OK', key };
}

export type CommitProductImageResult =
  | { outcome: 'NO_CATALOG' }
  | { outcome: 'NOT_FOUND' }
  | { outcome: 'INVALID_KEY' }
  | { outcome: 'FORBIDDEN' }
  | { outcome: 'OBJECT_NOT_FOUND' }
  | { outcome: 'TOO_LARGE' }
  | { outcome: 'COMMITTED'; product: ProductDto };

/**
 * Binds an uploaded object to a product (feature 16 — replace a product image).
 *
 * ORDERING: the pointer flips FIRST, then the old objects are swept. A crash
 * between the two leaves an orphaned object in the bucket; the reverse order
 * would leave a product pointing at something that no longer exists. The avatar
 * flow makes the same trade for the same reason — an orphan costs storage, a
 * dangling pointer costs the user their picture.
 */
export async function commitProductImage(
  userId: string,
  productId: string,
  key: string
): Promise<CommitProductImageResult> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NO_CATALOG' };

  const catalogId = catalog._id as Types.ObjectId;
  const product = await CatalogProduct.findOne({
    _id: new Types.ObjectId(productId),
    catalogId,
    deletedAt: null,
  }).exec();
  if (!product) return { outcome: 'NOT_FOUND' };

  const check = await checkCatalogImageKey(catalogId, key);
  if (check.outcome !== 'OK') return check;

  const previousKey = product.assets?.imageKey;

  const updated = await CatalogProduct.findOneAndUpdate(
    { _id: product._id, catalogId, deletedAt: null },
    { $set: { 'assets.imageKey': key } },
    { new: true, runValidators: true }
  ).exec();
  if (!updated) return { outcome: 'NOT_FOUND' };

  await bumpDraftRevision(catalogId);

  // From here the commit has already succeeded; a sweep failure is an orphan,
  // never a broken product, so it must not fail the request.
  await sweepSupersededImages(key, previousKey);

  return { outcome: 'COMMITTED', product: toProductDto(updated) };
}

