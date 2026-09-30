// src/models/types/catalog.types.ts
//
// Shared vocabularies and nested-field types for the catalog collections
// (models/Catalog.ts, CatalogProduct.ts, CatalogCategory.ts,
// CatalogPublishRun.ts) — the authoring store behind the Mirage publish flow.
//
// They live here, beside the other model type files, rather than in
// src/services/ or src/worker/: routes, services and the publish processor all
// need them, and services must not import from the worker.
//
// Design context: ReCapture OWNS catalog truth and Mirage holds a derived copy
// that only the publish worker writes (docs/next-phase/03-architecture-proposal.md
// §2a). Every `mirage*` field below is therefore a MAPPING — a record of what
// the projection currently looks like — never an input to authoring.

// ── Catalog ─────────────────────────────────────────────────────────────────

/**
 * Publish lifecycle of a whole catalog.
 *   DRAFT       — never published; no Mirage restaurant, no public URL yet.
 *   PUBLISHED   — at least one successful publish run; the public URL is live.
 *   UNPUBLISHED — items removed from Mirage, but the restaurant document (and
 *                 therefore the ObjectId, the public URL and every printed QR)
 *                 is deliberately KEPT. See §7.6 — Mirage has no hide flag, and
 *                 the only removal primitive destroys the id the QR is built on.
 */
export const CATALOG_STATUSES = ['DRAFT', 'PUBLISHED', 'UNPUBLISHED'] as const;
export type CatalogStatus = (typeof CATALOG_STATUSES)[number];

/**
 * How {@link ICatalog.publicUrl} was derived, recorded ON the catalog so a
 * future scheme change cannot silently rewrite already-issued URLs — a
 * grandfathered catalog is visibly on the old scheme instead of quietly
 * repointed. There are two:
 *
 *   MIRAGE_OBJECT_ID — `{MIRAGE_PUBLIC_BASE_URL}/{mirageRestaurantId}`.
 *   Every public Mirage resolver falls back to `findById` when the name lookup
 *   misses (mirage-be/src/Controllers/itemController.js:472-478), and an
 *   ObjectId is immutable where a name is not. That is what makes "the QR never
 *   breaks" a property of the URL scheme rather than a rule people remember.
 *
 *   RECAPTURE_SHORT_CODE — `{PUBLIC_RESOLVER_BASE_URL}/r/{code}`, written at
 *   REP ACTIVATION, before Mirage has ever heard of this restaurant. The
 *   indirection is the point: the printed code is meaningless and permanent,
 *   and remapping happens on the QrCode row rather than on this URL — so
 *   `publicUrl` stays as frozen under this scheme as under the other one.
 *
 * This enum being multi-member is exactly why it was written as an enum rather
 * than inferred from the string: catalogs provisioned before same-day
 * activation keep MIRAGE_OBJECT_ID and their printed QRs keep working, visibly
 * grandfathered instead of quietly repointed.
 */
export const PUBLIC_URL_SCHEMES = ['MIRAGE_OBJECT_ID', 'RECAPTURE_SHORT_CODE'] as const;
export type PublicUrlScheme = (typeof PUBLIC_URL_SCHEMES)[number];

/**
 * Public social handles/links for the business.
 *
 * PUBLISHED to Mirage. Its restaurant schema gained `socialLinks` in the phase-2
 * rework (mirage-be/src/Models/restaurantModel.js:82-91) and the public page
 * renders them in its contact sheet, so these reach customers on the next
 * publish — see `mirageLinks` in catalogProvisioningService.
 *
 * Mirage also holds `x` and `linkedin`; ReCapture has no field for either and
 * the publish path leaves them untouched rather than clearing them.
 */
export interface CatalogSocials {
  instagram?: string;
  facebook?: string;
  youtube?: string;
  whatsapp?: string;
}

/**
 * Business contact block.
 *
 * `phone` → `restaurant.phone` (the create endpoint prefixes `+91`),
 * `address` → the free-text `restaurant.location`, and `website`/`socials` →
 * `restaurant.website`/`restaurant.socialLinks`. `email` is the only
 * ReCapture-only field left: Mirage has nowhere to put it.
 */
export interface CatalogContact {
  phone?: string;
  email?: string;
  address?: string;
  website?: string;
  socials?: CatalogSocials;
}

