// src/services/mirage/mirageTypes.ts
//
// The Mirage API's shapes, normalized for our side of the seam.
//
// ⚠ RE-VERIFIED against `mirage-be-phase-2-recap` — Mirage has been extended
// since this file was first written, and the previous version's "Mirage ignores
// this" notes were WRONG. Every claim below now cites a line in
// mirage-be-phase-2-recap/src/, and citations are to be re-checked, not
// trusted, whenever Mirage changes. What actually moved:
//
//   • update-item now APPLIES `description` and `category`
//     (adminController.js:1460-1490) and re-derives `imgOnly` from what the
//     document holds (adminController.js:1500-1503). A category move is
//     therefore an UPDATE — no more delete-and-recreate, so the Mirage item id
//     and its analytics history survive a re-filing.
//   • update-restaurant is a PARTIAL update; `name` and `location` are no
//     longer both mandatory (adminController.js:378-404).
//   • The item schema gained `tags`, `availability`, `featured` and
//     `sortPosition` (itemModel.js:174-206); the category gained `sortPosition`
//     (categoryModel.js:66-70); the restaurant gained `website`, `socialLinks`,
//     `address` and `isPublished` (restaurantModel.js:75-113).
//   • multer accepts a THIRD file field, `objectIos`, and both item handlers
//     write `model.iosSrc` from it (multer.js:15-19, adminController.js:1102-
//     1142). iOS AR Quick Look on a published product is now possible.
//   • delete-item takes `?keepCategory=true` to opt OUT of the last-item
//     category cascade, and reports `deletedCategory` in its response body
//     (adminController.js:1651-1690).
//
// Two rules still hold everywhere below:
//   • Mirage's `_id` becomes `id`, exactly as our own DTOs do. No `_id` or
//     `__v` crosses this boundary.
//   • Mirage's envelope (`{status: boolean, message, data}`) does NOT appear in
//     any type here. A BOOLEAN `status` reaching a ReCapture response body would
//     be a contract violation.
//
// Field-by-field normalizers, never a spread: Mirage's documents carry fields we
// have no business copying forward (`orderBelong`, `expiry`, `views`, the
// denormalised `restaurantSlug`), and a spread is how one of them ends up in a
// ReCapture response the next time Mirage's schema grows.

/**
 * A file uploaded to Mirage as one multipart part.
 *
 * TWO SHAPES, and the distinction is about MEMORY, not about convenience.
 *
 * Mirage accepts BYTES ONLY. Neither create-item nor update-item reads a URL
 * field: create-item spreads the body but overwrites `image` and `model` with
 * values computed from `req.files` (adminController.js:1163-1177), and
 * update-item only assigns from an uploaded file (adminController.js:1478-1492).
 * It buffers each part to local disk and `readFileSync`s it (libs/s3.js), so
 * there is nothing on its side to stream INTO — but there is everything to gain
 * from not buffering on OURS. A 90 MiB GLB held in this process while another
 * request holds a second one is how a 512 MB Render instance dies.
 *
 * So: `bytes` for things that are small by construction (a logo, a thumbnail),
 * `stream` for anything model-sized. The client encodes the multipart body
 * itself and pipes the stream through it without ever concatenating it.
 */
export interface MirageBytesUpload {
  kind: 'bytes';
  filename: string;
  contentType: string;
  /** The whole file in memory. Only for assets bounded to a few hundred KB. */
  bytes: Buffer;
}

export interface MirageStreamUpload {
  kind: 'stream';
  filename: string;
  contentType: string;
  /**
   * Exact byte length. REQUIRED — it is what lets the client send a real
   * Content-Length instead of chunked encoding, and it is the number the
   * caller's preflight already had to fetch to enforce MIRAGE_MAX_ASSET_BYTES.
   */
  size: number;
  /**
   * Opens a FRESH stream. Called once per attempt; a retried request calls it
   * again, because a consumed stream cannot be replayed.
   */
  open: () => NodeJS.ReadableStream;
}

export type MirageFileUpload = MirageBytesUpload | MirageStreamUpload;

