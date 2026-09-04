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
import { randomUUID } from 'crypto';
import { Types } from 'mongoose';
import { Catalog, type ICatalog } from '@/models/Catalog';
import { CatalogProduct } from '@/models/CatalogProduct';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogPublishRun } from '@/models/CatalogPublishRun';
import { getMirageClient, MirageError, MirageErrorCode } from '@/services/mirage';
import { hasActiveRun } from '@/services/catalog/publishRunState';
import { BUCKET_ARTIFACTS, CLOUDFRONT_BASE } from '@/config/s3';
import { env } from '@/config/env';
import { presignObjectPutUrl, putObjectBytes } from '@/services/s3ObjectStore';
import { checkCatalogImageKey, sweepSupersededImages } from '@/services/catalogImages';
import {
  buildBrandingImageKey,
  productImageExtensionFor,
  type BrandingSlot,
  type ProductImageContentType,
} from '@/utils/productImageKeys';
import type { CatalogContact, CatalogStatus } from '@/models/types/catalog.types';
import type {
  BrandingCommitInput,
  BrandingUploadUrlInput,
  CreateCatalogInput,
  UpdateBusinessProfileInput,
  UpdateCatalogInput,
} from '@/validation/catalogSchemas';

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
 * The ONE catalog-metadata write. Both `PATCH /catalog` and
 * `PATCH /catalog/profile` go through it — they differ only in the DTO they
 * project out of the returned document, and two write paths is exactly how one
 * of them ends up forgetting the `draftRevision` bump.
 *
 * Returns the updated document, or null when the caller has no (non-deleted)
 * catalog. Ownership is re-scoped on the write itself, so a soft-delete landing
 * between a read and this write wins instead of being clobbered.
 */
async function applyCatalogPatch(
  userId: string,
  input: UpdateCatalogInput
): Promise<ICatalog | null> {
  const ownerId = new Types.ObjectId(userId);

  const set: Record<string, unknown> = {};
  if (input.name !== undefined) set.name = input.name;
  if (input.businessName !== undefined) set.businessName = input.businessName;
  if (input.contact !== undefined) set.contact = input.contact;

  return Catalog.findOneAndUpdate(
    { userId: ownerId, deletedAt: null },
    // The draft bump rides along in the SAME update rather than going through
    // bumpDraftRevision: this write already targets the catalog document, and
    // folding it in keeps the edit and its revision atomic.
    { $set: set, $inc: { draftRevision: 1 } },
    { new: true, runValidators: true }
  ).exec();
}

/**
 * Updates catalog metadata (feature 2) and returns the catalog DTO.
 *
 * `contact` REPLACES the whole block when present — see the schema for why a
 * deep merge is the wrong shape here. The write itself, and the reason it is
 * shared with the profile endpoint, live in {@link applyCatalogPatch}.
 */
export async function updateCatalog(
  userId: string,
  input: UpdateCatalogInput
): Promise<UpdateCatalogResult> {
  const updated = await applyCatalogPatch(userId, input);

  if (!updated) return { outcome: 'NOT_FOUND' };

  return {
    outcome: 'UPDATED',
    catalog: toCatalogDto(updated, await countsFor(updated._id as Types.ObjectId)),
  };
}

// ── Business profile (features 58-60) ───────────────────────────────────────
//
// The profile is a VIEW of the catalog document, not a second row. `User` stays
// out of it on purpose: the catalog is the thing that gets branded, `User` is
// deliberately near-PII-free, and `GET /auth/me` is a masked-only snapshot.

/**
 * The profile fields that actually reach the published public catalog, as dotted
 * paths into {@link BusinessProfileDto}.
 *
 * Mirage's `update-restaurant` (M3) carries name / location / phoneNo / icon /
 * description AND, since the phase-2 rework of its restaurant schema,
 * `website` and `socialLinks` (restaurantModel.js:75-105) — which the public
 * page renders in its contact sheet (mirage-fe BusinessLinks.tsx). Anything not
 * listed here is ReCapture-only and the profile screen marks it as such
 * (feature 59, T-023). This list is the ONE source of truth for that marking:
 * hardcoding it in the client would drift the moment the publish worker learns
 * to carry another field.
 *
 * Each social key is listed SEPARATELY rather than as a `contact.socials`
 * prefix, because `BusinessProfile.isPublic` matches the dotted path exactly and
 * the profile screen labels one field at a time.
 *
 * `name` → restaurant name · `contact.address` → location · `contact.phone` →
 * phoneNo · `logoUrl` → icon · `contact.website` → website ·
 * `contact.socials.*` → socialLinks.
 */