/**
 * How the public Mirage menu LOOKS (more-customization Stage 2).
 *
 * PUBLISHED to Mirage as `restaurant.theme` on every branding sync — see
 * `mirageTheme` in catalogProvisioningService. Every key optional: an absent
 * appearance (every catalog written before this field) is the default Basalt
 * page, exactly as before.
 *
 * `presetId` must be one of config/themePresets.ts THEME_PRESET_IDS; the colour
 * overrides are `#RRGGBB` and must pass utils/colorContrast.ts, which is the
 * same check Mirage-fe re-runs before painting them. Later stages (cover,
 * layout, fonts) add keys HERE rather than new top-level catalog fields.
 */
export interface CatalogAppearance {
  presetId?: string;
  /** Informational: every current preset fixes its own mode. */
  mode?: 'dark' | 'light';
  primary?: string;
  accent?: string;
  /** Stage 3: how dish cards are drawn. Absent = `grid`, today's cards. */
  layout?: 'grid' | 'list' | 'large';
  /** Stage 3: a THEME_FONT_IDS pairing. Absent = the default fonts. */
  fontId?: string;
  /** Stage 5: show the diet filter bar on the menu. Absent = off. */
  showFilters?: boolean;
}

// ── Badges and dietary detail (more-customization Stage 5) ─────────────────

/** Mapped to lucide icons in mirage-fe (features/menu/dishDetails.tsx). */
export const BADGE_ICONS = [
  'flame',
  'star',
  'sparkles',
  'leaf',
  'chef-hat',
  'crown',
  'heart',
  'thumbs-up',
  'clock',
  'percent',
] as const;
export type BadgeIcon = (typeof BADGE_ICONS)[number];

/** `primary` / `accent` follow the menu's theme; the rest are fixed hues. */
export const BADGE_COLORS = ['primary', 'accent', 'red', 'green', 'blue', 'orange'] as const;
export type BadgeColor = (typeof BADGE_COLORS)[number];

export const MAX_BADGES = 12;
export const MAX_BADGE_LABEL = 18;
/** How many a product may carry. The menu card shows two; the sheet shows all. */
export const MAX_PRODUCT_BADGES = 6;

/**
 * One badge in the catalog's library. Products hold its `id`; the publish step
 * denormalises `{ label, icon, color }` onto the Mirage item (dishDetails.ts).
 */
export interface CatalogBadge {
  id: string;
  label: string;
  icon: BadgeIcon;
  color: BadgeColor;
}

export const PRODUCT_DIETARY = [
  'JAIN',
  'VEGAN',
  'GLUTEN_FREE',
  'EGGLESS',
  'SUGAR_FREE',
  'KETO',
  'HIGH_PROTEIN',
] as const;
export type ProductDietary = (typeof PRODUCT_DIETARY)[number];

export const PRODUCT_ALLERGENS = [
  'NUTS',
  'DAIRY',
  'GLUTEN',
  'SOY',
  'EGG',
  'SHELLFISH',
  'SESAME',
] as const;
export type ProductAllergen = (typeof PRODUCT_ALLERGENS)[number];

/** A vegan or Jain dish cannot also be non-veg — refused as DIET_CONFLICT. */
export function dietConflicts(
  foodType: ProductFoodType,
  dietary: readonly string[] | undefined
): boolean {
  return (
    foodType === 'NON_VEG' && (dietary ?? []).some((d) => d === 'VEGAN' || d === 'JAIN')
  );
}

// ── Menu languages (more-customization Stage 6) ────────────────────────────
//
// The primary text stays where it always was (`name`, `description`, the
// announcement's `text`, a badge's `label`) — nothing moves. Translations sit
// BESIDE it, keyed by language, and the owner types every one of them (Q3: no
// machine translation). The public page falls back to the primary text wherever
// a translation is missing.

/**
 * Every language a menu can be written in. Mirage-fe maps each to a label and,
 * for the non-Latin scripts, a Noto font (src/i18n/languages.ts). Hand-synced
 * with that file, mirage-be helper/i18nFields.js and the Flutter
 * domain/catalog/menu_languages.dart.
 */
export const MENU_LANGUAGES = ['en', 'hi', 'mr', 'gu', 'ta', 'te', 'kn', 'bn', 'pa', 'ml'] as const;
export type MenuLanguage = (typeof MENU_LANGUAGES)[number];

