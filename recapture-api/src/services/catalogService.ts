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
import { CustomerContact } from '@/models/CustomerContact';
import { Catalog, type ICatalog } from '@/models/Catalog';
import { CatalogProduct } from '@/models/CatalogProduct';
import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogPublishRun } from '@/models/CatalogPublishRun';
import { getMirageClient, MirageError, MirageErrorCode } from '@/services/mirage';
import { hasActiveRun } from '@/services/catalog/publishRunState';
import { BUCKET_ARTIFACTS, CLOUDFRONT_BASE } from '@/config/s3';
import { env } from '@/config/env';
import { customerUrl } from '@/services/customerUrl';
import { presignObjectPutUrl, putObjectBytes } from '@/services/s3ObjectStore';
import { checkCatalogImageKey, sweepSupersededImages } from '@/services/catalogImages';
import {
  cancelOnCatalogDelete,
  getSubscriptionSummary,
  type SubscriptionSummaryDto,
} from '@/services/subscription/subscriptionService';
import { settleOpenOrdersOnRead } from '@/services/subscription/reconcileService';
import { cancelAutopay } from '@/services/subscription/autopayService';
import { alertAdmins } from '@/services/subscription/adminAlerts';
import { rejectPendingOnCatalogDelete } from '@/services/subscription/manualPaymentService';
import {
  buildBrandingImageKey,
  productImageExtensionFor,
  type BrandingSlot,
  type ProductImageContentType,
} from '@/utils/productImageKeys';
import type {
  AnnouncementStyle,
  CatalogBadge,
  CatalogAppearance,
  CatalogContact,
  CatalogHours,
  CatalogLanguages,
  CatalogTranslations,
  CatalogStatus,
  CatalogArBranding,
  CatalogEngagement,
  CatalogQrStyle,
  CatalogSpotlight,
  CatalogCustomers,
  CatalogLinks,
} from '@/models/types/catalog.types';
import { effectiveLanguages } from '@/models/types/catalog.types';
import { translationWrites } from '@/services/catalog/menuTranslations';
import {
  appearanceContrastProblem,
  type AppearanceContrastProblem,
} from '@/utils/colorContrast';
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
   * The link to SHOW — the Mirage menu page — or null before first publish.
   * Under the MIRAGE_OBJECT_ID scheme this is the frozen `publicUrl` verbatim;
   * under RECAPTURE_SHORT_CODE the stored string is this API's resolver and is
   * never shown — see `services/customerUrl.ts`. Displayed by the client
   * verbatim and composed by nobody on that side.
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
  /**
   * True when authoring writes have landed SINCE the in-flight run planned —
   * `draftRevision > run.snapshotRevision`. False whenever nothing is running.
   *
   * WHY `hasUnpublishedChanges` CANNOT ANSWER THIS. That flag compares against
   * `publishedRevision`, which only moves at finalize, so it is true for the
   * whole duration of EVERY run — including one that carries the draft
   * perfectly. A client using it to decide whether to re-offer Publish would
   * re-offer it during every publish, and the rep would learn to ignore it.
   *
   * The run planned from a SNAPSHOT (see publishSnapshot.ts), so an edit made
   * after that instant is genuinely not in the run and genuinely needs another
   * publish. This is the only field that says so.
   */
  hasChangesSincePublishStarted: boolean;
  counts: CatalogCountsDto;
  /**
   * The compact subscription state, or null when the catalog has no
   * subscription row yet — the header chip and the rep list read this so
   * neither pays a second request. The full picture is GET /catalog/subscription.
   */
  subscription: SubscriptionSummaryDto | null;
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

/**
 * The ONE catalog DTO mapper — every catalog response serializes through here.
 *
 * [publishSnapshotRevision] is the in-flight run's `snapshotRevision`, or null
 * when nothing is running or the caller did not load it. Null reads as "no
 * changes since the run planned", which is the answer that keeps a caller who
 * cannot cheaply load the run — a create, where nothing can be running yet —
 * from claiming a staleness it has not checked.
 */