/** Convenience constructor for the small-file case. */
export function bytesUpload(
  filename: string,
  contentType: string,
  bytes: Buffer
): MirageBytesUpload {
  return { kind: 'bytes', filename, contentType, bytes };
}

/**
 * ⚠ NOT SUPPORTED BY MIRAGE TODAY — see MIRAGE_ASSET_TRANSFER_MODE.
 *
 * Mirage prompt M1 proposes letting create-item/update-item take a URL and
 * fetch the object server-side, which would turn a 90 MiB round trip through
 * this process into a message. The fields are declared (and sent) so the moment
 * M1 lands the flag flips with no code change; until then the current handlers
 * ignore them, which is exactly why `bytes` is the default mode.
 */
export interface MirageAssetUrls {
  imageUrl?: string;
  objectUrl?: string;
  objectIosUrl?: string;
}

/** The multipart file field names Mirage's multer accepts (multer.js:15-19). */
export type MirageFileField = 'image' | 'object' | 'objectIos';

/**
 * restaurantModel.js:82-91. `x` and `linkedin` have no ReCapture equivalent.
 *
 * A type ALIAS, not an interface, on purpose: TypeScript gives object literal
 * types an implicit index signature but withholds it from interfaces, and the
 * client serialises this block by iterating it as a
 * `Record<string, string | undefined>`. Declared as an interface it would not
 * type-check there, for a reason nobody reading the call site could guess.
 */
export type MirageSocialLinks = {
  instagram?: string;
  facebook?: string;
  x?: string;
  youtube?: string;
  linkedin?: string;
  whatsapp?: string;
};

/**
 * restaurantModel.js:95-102.
 *
 * NOTE this does NOT replace the free-text `location`: Mirage writes both
 * independently and its own comment says so. ReCapture stores one address
 * string, so `location` stays authoritative and this block is optional.
 *
 * A type alias rather than an interface for the same serialisation reason as
 * {@link MirageSocialLinks}.
 */
export type MirageAddress = {
  line1?: string;
  line2?: string;
  city?: string;
  state?: string;
  postalCode?: string;
  country?: string;
};

/** itemModel.js:191-195. Mirage upper-cases and validates against this set. */
export const MIRAGE_AVAILABILITIES = ['IN_STOCK', 'OUT_OF_STOCK'] as const;
export type MirageAvailability = (typeof MIRAGE_AVAILABILITIES)[number];

/**
 * A Mirage restaurant — one business's catalog container, and the entity whose
 * immutable `_id` the public URL and every printed QR are built from.
 */
export interface MirageRestaurant {
  id: string;
  name: string;
  location: string;
  /** CDN URL of the restaurant icon, or Mirage's stock placeholder. */
  icon?: string;
  phone?: string;
  /** Now writable on BOTH create and update (adminController.js:318, 523). */
  description?: string;
  website?: string;
  socialLinks?: MirageSocialLinks;
  address?: MirageAddress;
  /**
   * The soft on/off switch for the public page (restaurantModel.js:108-113).
   * THIS is what makes unpublish possible without `delete-restaurant`, which
   * would destroy the `_id` every printed QR encodes. Defaults to true, and the
   * read paths treat only an explicit `false` as unpublished.
   */
  isPublished?: boolean;
  clientType?: string;
  categoryIds: string[];
}

export interface MirageCategory {
  id: string;
  /** ⚠ Stored LOWERCASED with spaces underscored (adminController.js:737-738). */
  name: string;
  restaurantId?: string;
  image?: string;
  sortPosition?: number;
  productIds: string[];
}

export interface MirageItem {
  id: string;
  name: string;
  description?: string;
  price?: number;
  /** CDN URL of the product photo, or Mirage's stock placeholder. */
  image?: string;
  /** CDN URL of the GLB. */
  modelSrc?: string;
  /** CDN URL of the USDZ. Populated from the `objectIos` file field. */
  modelIosSrc?: string;
  categoryId?: string;
  restaurantId?: string;
  /**
   * DERIVED by Mirage on every write — `Boolean(image) && !model.src` — never
   * taken from the caller (adminController.js:1194, 1500-1503). Pushing a model
   * onto an image-only product therefore flips it automatically; there is
   * nothing for us to send.
   */
  imgOnly?: boolean;
  tags?: string[];
  availability?: MirageAvailability;
  featured?: boolean;
  sortPosition?: number;
}