/** How many languages a menu may offer besides its primary one. */
export const MAX_EXTRA_LANGUAGES = 3;

/**
 * Which languages the menu is offered in → Mirage `restaurant.languages`.
 * `extra` never contains `primary`. Absent on the catalog = English only.
 */
export interface CatalogLanguages {
  primary: MenuLanguage;
  extra: MenuLanguage[];
}

export const DEFAULT_LANGUAGES: CatalogLanguages = { primary: 'en', extra: [] };

/** A dish's name / description in one language. Either may be missing. */
export interface ProductTranslation {
  name?: string;
  description?: string;
}
export type ProductTranslations = Partial<Record<MenuLanguage, ProductTranslation>>;

/** A category's name in one language. */
export interface CategoryTranslation {
  name?: string;
}
export type CategoryTranslations = Partial<Record<MenuLanguage, CategoryTranslation>>;

/**
 * The catalog-level text in one language: the announcement and the badge
 * labels, the latter keyed by badge id. Kept on the catalog rather than inside
 * the announcement / badge blocks so the Stage 4 and 5 editors, which REPLACE
 * those blocks whole, can never drop a translation they know nothing about.
 */
export interface CatalogLanguageText {
  announcement?: string;
  badges?: Record<string, string>;
}
export type CatalogTranslations = Partial<Record<MenuLanguage, CatalogLanguageText>>;

/** The stored languages, or English-only for a catalog that never chose. */
export function effectiveLanguages(catalog: { languages?: CatalogLanguages | null }): CatalogLanguages {
  const l = catalog.languages;
  if (!l) return { primary: DEFAULT_LANGUAGES.primary, extra: [] };
  return { primary: l.primary ?? 'en', extra: [...(l.extra ?? [])] };
}

// ── Time-based menu fields (more-customization Stage 4) ────────────────────
//
// All PUBLISHED to Mirage, and all evaluated ON THE PUBLIC PAGE in the
// restaurant's timezone (decision D7) — nothing here is judged server-side, so
// a scheduled announcement or a breakfast window works without a re-publish.

/** One opening slot. `close` earlier than `open` means it runs past midnight. */
export interface CatalogHoursSlot {
  /** 0 = Sunday … 6 = Saturday. */
  day: number;
  /** 'HH:mm', 24-hour. */
  open: string;
  close: string;
}

/** Opening hours → Mirage `restaurant.hours`. Replaced whole on every edit. */
export interface CatalogHours {
  /** IANA zone; 'Asia/Kolkata' unless the owner says otherwise. */
  timezone: string;
  /** Several rows per day allowed (lunch + dinner), at most 3. */
  weekly: CatalogHoursSlot[];
  /** 'YYYY-MM-DD' holidays, in the restaurant's timezone. */
  closedDates: string[];
  /** Whether the menu shows the "Open · closes 11 pm" chip. */
  showOpenBadge: boolean;
}

export const ANNOUNCEMENT_STYLES = ['info', 'offer', 'alert'] as const;
export type AnnouncementStyle = (typeof ANNOUNCEMENT_STYLES)[number];

/** The announcement strip → Mirage `restaurant.announcement`. */
export interface CatalogAnnouncement {
  text: string;
  emoji?: string;
  style: AnnouncementStyle;
  /** Either bound optional; the page shows it while startsAt ≤ now < endsAt. */
  startsAt?: Date;
  endsAt?: Date;
  link?: string;
}

/** When a category is served → Mirage `category.schedule`. */
export interface CategorySchedule {
  days: number[];
  from: string;
  to: string;
}

export const OUTSIDE_WINDOW_MODES = ['hide', 'dim'] as const;
export type OutsideWindowMode = (typeof OUTSIDE_WINDOW_MODES)[number];

// ── Products ────────────────────────────────────────────────────────────────

/**
 * What a catalog product IS.
 *   THREE_D    — backed by a SUCCEEDED ProjectModel; carries a GLB (and, where
 *                available, a USDZ and a generated preview image).
 *   IMAGE_ONLY — a photo, a name and a price. No model.
 *
 * ⚠ THE OLD REASON TO FEAR A CONVERSION IS GONE. This comment used to say that
 * `update-item` cannot unset `imgOnly`, so a conversion had to be published as
 * DELETE + CREATE and minted a new Mirage item id. Mirage's current handler
 * RE-DERIVES the flag from what the document ends up holding
 * (adminController.js:1995), so a conversion is an ordinary UPDATE and the
 * Mirage item id — with its whole analytics history — survives. See C7 in
 * docs/same-day-activation/00-preflight-and-corrections.md. Do not build a
 * DELETE + CREATE path on the strength of the old sentence.
 *
 * `type` is AUTHORED INTENT and does not move on its own. Whether a THREE_D
 * product can actually launch AR right now is {@link ProductModelStatus}, which
 * is a different question with a different answer.
 */