export function toCatalogDto(
  c: ICatalog,
  counts: CatalogCountsDto,
  publishSnapshotRevision: number | null = null,
  subscription: SubscriptionSummaryDto | null = null
): CatalogDto {
  return {
    id: c.id as string,
    name: c.name,
    businessName: c.businessName ?? null,
    contact: c.contact ?? null,
    status: c.status,
    publicUrl: customerUrl(c),
    isProvisioned: Boolean(c.mirageRestaurantId),
    hasUnpublishedChanges: c.draftRevision > c.publishedRevision,
    lastPublishedAt: c.lastPublishedAt ? c.lastPublishedAt.toISOString() : null,
    isPublishing: Boolean(c.activePublishRunId),
    hasChangesSincePublishStarted:
      Boolean(c.activePublishRunId) &&
      publishSnapshotRevision !== null &&
      c.draftRevision > publishSnapshotRevision,
    counts,
    subscription,
    updatedAt: c.updatedAt.toISOString(),
    createdAt: c.createdAt.toISOString(),
  };
}

/** The summary every catalog DTO carries — one read, keyed by the catalog and its owner. */
function subscriptionSummaryOf(c: ICatalog): Promise<SubscriptionSummaryDto | null> {
  return getSubscriptionSummary(c._id as Types.ObjectId, c.userId);
}

/**
 * Loads the caller's catalog as a DTO, or null when they have none yet.
 *
 * The extra run read happens ONLY while a publish holds the catalog, which is a
 * few seconds per visit — and it is what lets a rep who edits a dish mid-publish
 * be told the running publish will not carry it. Every other read pays nothing.
 */
export async function getCatalog(userId: string): Promise<CatalogDto | null> {
  const catalog = await findOwnedCatalog(userId);
  if (!catalog) return null;

  // A paid order the webhook never delivered becomes ACTIVE here, before the
  // summary is read — so the catalog chip is right on the first load after
  // paying (or after signing in on another phone). Fail-open and bounded.
  await settleOpenOrdersOnRead(catalog._id as Types.ObjectId);

  const [counts, activeRun, subscription] = await Promise.all([
    countsFor(catalog._id as Types.ObjectId),
    catalog.activePublishRunId
      ? CatalogPublishRun.findById(catalog.activePublishRunId)
          .select({ snapshotRevision: 1 })
          .lean()
          .exec()
      : Promise.resolve(null),
    subscriptionSummaryOf(catalog),
  ]);

  return toCatalogDto(catalog, counts, activeRun?.snapshotRevision ?? null, subscription);
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
      catalog: toCatalogDto(
        existing,
        await countsFor(existing._id as Types.ObjectId),
        null,
        await subscriptionSummaryOf(existing)
      ),
    };
  }
}

export type UpdateCatalogResult =
  | { outcome: 'NOT_FOUND' }
  | { outcome: 'LOW_CONTRAST'; problem: AppearanceContrastProblem }
  | { outcome: 'UPDATED'; catalog: CatalogDto };

/**
 * A readable appearance, or the reason it is not. Checked BEFORE the write, on
 * the input alone: `appearance` replaces the whole block, so what was stored
 * before has no say in whether the new one is readable.
 */
function appearanceRefusal(input: UpdateCatalogInput): AppearanceContrastProblem | null {
  return input.appearance ? appearanceContrastProblem(input.appearance) : null;
}

