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
import type {
  BulkProductsInput,
  CreateProductInput,
  ListProductsQuery,
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
    thumbnailUrl: p.assets?.thumbnailUrl ?? null,
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

  const updated = await CatalogProduct.findOneAndUpdate(
    { _id: id, catalogId, deletedAt: null },
    { $set: set },
    { new: true, runValidators: true }
  ).exec();

  if (!updated) return { outcome: 'NOT_FOUND' };

  await bumpDraftRevision(catalogId);

  return { outcome: 'UPDATED', product: toProductDto(updated) };
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
