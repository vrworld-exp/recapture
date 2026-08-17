// src/services/catalogService.ts
//
// The catalog root: one per user, created on demand, and the owner of the two
// revision counters that drive the whole draft/published split.
//
// Every authoring write in the catalog feature — here, in
// catalogCategoriesService and in catalogProductsService — MUST go through
// {@link bumpDraftRevision}. That single `$inc` is the entire "you have
// unpublished changes" signal (§7.10); there is no per-field dirty tracking and
// nothing recomputes it at read time, so a write that forgets to bump leaves a
// change permanently invisible to the publish screen.
import { Types } from 'mongoose';
import { Catalog, type ICatalog } from '@/models/Catalog';
import { CatalogProduct } from '@/models/CatalogProduct';
import { CatalogCategory } from '@/models/CatalogCategory';
import type { CatalogContact, CatalogStatus } from '@/models/types/catalog.types';
import type { CreateCatalogInput, UpdateCatalogInput } from '@/validation/catalogSchemas';

/** Headline counts for the catalog screen. */
export interface CatalogCountsDto {
  products: number;
  archivedProducts: number;
  categories: number;
}

/**
 * The ONE catalog DTO. Built field by field, never by spreading the document —
 * a spread is how an internal field (`activePublishRunId`, `deletedAt`, the
 * mirage mapping fields) reaches a client the next time the schema grows.
 */
export interface CatalogDto {
  id: string;
  name: string;
  businessName: string | null;
  contact: CatalogContact | null;
  status: CatalogStatus;
  /**
   * The frozen public URL, or null before first publish. Read back verbatim —
   * NEVER recomputed, because every printed QR encodes it (feature 32).
   */
  publicUrl: string | null;
  /** True once a publish run has provisioned the Mirage restaurant. */
  isProvisioned: boolean;
  /**
   * Feature 38. Derived from the counters, not stored: `publishedRevision`
   * starts at -1 so a brand-new catalog (draftRevision 0) already reads true.
   */
  hasUnpublishedChanges: boolean;
  lastPublishedAt: string | null;
  /** True while a publish run holds the catalog — the client disables Publish. */
  isPublishing: boolean;
  counts: CatalogCountsDto;
  updatedAt: string;
  createdAt: string;
}

/**
 * Loads the caller's catalog document. Scoped to the owner AND `deletedAt: null`
 * so missing, not-owned and soft-deleted are indistinguishable (→ null → an
 * identical 404 at the route). Exported because every category/product service
 * call starts by resolving the caller's catalog this way.
 */
export async function findOwnedCatalog(userId: string): Promise<ICatalog | null> {
  return Catalog.findOne({
    userId: new Types.ObjectId(userId),
    deletedAt: null,
  }).exec();
}

/**
 * Bumps the draft revision. Called by EVERY authoring write across the catalog
 * feature — see the file header for why that is not optional.
 *
 * A bare `$inc`, deliberately: it is atomic on its own, needs no read, and two
 * concurrent edits both counting is correct (two changes really are pending).
 * `updatedAt` moves with it via `timestamps`.
 */
export async function bumpDraftRevision(catalogId: Types.ObjectId): Promise<void> {
  await Catalog.updateOne({ _id: catalogId }, { $inc: { draftRevision: 1 } }).exec();
}

/** Live counts for one catalog. Three counts, one round trip. */
async function countsFor(catalogId: Types.ObjectId): Promise<CatalogCountsDto> {
  const [products, archivedProducts, categories] = await Promise.all([
    CatalogProduct.countDocuments({ catalogId, deletedAt: null, archivedAt: null }).exec(),
    CatalogProduct.countDocuments({
      catalogId,
      deletedAt: null,
      archivedAt: { $ne: null },
    }).exec(),
    CatalogCategory.countDocuments({ catalogId, deletedAt: null }).exec(),
  ]);

  return { products, archivedProducts, categories };
}

/** The ONE catalog DTO mapper — every catalog response serializes through here. */
export function toCatalogDto(c: ICatalog, counts: CatalogCountsDto): CatalogDto {
  return {
    id: c.id as string,
    name: c.name,
    businessName: c.businessName ?? null,
    contact: c.contact ?? null,
    status: c.status,
    publicUrl: c.publicUrl ?? null,
    isProvisioned: Boolean(c.mirageRestaurantId),
    hasUnpublishedChanges: c.draftRevision > c.publishedRevision,
    lastPublishedAt: c.lastPublishedAt ? c.lastPublishedAt.toISOString() : null,
    isPublishing: Boolean(c.activePublishRunId),
    counts,
    updatedAt: c.updatedAt.toISOString(),
    createdAt: c.createdAt.toISOString(),
  };
}