/** An appearance with nothing in it is no appearance — stored as absent. */
function isEmptyAppearance(a: CatalogAppearance | null | undefined): boolean {
  // `showFilters: false` is the default, so it counts as nothing set.
  return !a || Object.values(a).every((v) => v === undefined || v === '' || v === false);
}

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
  const unset: Record<string, 1> = {};
  if (input.name !== undefined) set.name = input.name;
  if (input.businessName !== undefined) set.businessName = input.businessName;
  if (input.contact !== undefined) set.contact = input.contact;
  // Appearance REPLACES the block; `null` (Reset to default) and an empty
  // object both remove it, so the catalog reads exactly like one that never
  // had an appearance and Mirage is sent the all-'' default theme.
  if (input.appearance !== undefined) {
    if (isEmptyAppearance(input.appearance)) unset.appearance = 1;
    else set.appearance = input.appearance;
  }
  // Stage 4: both REPLACE their block; null removes it.
  if (input.hours !== undefined) {
    if (input.hours === null) unset.hours = 1;
    else set.hours = input.hours;
  }
  if (input.announcement !== undefined) {
    if (input.announcement === null) unset.announcement = 1;
    else set.announcement = input.announcement;
  }
  if (input.badges !== undefined) set.badges = input.badges;
  // Stage 6: the languages block is replaced; the announcement / badge-label
  // translations merge per language, like a product's.
  if (input.languages !== undefined) set.languages = input.languages;
  const translations = translationWrites(input.i18n);
  Object.assign(set, translations.set);
  Object.assign(unset, translations.unset);
  // Stage 7: each REPLACES its block; null removes it.
  for (const key of ['arBranding', 'spotlight', 'engagement', 'qrStyle'] as const) {
    const value = input[key];
    if (value === undefined) continue;
    if (value === null) unset[key] = 1;
    else set[key] = value;
  }
  // Stage 11: My plate — replaced whole.
  if (input.plate !== undefined) set.plate = input.plate;
  // Stage 12: links replaced whole (null / all-empty removes); the sign-up switch.
  if (input.links !== undefined) {
    if (input.links === null || Object.keys(input.links).length === 0) unset.links = 1;
    else set.links = input.links;
  }
  if (input.customers !== undefined) set.customers = input.customers;

  const updated = await Catalog.findOneAndUpdate(
    { userId: ownerId, deletedAt: null },
    // The draft bump rides along in the SAME update rather than going through
    // bumpDraftRevision: this write already targets the catalog document, and
    // folding it in keeps the edit and its revision atomic.
    {
      ...(Object.keys(set).length > 0 ? { $set: set } : {}),
      ...(Object.keys(unset).length > 0 ? { $unset: unset } : {}),
      $inc: { draftRevision: 1 },
    },
    { new: true, runValidators: true }
  ).exec();

  // Stage 6: a category's published name set depends on which languages are
  // on, but the planner only re-pushes a category edited since its last sync.
  // Touching them is what gets the new set to the menu on the next publish.
  if (updated && input.languages !== undefined) {
    await CatalogCategory.updateMany(
      { catalogId: updated._id, deletedAt: null },
      { $set: { updatedAt: new Date() } },
      { timestamps: false }
    ).exec();
  }

  // Stage 5: a badge removed from the library comes off every product in the
  // same request, so no dish keeps pointing at a badge that no longer exists.
  // Pulling "everything not in the new list" needs no before/after diff.
  if (updated && input.badges !== undefined) {
    await CatalogProduct.updateMany(
      { catalogId: updated._id, badgeIds: { $exists: true, $ne: [] } },
      { $pull: { badgeIds: { $nin: input.badges.map((b) => b.id) } } }
    ).exec();
  }

  return updated;
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
  const problem = appearanceRefusal(input);
  if (problem) return { outcome: 'LOW_CONTRAST', problem };

  const updated = await applyCatalogPatch(userId, input);

  if (!updated) return { outcome: 'NOT_FOUND' };

  return {
    outcome: 'UPDATED',
    catalog: toCatalogDto(
      updated,
      await countsFor(updated._id as Types.ObjectId),
      null,
      await subscriptionSummaryOf(updated)
    ),
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
 * `contact.socials.*` → socialLinks · `coverImageUrl` → coverImage (the menu's
 * hero banner, more-customization Stage 3) · `appearance` → theme.
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
  // The menu theme — Mirage `restaurant.theme` (more-customization Stage 2).
  'appearance',
  // The hero banner — Mirage `restaurant.coverImage` (Stage 3).
  'coverImageUrl',
  // Opening hours and the announcement strip (Stage 4).
  'hours',
  'announcement',
  // The badge library (Stage 5) — reaches customers through the dishes.
  'badges',
  // The menu's languages and the text in them (Stage 6).
  'languages',
  'i18n',
  // The 3D viewer's branding, the spotlight carousel and the customer buttons
  // (Stage 7). `qrStyle` is not here: it changes what is PRINTED, not the menu.
  'arBranding',
  'spotlight',
  'engagement',
  // "My plate" (Stage 11).
  'plate',
  // Delivery / booking links and the WhatsApp-offers card (Stage 12).
  'links',
  'customers',
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
  /** The public menu's look; null = the default Basalt page. */
  appearance: CatalogAppearance | null;
  /** Stage 4: opening hours; null = none set. */
  hours: CatalogHours | null;
  /** Stage 4: the announcement strip, dates as ISO strings; null = none. */
  announcement: AnnouncementDto | null;
  /** Stage 5: the badge library, in the owner's order. Empty = none. */
  badges: CatalogBadge[];
  /** Stage 6: which languages the menu is offered in (English only by default). */
  languages: CatalogLanguages;
  /**
   * Stage 6: the announcement and badge labels per language — every stored
   * language, including one switched off. `{}` when none.
   */
  i18n: CatalogTranslations;
  /** Stage 7: null = the plain viewer / no carousel / no buttons / black-on-white QR. */
  arBranding: CatalogArBranding | null;
  spotlight: CatalogSpotlight | null;
  engagement: CatalogEngagement | null;
  qrStyle: CatalogQrStyle | null;
  /** Stage 11: My plate. Always present — absent on the catalog reads as on, with totals. */
  plate: { enabled: boolean; showTotal: boolean };
  /** Stage 12: null = no delivery / booking links. */
  links: CatalogLinks | null;
  /** Stage 12: the WhatsApp-offers card; off unless switched on. */
  customers: CatalogCustomers;
  /**
   * Stage 8.2: the menu's pretty address and its full URL (null when no
   * subdomain host is configured). Additional to `publicUrl`, never instead.
   */
  slug: string | null;
  slugUrl: string | null;
  /** See {@link PUBLIC_PROFILE_FIELDS}. */
  publicFields: readonly string[];
  updatedAt: string;
}

