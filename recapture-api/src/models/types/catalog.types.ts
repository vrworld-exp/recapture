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
 * repointed. Today there is exactly one scheme:
 *
 *   MIRAGE_OBJECT_ID — `{MIRAGE_PUBLIC_BASE_URL}/{mirageRestaurantId}`.
 *   Every public Mirage resolver falls back to `findById` when the name lookup
 *   misses (mirage-be/src/Controllers/itemController.js:472-478), and an
 *   ObjectId is immutable where a name is not. That is what makes "the QR never
 *   breaks" a property of the URL scheme rather than a rule people remember.
 */
export const PUBLIC_URL_SCHEMES = ['MIRAGE_OBJECT_ID'] as const;
export type PublicUrlScheme = (typeof PUBLIC_URL_SCHEMES)[number];

/**
 * Public social handles/links for the business.
 *
 * ReCapture-only: Mirage's restaurant schema has no social fields at all
 * (mirage-be/src/Models/restaurantModel.js:32-84), so these are stored, shown
 * in the app, and marked in the UI as not reaching the public page.
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
 * Only `phone` has a Mirage home (`restaurant.phone`, which the create endpoint
 * prefixes with `+91`). `email`, `address`, `website` and `socials` are
 * ReCapture-only — Mirage stores a single free-text `location` and nothing else.
 */
export interface CatalogContact {
  phone?: string;
  email?: string;
  address?: string;
  website?: string;
  socials?: CatalogSocials;
}

// ── Products ────────────────────────────────────────────────────────────────

/**
 * What a catalog product IS.
 *   THREE_D    — backed by a SUCCEEDED ProjectModel; carries a GLB (and, where
 *                available, a USDZ and a generated preview image).
 *   IMAGE_ONLY — a photo, a name and a price. No model.
 *
 * Converting between the two is a real operation with a Mirage-side cost: M9
 * (`update-item`) cannot unset `imgOnly`, so a conversion has to be published
 * as DELETE + CREATE and mints a new Mirage item id (§12 edge case 7).
 */
export const PRODUCT_TYPES = ['THREE_D', 'IMAGE_ONLY'] as const;
export type ProductType = (typeof PRODUCT_TYPES)[number];

/**
 * ReCapture-only stock flag. Mirage's item schema has no availability field, so
 * this drives ReCapture's own list filters and nothing on the public page.
 */
export const PRODUCT_AVAILABILITIES = ['IN_STOCK', 'OUT_OF_STOCK'] as const;
export type ProductAvailability = (typeof PRODUCT_AVAILABILITIES)[number];

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
  glbUrl?: string;
  usdzUrl?: string;
  thumbnailUrl?: string;
  imageKey?: string;
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
}