export const PUBLIC_PROFILE_FIELDS: readonly string[] = [
  'name',
  'contact.phone',
  'contact.address',
  'logoUrl',
  'contact.website',
  'contact.socials.instagram',
  'contact.socials.facebook',
  'contact.socials.youtube',
  'contact.socials.whatsapp',
];

/**
 * The business profile as the profile screen reads it. Built field by field for
 * the same reason as {@link CatalogDto} — a spread is how `mirageRestaurantId`
 * or `deletedAt` reaches a client the next time the schema grows.
 */
export interface BusinessProfileDto {
  /** The catalog this profile belongs to (feature 3). */
  id: string;
  /** The storefront title — becomes the Mirage restaurant name on publish. */
  name: string;
  businessName: string | null;
  contact: CatalogContact | null;
  /**
   * CDN URLs derived from the stored KEYS. Null until the logo/cover upload
   * flow (T-007) commits one; the model stores keys, never URLs.
   */
  logoUrl: string | null;
  coverImageUrl: string | null;
  /** See {@link PUBLIC_PROFILE_FIELDS}. */
  publicFields: readonly string[];
  updatedAt: string;
}

/** `null` for an unset key — never a `.../undefined` URL. */
function cdnUrlForKey(key: string | undefined): string | null {
  return key ? `${CLOUDFRONT_BASE}/${key}` : null;
}

/** The ONE profile DTO mapper. */
export function toBusinessProfileDto(c: ICatalog): BusinessProfileDto {
  return {
    id: c.id as string,
    name: c.name,
    businessName: c.businessName ?? null,
    contact: c.contact ?? null,
    logoUrl: cdnUrlForKey(c.logoKey),
    coverImageUrl: cdnUrlForKey(c.coverImageKey),
    publicFields: PUBLIC_PROFILE_FIELDS,
    updatedAt: c.updatedAt.toISOString(),
  };
}

/** Loads the caller's business profile, or null when they have no catalog. */
export async function getBusinessProfile(userId: string): Promise<BusinessProfileDto | null> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return null;

  return toBusinessProfileDto(catalog);
}

export type UpdateBusinessProfileResult =
  | { outcome: 'NOT_FOUND' }
  | { outcome: 'UPDATED'; profile: BusinessProfileDto };

/**
 * Updates the business profile (feature 60).
 *
 * Writes through the SAME `$set` + `$inc draftRevision` as {@link updateCatalog}
 * — editing the profile is an authoring change like any other, so it must light
 * up the "draft changes not yet live" badge (feature 38). Splitting these into
 * two write paths is exactly how one of them would end up forgetting the bump.
 */
export async function updateBusinessProfile(
  userId: string,
  input: UpdateBusinessProfileInput
): Promise<UpdateBusinessProfileResult> {
  const updated = await applyCatalogPatch(userId, input);
  if (!updated) return { outcome: 'NOT_FOUND' };

  return { outcome: 'UPDATED', profile: toBusinessProfileDto(updated) };
}

// ── Branding images (feature 2) ─────────────────────────────────────────────
//
// The logo and cover ride the SAME key space, bucket and containment rules as a
// product image (see utils/productImageKeys.ts) — they differ only in living
// under a reserved slot name instead of a product id.
//
// The cover has no Mirage counterpart at all and never reaches the public page;
// the logo becomes the restaurant `icon` at publish. The profile DTO's
// `publicFields` is what tells the client which is which.

/** What a presigned branding slot hands back to the client. */
export interface BrandingSlotDto {
  key: string;
  /** A WRITE bearer credential for exactly that key until `expiresAt`. */
  url: string;
  expiresAt: string;
}

export type BrandingSlotResult =
  | { outcome: 'NOT_FOUND' }
  | { outcome: 'OK'; slot: BrandingSlotDto };