/** `null` for an unset key — never a `.../undefined` URL. */
function cdnUrlForKey(key: string | undefined): string | null {
  return key ? `${CLOUDFRONT_BASE}/${key}` : null;
}

/** The announcement on the wire — dates as ISO strings, null when unbounded. */
export interface AnnouncementDto {
  text: string;
  emoji?: string;
  style: AnnouncementStyle;
  startsAt: string | null;
  endsAt: string | null;
  link?: string;
}

/** Field by field, like every DTO here; unset keys are omitted, not null. */
function toAppearanceDto(a: CatalogAppearance | undefined): CatalogAppearance | null {
  if (isEmptyAppearance(a)) return null;
  return {
    ...(a!.presetId ? { presetId: a!.presetId } : {}),
    ...(a!.mode ? { mode: a!.mode } : {}),
    ...(a!.primary ? { primary: a!.primary } : {}),
    ...(a!.accent ? { accent: a!.accent } : {}),
    ...(a!.layout ? { layout: a!.layout } : {}),
    ...(a!.fontId ? { fontId: a!.fontId } : {}),
    ...(a!.showFilters ? { showFilters: true } : {}),
  };
}

/**
 * Stored catalog translations for the DTO, strings only. A label for a badge
 * that has since been deleted passes through: it is never published (nothing
 * resolves to it), and the app's next save of that language drops it.
 */