export const PRODUCT_TYPES = ['THREE_D', 'IMAGE_ONLY'] as const;
export type ProductType = (typeof PRODUCT_TYPES)[number];

/**
 * Does this product have a usable 3D model RIGHT NOW?
 *
 * Mirrors ProjectModel.status onto the row the menu actually renders, so the
 * menu never has to join to a project to answer "can this dish launch AR".
 *
 *   NONE       — image-only, or 3D with no linked model.
 *   QUEUED     — linked to a model that has not started generating.
 *   PROCESSING — Meshy is working on it.
 *   READY      — assets are promoted and live. THE ONLY STATE THAT GATES AR.
 *   FAILED     — generation failed; the product stays on the menu in 2D.
 *
 * `type` stays AUTHORED INTENT (THREE_D vs IMAGE_ONLY) and does not move.
 * `modelStatus` is the runtime fact. A THREE_D product with modelStatus
 * PROCESSING is a real, valid menu item — it just has no AR button yet.
 */
export const PRODUCT_MODEL_STATUSES = ['NONE', 'QUEUED', 'PROCESSING', 'READY', 'FAILED'] as const;
export type ProductModelStatus = (typeof PRODUCT_MODEL_STATUSES)[number];

/**
 * The model status of a product row, correct for legacy documents too.
 *
 * ⚠ THE BACKFILL DECISION, WRITTEN DOWN: `modelStatus` is DERIVED AT READ TIME
 * for documents that predate the field. There is no migration script and there
 * will not be one.
 *
 * Every pre-existing document materialises as `NONE` through the schema
 * default, and a product carrying a `glbUrl` is READY by definition — no other
 * state can produce one. So the derivation is total and unambiguous, it needs
 * no write, it cannot half-complete the way a script can, and a row that is
 * later promoted overwrites the stored field with the same answer. Reading the
 * raw field anywhere a legacy row could reach is the bug; call this instead.
 */
export function effectiveModelStatus(product: {
  modelStatus?: ProductModelStatus;
  assets?: { glbUrl?: string };
}): ProductModelStatus {
  const stored = product.modelStatus ?? 'NONE';
  if (stored === 'NONE' && product.assets?.glbUrl) return 'READY';
  return stored;
}

/** QUEUED or PROCESSING — a model is coming, but it is not here yet. */
export function isModelPending(status: ProductModelStatus): boolean {
  return status === 'QUEUED' || status === 'PROCESSING';
}

/**
 * ReCapture-only stock flag. Mirage's item schema has no availability field, so
 * this drives ReCapture's own list filters and nothing on the public page.
 */
export const PRODUCT_AVAILABILITIES = ['IN_STOCK', 'OUT_OF_STOCK'] as const;
export type ProductAvailability = (typeof PRODUCT_AVAILABILITIES)[number];

/**
 * The veg / non-veg marker a dish carries on the public menu.
 *   VEG     — the green square. THE DEFAULT: a dish nobody classified is
 *             vegetarian, which is what Mirage has always rendered for an
 *             item with no `isNonVeg`.
 *   NON_VEG — the red square.
 *   NONE    — no marker at all. For a catalog where the distinction is
 *             meaningless (a furniture showroom, a bakery), or a dish the
 *             owner would rather not label.
 *
 * PUBLISHED to Mirage as `foodType`, with `isNonVeg` sent alongside so the
 * older boolean the public page grew up on stays in step (NON_VEG ⇒ true,
 * everything else ⇒ false). Three values rather than a boolean because "no
 * label" is a real answer a boolean cannot give.
 *
 * Read it through `effectiveFoodType`, never raw — documents predating the
 * field have no value stored and are VEG by the same rule Mirage applies.
 */
export const PRODUCT_FOOD_TYPES = ['VEG', 'NON_VEG', 'NONE'] as const;
export type ProductFoodType = (typeof PRODUCT_FOOD_TYPES)[number];