// ── Write inputs ────────────────────────────────────────────────────────────
// `CLOUD_FRONT_URL` and `BUCKET_NAME` are deliberately NOT part of any input
// below: the client injects them into every write body from config, because
// Mirage reads them from the request body and an omitted value silently stores
// a customer-facing URL beginning with the string "undefined".
//
// Arrays, booleans, numbers and nested objects all arrive at Mirage as multipart
// STRINGS and are coerced by helper.js's parse*Field functions. The client
// serialises them; callers pass real types.

export interface CreateRestaurantInput {
  name: string;
  /** Mirage 400s unless this is a string — send `''`, never undefined. */
  location: string;
  /** Digits only. Mirage prefixes `+91` itself (adminController.js:291-293). */
  phoneNo?: string;
  description?: string;
  website?: string;
  socialLinks?: MirageSocialLinks;
  address?: MirageAddress;
  isPublished?: boolean;
  image?: MirageFileUpload;
}

/**
 * A PARTIAL update (adminController.js:378-404) — every field is optional and an
 * omitted one is left alone. This is what makes `{ isPublished: false }` a legal
 * call on its own, which feature 39's unpublish depends on.
 *
 * ⚠ `socialLinks` and `address` MERGE key by key (adminController.js:530-543):
 * sending only `{ instagram }` does not wipe `facebook`. There is consequently
 * no way to clear one of those keys except by sending it as `''`.
 */
export interface UpdateRestaurantInput {
  name?: string;
  location?: string;
  phoneNo?: string;
  description?: string;
  website?: string;
  socialLinks?: MirageSocialLinks;
  address?: MirageAddress;
  isPublished?: boolean;
  image?: MirageFileUpload;
}

export interface CreateCategoryInput {
  /**
   * ⚠ SEND IT ALREADY NORMALIZED (lowercase, spaces → underscores).
   *
   * Mirage's duplicate check compares the RAW input against stored names
   * (adminController.js:723-731) but normalizes only afterwards
   * (adminController.js:737-738). So posting "Chairs" against a stored "chairs"
   * passes the check and creates a SECOND "chairs" category. Normalising on our
   * side is what makes the check actually fire.
   */
  name: string;
  /** Mirage restaurant id — must be a valid ObjectId or Mirage 400s. */
  restaurantId: string;
  /** categoryModel.js:66-70. Lower sorts first; everything defaults to 0. */
  sortPosition?: number;
  image?: MirageFileUpload;
}

/** `name` is optional now — a reorder-only update is legal (adminController.js:836-840). */
export interface UpdateCategoryInput {
  /** Same normalization warning as CreateCategoryInput. */
  name?: string;
  sortPosition?: number;
  image?: MirageFileUpload;
}

export interface CreateItemInput {
  name: string;
  /** Mirage category id. REQUIRED — there is no uncategorized affordance. */
  categoryId: string;
  restaurantId: string;
  /** Dropped by Mirage when falsy or ≤ 0 — a free product has no price field. */
  price?: number;
  description?: string;
  isNonVeg?: boolean;
  tags?: string[];
  availability?: MirageAvailability;
  featured?: boolean;
  sortPosition?: number;
  /** The product photo. At least one of `image`/`object` is required. */
  image?: MirageFileUpload;
  /** The GLB. */
  object?: MirageFileUpload;
  /** The USDZ twin, written to `model.iosSrc`. */
  objectIos?: MirageFileUpload;
  /** URL transfer mode only (M1). Ignored by the current Mirage handlers. */
  assetUrls?: MirageAssetUrls;
}