/** Loads the caller's catalog as a DTO, or null when they have none yet. */
export async function getCatalog(userId: string): Promise<CatalogDto | null> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return null;

  return toCatalogDto(catalog, await countsFor(catalog._id as Types.ObjectId));
}

/**
 * Outcome of a create. `ALREADY_EXISTS` carries the existing catalog rather than
 * an error: "one catalog per user" means a second create is a replay, and the
 * client that retried a timed-out request must get the winner back, not a 409 it
 * has to special-case.
 */
export type CreateCatalogResult =
  | { outcome: 'CREATED'; catalog: CatalogDto }
  | { outcome: 'ALREADY_EXISTS'; catalog: CatalogDto };

/**
 * Creates the caller's catalog.
 *
 * The unique index on `userId` IS the one-per-user rule — this does not
 * read-then-write to enforce it, because two concurrent creates would both pass
 * that check. The loser's E11000 is caught and resolved to a replay of the
 * winner, the same shape as every other idempotent create in this codebase.
 *
 * NOTE the index is on `userId` alone, so a SOFT-DELETED catalog still occupies
 * the slot. That is deliberate (see Catalog.ts): the user restores it rather
 * than silently getting a second one with a different public URL.
 */
export async function createCatalog(
  userId: string,
  input: CreateCatalogInput
): Promise<CreateCatalogResult> {
  const ownerId = new Types.ObjectId(userId);

  try {
    const created = await Catalog.create({
      userId: ownerId,
      name: input.name,
      ...(input.businessName ? { businessName: input.businessName } : {}),
      ...(input.contact ? { contact: input.contact } : {}),
      // status DRAFT, draftRevision 0, publishedRevision -1 all via schema
      // defaults — a fresh catalog therefore already reads as "not yet live".
    });

    return {
      outcome: 'CREATED',
      catalog: toCatalogDto(created, { products: 0, archivedProducts: 0, categories: 0 }),
    };
  } catch (err) {
    if (!isDuplicateKeyError(err)) throw err;

    // Lost the race (or a plain retry): return the winner.
    const existing = await Catalog.findOne({ userId: ownerId }).exec();
    if (!existing) throw err; // the unique index fired but no row — genuinely broken

    return {
      outcome: 'ALREADY_EXISTS',
      catalog: toCatalogDto(existing, await countsFor(existing._id as Types.ObjectId)),
    };
  }
}

export type UpdateCatalogResult =
  | { outcome: 'NOT_FOUND' }
  | { outcome: 'UPDATED'; catalog: CatalogDto };

/**
 * Updates catalog metadata (features 2, 58-60). Ownership is token-resolved and
 * re-scoped on the write, so a soft-delete landing between the read and the
 * write wins instead of being clobbered.
 *
 * `contact` REPLACES the whole block when present — see the schema for why a
 * deep merge is the wrong shape here.
 */
export async function updateCatalog(
  userId: string,
  input: UpdateCatalogInput
): Promise<UpdateCatalogResult> {
  const ownerId = new Types.ObjectId(userId);

  const set: Record<string, unknown> = {};
  if (input.name !== undefined) set.name = input.name;
  if (input.businessName !== undefined) set.businessName = input.businessName;
  if (input.contact !== undefined) set.contact = input.contact;

  const updated = await Catalog.findOneAndUpdate(
    { userId: ownerId, deletedAt: null },
    // The draft bump rides along in the SAME update rather than going through
    // bumpDraftRevision: this write already targets the catalog document, and
    // folding it in keeps the edit and its revision atomic.
    { $set: set, $inc: { draftRevision: 1 } },
    { new: true, runValidators: true }
  ).exec();

  if (!updated) return { outcome: 'NOT_FOUND' };

  return {
    outcome: 'UPDATED',
    catalog: toCatalogDto(updated, await countsFor(updated._id as Types.ObjectId)),
  };
}

/**
 * Mongo duplicate-key (E11000) detection without an `any` cast — ESLint has
 * `no-explicit-any: error`, and a bare `catch (err: any)` would not survive CI.
 */
export function isDuplicateKeyError(err: unknown): boolean {
  return (
    typeof err === 'object' &&
    err !== null &&
    'code' in err &&
    (err as { code?: unknown }).code === 11000
  );
}