/** The stored value, or the VEG default a document predating the field means. */
export function effectiveFoodType(product: { foodType?: ProductFoodType }): ProductFoodType {
  return product.foodType ?? 'VEG';
}

/**
 * Per-entity projection state — "does Mirage currently match what we last
 * pushed for this row?".
 *
 *   NEVER   — never included in a successful publish run.
 *   PENDING — claimed by the in-flight run.
 *   SYNCED  — Mirage matches `publishedSnapshot`.
 *   FAILED  — the last attempt failed; `syncError` says why, and feature 53's
 *             manual retry re-enqueues exactly this set.
 *
 * NOTE an authoring edit to a SYNCED product does NOT flip it back to PENDING:
 * "synced" means "Mirage matches the last snapshot", which stays true until the
 * next run. The "you have unpublished changes" signal is the catalog's
 * `draftRevision > publishedRevision`, not this field (§7.10).
 */
export const SYNC_STATUSES = ['NEVER', 'PENDING', 'SYNCED', 'FAILED'] as const;
export type SyncStatus = (typeof SYNC_STATUSES)[number];

/**
 * A product's renderable assets.
 *
 * `glbUrl`/`usdzUrl`/`thumbnailUrl` are OUR CloudFront URLs, copied from the
 * source `ProjectModel.artifacts.cdnUrls` at product-create time so a later
 * regeneration cannot silently change what a published product points at.
 * `imageKey` is an S3 key (never a URL) in the product-image key space, exactly
 * as `User.avatarKey` is — the API derives the URL.
 */
export interface ProductAssets {
  glbUrl?: string;
  usdzUrl?: string;
  thumbnailUrl?: string;
  imageKey?: string;
}

/**
 * Why a row's last sync attempt failed.
 *
 * `code` is a ReCapture `UPPER_SNAKE` code, NEVER Mirage prose: Mirage returns
 * HTTP 400 with an unversioned human sentence for validation errors, not-found,
 * a bad api key AND its global 404 handler, so its message is a classification
 * input inside the adapter and must not escape into our data or our responses.
 * `message` is OUR user-facing sentence for that code.
 */
export interface SyncError {
  code: string;
  message: string;
  at: Date;
}

/**
 * The product's field values AS LAST PUSHED to Mirage — the diff basis the
 * publish planner uses to derive CREATE / UPDATE / SKIP, and the reason a
 * republish of a text edit does not re-upload a 40 MB model.
 *
 * Stored as Mixed (see CatalogProduct.ts) on purpose: this is a snapshot whose
 * shape follows whatever the planner currently diffs, and a strict sub-schema
 * would silently DROP a newly-diffed field — which the planner would then read
 * back as "unchanged" and skip. Same reasoning as
 * `ModelGenerationTrace.selection`.
 */
export interface ProductPublishedSnapshot {
  name?: string;
  description?: string;
  price?: number;
  type?: ProductType;
  /** ReCapture category id (string form) at the time of the push. */
  categoryId?: string | null;
  /** The Mirage category the item was actually filed under. */
  mirageCategoryId?: string;
  /** Display order as last pushed (Mirage's `sortPosition`) — feature 48. */
  position?: number;
  /**
   * The veg / non-veg marker as last pushed. Absent on a snapshot written
   * before the field existed, which the planner reads as VEG — the value
   * Mirage was showing for that item all along — rather than as "changed".
   */
  foodType?: ProductFoodType;
  /**
   * Stage 5: the dish-details key as last pushed (dishDetails.ts). Absent on a
   * snapshot written before the field, which the planner reads as "none".
   */
  details?: string;
  /**
   * Stage 6: the translations key as last pushed (menuTranslations.ts). Absent
   * on a snapshot written before the field, which the planner reads as "none".
   */
  i18n?: string;
  glbUrl?: string;
  usdzUrl?: string;
  thumbnailUrl?: string;
  imageKey?: string;
  /**
   * How each Mirage file slot's bytes were identified at the last push
   * (see services/catalog/assetUploader.ts). The URL fields above catch an
   * asset that was REPLACED; this catches one whose key was overwritten in
   * place, which is the case a URL comparison cannot see — and it is what makes
   * "republishing with unchanged assets uploads nothing" exact rather than
   * merely usually right.
   *
   * Deliberately untyped here beyond a shape: it lives in a Mixed field and its
   * contents are the asset layer's business, not the planner's.
   */
  assetIdentities?: Record<string, { source: string; etag?: string; size?: number }>;
  /** When this snapshot was written. */
  at?: Date;
}