/** Mints one presigned PUT slot for the catalog logo or cover. */
export async function createBrandingImageSlot(
  userId: string,
  input: BrandingUploadUrlInput
): Promise<BrandingSlotResult> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NOT_FOUND' };

  const key = buildBrandingImageKey(
    (catalog._id as Types.ObjectId).toHexString(),
    input.slot,
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

export type BrandingImageBytesResult =
  | { outcome: 'NOT_FOUND' }
  | { outcome: 'OK'; key: string };

/**
 * Stores branding bytes in ONE call and returns the key they landed on. Feed
 * that key straight to {@link commitBrandingImage}, exactly as if it had been
 * presigned.
 *
 * WHY THIS EXISTS ALONGSIDE {@link createBrandingImageSlot}, and it is the same
 * reason `storeProductImageBytes` exists alongside the product slot: the
 * presigned PUT is cross-origin to BUCKET_ARTIFACTS, which serves no CORS
 * policy (docs/aws-storage-and-cdn.md), so it cannot work from the BROWSER
 * build. A logo is one small file, so proxying it costs little — the reasoning
 * does NOT extend to capture uploads, which stay direct-to-S3.
 *
 * The key lands under the RESERVED slot segment (`.../products/logo/`), not a
 * uuid one, so the commit's prefix sweep still collects the superseded image.
 */
export async function storeBrandingImageBytes(
  userId: string,
  input: { bytes: Buffer; contentType: ProductImageContentType; slot: BrandingSlot }
): Promise<BrandingImageBytesResult> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NOT_FOUND' };

  const key = buildBrandingImageKey(
    (catalog._id as Types.ObjectId).toHexString(),
    input.slot,
    randomUUID(),
    productImageExtensionFor(input.contentType)
  );

  await putObjectBytes(BUCKET_ARTIFACTS, key, input.bytes, input.contentType);

  return { outcome: 'OK', key };
}

export type CommitBrandingResult =
  | { outcome: 'NOT_FOUND' }
  | { outcome: 'INVALID_KEY' }
  | { outcome: 'FORBIDDEN' }
  | { outcome: 'OBJECT_NOT_FOUND' }
  | { outcome: 'TOO_LARGE' }
  | { outcome: 'COMMITTED'; profile: BusinessProfileDto };

/**
 * Binds an uploaded object as the catalog logo or cover.
 *
 * Bumps `draftRevision` like every other authoring write: branding reaches
 * customers only at publish, so changing it must light up the "draft changes not
 * yet live" badge.
 *
 * ORDERING: the pointer flips first, then the old objects are swept — a crash
 * between the two leaves an orphan rather than a catalog pointing at an object
 * that no longer exists.
 */
export async function commitBrandingImage(
  userId: string,
  input: BrandingCommitInput
): Promise<CommitBrandingResult> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NOT_FOUND' };

  const catalogId = catalog._id as Types.ObjectId;
  const check = await checkCatalogImageKey(catalogId, input.key);
  if (check.outcome !== 'OK') return check;

  const field = input.slot === 'logo' ? 'logoKey' : 'coverImageKey';
  const previousKey = input.slot === 'logo' ? catalog.logoKey : catalog.coverImageKey;

  const updated = await Catalog.findOneAndUpdate(
    { _id: catalogId, deletedAt: null },
    { $set: { [field]: input.key }, $inc: { draftRevision: 1 } },
    { new: true, runValidators: true }
  ).exec();
  if (!updated) return { outcome: 'NOT_FOUND' };

  await sweepSupersededImages(input.key, previousKey);

  return { outcome: 'COMMITTED', profile: toBusinessProfileDto(updated) };
}


// ── Delete (start over) ─────────────────────────────────────────────────────

/**
 * Outcome of a catalog delete.
 *
 * `MIRAGE_FAILED` is its own outcome rather than a thrown error because the
 * caller has to say something specific: the local rows are still there, nothing
 * was lost, and retrying is the fix.
 */
export type DeleteCatalogResult =
  | { outcome: 'NOT_FOUND' }
  /** A publish run holds the catalog. Deleting under it would race the worker. */
  | { outcome: 'PUBLISH_IN_PROGRESS'; runId: string }
  /** Mirage would not let go of the restaurant. NOTHING was deleted. */
  | { outcome: 'MIRAGE_FAILED'; code: string }
  | {
      outcome: 'DELETED';
      deletedProducts: number;
      deletedCategories: number;
      /** True when a live Mirage restaurant was torn down with it. */
      wasPublished: boolean;
    };