function catalogTranslationsDto(raw: unknown): CatalogTranslations {
  const out: CatalogTranslations = {};
  if (!raw || typeof raw !== 'object') return out;
  for (const [lang, entry] of Object.entries(raw as Record<string, unknown>)) {
    if (!entry || typeof entry !== 'object') continue;
    const { announcement, badges } = entry as Record<string, unknown>;
    const labels: Record<string, string> = {};
    if (badges && typeof badges === 'object') {
      for (const [id, label] of Object.entries(badges as Record<string, unknown>)) {
        if (typeof label === 'string' && label) labels[id] = label;
      }
    }
    const t = {
      ...(typeof announcement === 'string' && announcement ? { announcement } : {}),
      ...(Object.keys(labels).length > 0 ? { badges: labels } : {}),
    };
    if (Object.keys(t).length > 0) out[lang as keyof CatalogTranslations] = t;
  }
  return out;
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
    appearance: toAppearanceDto(c.appearance),
    hours: c.hours
      ? {
          timezone: c.hours.timezone,
          weekly: c.hours.weekly.map((s) => ({ day: s.day, open: s.open, close: s.close })),
          closedDates: [...(c.hours.closedDates ?? [])],
          showOpenBadge: c.hours.showOpenBadge !== false,
        }
      : null,
    announcement: c.announcement
      ? {
          text: c.announcement.text,
          ...(c.announcement.emoji ? { emoji: c.announcement.emoji } : {}),
          style: c.announcement.style,
          startsAt: c.announcement.startsAt?.toISOString() ?? null,
          endsAt: c.announcement.endsAt?.toISOString() ?? null,
          ...(c.announcement.link ? { link: c.announcement.link } : {}),
        }
      : null,
    badges: (c.badges ?? []).map((b) => ({ id: b.id, label: b.label, icon: b.icon, color: b.color })),
    languages: effectiveLanguages(c),
    i18n: catalogTranslationsDto(c.i18n),
    arBranding: c.arBranding
      ? {
          watermarkLogo: c.arBranding.watermarkLogo === true,
          loaderStyle: c.arBranding.loaderStyle ?? 'default',
          stage: c.arBranding.stage ?? 'none',
          showDishName: c.arBranding.showDishName === true,
        }
      : null,
    spotlight: c.spotlight
      ? {
          enabled: c.spotlight.enabled === true,
          productIds: [...(c.spotlight.productIds ?? [])],
          ...(c.spotlight.title ? { title: c.spotlight.title } : {}),
        }
      : null,
    engagement: c.engagement
      ? {
          ...(c.engagement.reviewUrl ? { reviewUrl: c.engagement.reviewUrl } : {}),
          whatsappOrder: c.engagement.whatsappOrder === true,
          callWaiter: c.engagement.callWaiter === true,
          ...(c.engagement.wifi?.ssid
            ? {
                wifi: {
                  ssid: c.engagement.wifi.ssid,
                  ...(c.engagement.wifi.password ? { password: c.engagement.wifi.password } : {}),
                },
              }
            : {}),
          feedbackForm: c.engagement.feedbackForm === true,
        }
      : null,
    links: c.links && Object.keys(c.links).length > 0 ? { ...c.links } : null,
    customers: { optInEnabled: c.customers?.optInEnabled === true },
    plate: {
      enabled: c.plate?.enabled !== false,
      showTotal: c.plate?.showTotal !== false,
    },
    qrStyle: c.qrStyle
      ? {
          fg: c.qrStyle.fg,
          bg: c.qrStyle.bg,
          logoCenter: c.qrStyle.logoCenter === true,
          ...(c.qrStyle.frameText ? { frameText: c.qrStyle.frameText } : {}),
          template: c.qrStyle.template ?? 'classic',
        }
      : null,
    slug: c.slug ?? null,
    slugUrl: c.slug && env.MENU_SUBDOMAIN_BASE ? `https://${c.slug}.${env.MENU_SUBDOMAIN_BASE}` : null,
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
  | { outcome: 'LOW_CONTRAST'; problem: AppearanceContrastProblem }
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
  const problem = appearanceRefusal(input);
  if (problem) return { outcome: 'LOW_CONTRAST', problem };

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
// Both reach the public page at publish: the logo as the restaurant `icon`, the
// cover (since more-customization Stage 3) as the menu's hero banner, sent to
// Mirage as `coverUrl` for it to copy. The profile DTO's `publicFields` is what
// tells the client which fields are public.

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
      /** True when a subscription row was moved to CANCELLED with it (C9). */
      subscriptionCancelled: boolean;
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

  // The subscription is CANCELLED, not deleted, and only once Mirage has let
  // go: a refusal above aborts with everything intact, this row included. It
  // outlives the catalog on purpose — `trialUsedAt` is the owner's history
  // (D2), and the row's `userId` is how a re-created catalog inherits it.
  // Autopay first: a mandate left running would keep charging a restaurant
  // that no longer exists. Not a reason to refuse the delete if Razorpay is
  // down — the admins are told, and the charge would land as an ORPHAN_PAYMENT
  // (recorded, not activated, a refund case) rather than vanish.
  const autopay = await cancelAutopay(catalogId, 'CATALOG_DELETED');
  if (autopay.outcome === 'UNAVAILABLE') {
    void alertAdmins({
      kind: 'AUTOPAY_CANCEL_FAILED',
      catalogId,
      title: 'Autopay not stopped for a deleted catalog',
      message:
        `Catalog ${catalogId.toHexString()} was deleted but its Razorpay autopay could not be ` +
        'cancelled. Cancel the subscription from the Razorpay dashboard.',
    });
  }
  const subscriptionCancelled = await cancelOnCatalogDelete(catalogId);
  // And every cash request still awaiting verification is rejected (E37):
  // an admin working the queue a week from now must not be able to activate
  // a catalog that is about to stop existing.
  await rejectPendingOnCatalogDelete(catalogId);

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
  // Stage 12.2: the customer list never outlives the catalog it was given to.
  // (Mirage deletes its copy with the restaurant.)
  await CustomerContact.deleteMany({ catalogId }).exec();

  await Catalog.deleteOne({ _id: catalogId }).exec();

  return {
    outcome: 'DELETED',
    deletedProducts: products.deletedCount ?? 0,
    deletedCategories: categories.deletedCount ?? 0,
    wasPublished: Boolean(restaurantId),
    subscriptionCancelled,
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