// ── Publish runs ────────────────────────────────────────────────────────────

/**
 * Outcome of one publish run.
 *   QUEUED/RUNNING — in flight (the worker's own QUEUED⇄RUNNING retry loop sits
 *                    inside RUNNING; a crash is recovered by claimNextJob's
 *                    stale-lease re-claim).
 *   SUCCEEDED — zero failures. Only this advances `publishedRevision`.
 *   PARTIAL   — ≥1 success and ≥1 failure. The successes are genuinely live, so
 *               the catalog is/stays PUBLISHED and the QR works, but
 *               `publishedRevision` is NOT advanced — "draft changes not yet
 *               live" is the truth (§7.8).
 *   FAILED    — zero successes; catalog state unchanged.
 */
export const PUBLISH_RUN_STATES = [
  'QUEUED',
  'RUNNING',
  'SUCCEEDED',
  'PARTIAL',
  'FAILED',
] as const;
export type PublishRunState = (typeof PUBLISH_RUN_STATES)[number];

/** Headline numbers for the publish screen's "7 of 10 published · 3 failed". */
export interface PublishRunCounts {
  total: number;
  synced: number;
  failed: number;
  skipped: number;
}

/** Which kind of Mirage entity an entry acted on. */
export const PUBLISH_TARGET_KINDS = ['RESTAURANT', 'CATEGORY', 'PRODUCT'] as const;
export type PublishTargetKind = (typeof PUBLISH_TARGET_KINDS)[number];

/** What the planner decided to do with that target. */
export const PUBLISH_ACTIONS = ['CREATE', 'UPDATE', 'DELETE', 'SKIP'] as const;
export type PublishAction = (typeof PUBLISH_ACTIONS)[number];

/** What actually happened when the processor ran it. */
export const PUBLISH_OUTCOMES = ['SUCCEEDED', 'FAILED', 'SKIPPED'] as const;
export type PublishOutcome = (typeof PUBLISH_OUTCOMES)[number];

/**
 * What a run was asked to do. The mode is chosen by the endpoint that enqueues
 * the run and is fixed for that run's lifetime — it is an input to the planner,
 * never something the processor re-decides.
 *
 *   FULL         — the whole catalog: provision if needed, categories, then
 *                  every live product, then the deletes.
 *   RETRY_FAILED — feature 53. Plans ONLY the rows whose `syncStatus` is
 *                  FAILED, so a user tapping Retry after "8 of 10 published"
 *                  re-attempts two products, not ten.
 *   UNPUBLISH    — feature 39. Deletes the published ITEMS and nothing else.
 *                  The Mirage restaurant, its ObjectId, the public URL and
 *                  every printed QR survive deliberately (§7.6); republishing
 *                  restores the same URL.
 */
export const PUBLISH_MODES = ['FULL', 'RETRY_FAILED', 'UNPUBLISH'] as const;
export type PublishMode = (typeof PUBLISH_MODES)[number];

/**
 * One target's outcome within a run. The `entries[]` array of these doubles as
 * the feature-55 activity log, which is why a fifth collection is not needed.
 *
 * `targetName` is denormalised so the log still reads sensibly after the row it
 * points at is deleted. It is catalog content, not PII, and must not be copied
 * into analytics props or logs.
 */
export interface PublishRunEntry {
  target: PublishTargetKind;
  /** The ReCapture id of the product/category, absent for the restaurant. */
  targetId?: string;
  targetName?: string;
  action: PublishAction;
  outcome: PublishOutcome;
  /** ReCapture `UPPER_SNAKE` code on failure — never Mirage prose. */
  code?: string;
  at: Date;
}

/** Run-level failure (as opposed to a per-target one). Same code rules. */
export interface PublishRunError {
  code: string;
  message: string;
  /**
   * On `CATALOG_NAME_TAKEN` only: a name Mirage would accept. Carried so a
   * collision discovered DURING a run offers the same one-tap rename the
   * synchronous 409 does. OPTIONAL FOREVER — every run written before this
   * field existed lacks it, and there is no backfill.
   */
  suggestedName?: string;
}