/**
 * Everything here is applied by the current handler — verified line by line
 * against adminController.js:1460-1503.
 *
 * ⚠ ALWAYS SEND `name`, even when it has not changed. Mirage builds the S3 key
 * for an uploaded file as `${slug}/imgs/${Date.now()}-${name}.${ext}`
 * (adminController.js:1420-1423) using the REQUEST's `name`, so an upload
 * without one stores an object literally called `…-undefined.jpg`.
 *
 * ⚠ `price` is applied only when truthy (`if (price && …)`), so an item's price
 * cannot be cleared or set to 0 through this endpoint.
 *
 * ⚠ `categoryId` must belong to the item's own restaurant or Mirage 400s
 * (adminController.js:1470-1476).
 */
export interface UpdateItemInput {
  name?: string;
  price?: number;
  description?: string;
  /** A real category move — Mirage repoints both back-references. */
  categoryId?: string;
  isNonVeg?: boolean;
  tags?: string[];
  availability?: MirageAvailability;
  featured?: boolean;
  sortPosition?: number;
  image?: MirageFileUpload;
  object?: MirageFileUpload;
  objectIos?: MirageFileUpload;
  /** URL transfer mode only (M1). Ignored by the current Mirage handlers. */
  assetUrls?: MirageAssetUrls;
}

/** What one delete-item call did. */
export interface DeleteItemResult {
  /** False when the item was already gone — a replayed delete is a success. */
  existed: boolean;
  /**
   * Mirage removed the item's CATEGORY too, because this was its last item
   * (adminController.js:1660-1672). The caller must clear its cached
   * `mirageCategoryId` or the next create-item lands on a dead id.
   */
  deletedCategory: boolean;
}

export interface DeleteItemOptions {
  /**
   * Opt OUT of the last-item category cascade (`?keepCategory=true`,
   * adminController.js:1655-1656). Publishing wants this ON: a category that
   * vanishes because a product was archived is a destructive side effect of an
   * unrelated edit, and re-creating it costs another round trip and a new id.
   */
  keepCategory?: boolean;
}

// ── Public read (M14) ───────────────────────────────────────────────────────

/** What the public catalog page itself fetches — used for post-publish verification. */
export interface MiragePublicCatalog {
  restaurant: {
    id: string;
    name: string;
    location?: string;
    phone?: string;
    icon?: string;
    description?: string;
    clientType?: string;
    isPublished?: boolean;
  };
  categories: MirageCategory[];
  items: MirageItem[];
}

// ── Analytics reads (M27–M29) ───────────────────────────────────────────────
// These routes are ADMIN-SCOPED and Mirage's own in-code note forbids opening
// them to client scope (analyticsRoutes.js:20-24). Every call from ReCapture
// therefore carries a server-forced `restaurant` id; a client-supplied one is
// never passed through.

export interface MirageAnalyticsRange {
  /** ISO instants. */
  from: string;
  to: string;
  days?: number;
}

export interface MirageAnalyticsKpis {
  pageViews: number;
  sessions: number;
  visitors: number;
  productViews: number;
  arViews: number;
  arSessions: number;
  contactClicks: number;
  searches: number;
}

/**
 * Mirage's summary payload. Indexed because the aggregation returns several
 * cross-client panels (`byRestaurant`, `byDevice`, `topCategories`, `topZoomed`)
 * that a per-business dashboard must NOT surface — they are kept `unknown` so
 * nothing reads them by accident.
 */
export interface MirageAnalyticsSummary {
  range: MirageAnalyticsRange;
  kpis: MirageAnalyticsKpis;
  previousKpis?: MirageAnalyticsKpis;
  [key: string]: unknown;
}

export interface MirageTimeseriesPoint {
  /** `YYYY-MM-DD`, UTC. Gaps are already filled by Mirage. */
  date: string;
  pageViews: number;
  productViews: number;
  arViews: number;
  sessions: number;
}

export interface MirageTopProductRow {
  /** The value the public page put in `props.productId`. */
  productId: string;
  name: string;
  views: number;
  arViews: number;
  modelLoads: number;
  sessions: number;
}

export interface MirageAnalyticsQuery {
  /** Mirage restaurant id — always supplied by the server, never by a client. */
  restaurantId: string;
  from?: string;
  to?: string;
  days?: number;
  /** top-products only. Mirage clamps to 100. */
  limit?: number;
}