/**
 * Deletes the caller's catalog and everything under it, so they can create a
 * new one from scratch.
 *
 * ⚠ THIS IS A HARD DELETE, and deliberately not the house soft-delete.
 * The unique index on `Catalog.userId` has no `deletedAt` predicate, so a
 * soft-deleted catalog KEEPS its owner's one slot — and `createCatalog` resolves
 * the resulting E11000 by replaying the existing row. A soft delete here would
 * therefore hand the user back the catalog they just deleted the moment they
 * tried to make a new one, which is the exact opposite of what this endpoint is
 * for. Anything that reintroduces a soft delete has to make that index partial
 * on `deletedAt: null` in the same change.
 *
 * ORDER MATTERS. Mirage is torn down FIRST, and a refusal aborts the whole
 * operation with the local rows untouched:
 *
 *   • Mirage's `delete-restaurant` cascades its own categories and items, so one
 *     call empties the public side.
 *   • If we dropped the local rows first and Mirage then refused, the mapping
 *     (`mirageRestaurantId`) would be gone and the orphaned restaurant would be
 *     unreachable from here forever — while still serving the old products at
 *     the old URL.
 *   • Worse, provisioning ADOPTS a Mirage restaurant whose name matches
 *     (§7.5). A leftover restaurant means the user's "fresh" catalog would
 *     silently adopt it on its first publish and inherit every product they
 *     just deleted. "Fresh start" has to be true on the public page too.
 *
 * A restaurant Mirage has already lost (`MIRAGE_NOT_FOUND`) is treated as
 * success — the end state is the one we were asking for.
 *
 * NOT cleaned up: S3 objects (logo, cover, product images and models). They are
 * content-addressed under the catalog id and nothing else can reach them, so
 * they are dead weight rather than a correctness problem; a bucket lifecycle
 * sweep is the right tool, not a request-path loop over an unbounded key set.
 */
export async function deleteCatalog(userId: string): Promise<DeleteCatalogResult> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return { outcome: 'NOT_FOUND' };

  const catalogId = catalog._id as Types.ObjectId;

  // A run in flight is mid-way through writing this catalog into Mirage. Let it
  // finish or fail on its own terms rather than deleting the rows underneath it.
  const active = await hasActiveRun(catalogId);
  if (active.active && active.runId) {
    return { outcome: 'PUBLISH_IN_PROGRESS', runId: active.runId };
  }

  const restaurantId = catalog.mirageRestaurantId;

  if (restaurantId) {
    try {
      await getMirageClient().deleteRestaurant(restaurantId);
    } catch (err) {
      if (!(err instanceof MirageError)) throw err;

      // Already gone is the state we wanted. Anything else aborts with the
      // local rows intact, so the user can retry rather than being left with
      // half a catalog and a live public page.
      if (err.code !== MirageErrorCode.NOT_FOUND) {
        console.warn(
          `[catalog] delete aborted: Mirage refused delete-restaurant (${err.code})`
        );
        return { outcome: 'MIRAGE_FAILED', code: err.code };
      }
    }
  }

  // Children first: a crash between these leaves orphan rows whose catalog is
  // gone, and orphan children are invisible (every read is scoped by catalogId)
  // where an orphan CATALOG would still be served as the user's own.
  const [products, categories] = await Promise.all([
    CatalogProduct.deleteMany({ catalogId }).exec(),
    CatalogCategory.deleteMany({ catalogId }).exec(),
  ]);

  // Publish history goes too. It is per-catalog and references a catalogId that
  // is about to stop existing; its counts are not destructured because nothing
  // reports them.
  await CatalogPublishRun.deleteMany({ catalogId }).exec();

  await Catalog.deleteOne({ _id: catalogId }).exec();

  return {
    outcome: 'DELETED',
    deletedProducts: products.deletedCount ?? 0,
    deletedCategories: categories.deletedCount ?? 0,
    wasPublished: Boolean(restaurantId),
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
