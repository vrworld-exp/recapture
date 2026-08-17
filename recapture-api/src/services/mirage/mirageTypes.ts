// src/services/mirage/mirageTypes.ts
//
// The Mirage API's shapes, normalized for our side of the seam.
//
// Two rules hold everywhere below:
//   • Mirage's `_id` becomes `id`, exactly as our own DTOs do. No `_id` or
//     `__v` crosses this boundary.
//   • Mirage's envelope (`{status: boolean, message, data}`) does NOT appear in
//     any type here. A BOOLEAN `status` reaching a ReCapture response body would
//     be a contract violation; the client unwraps it and throws on failure.
//
// Field-by-field normalizers, never a spread: Mirage's documents carry fields we
// have no business copying forward (`orderBelong`, `expiry`, `views`, the
// denormalised `restaurantSlug`), and a spread is how one of them ends up in a
// ReCapture response the next time Mirage's schema grows.

/** A file uploaded to Mirage as multipart bytes. */
export interface MirageFileUpload {
  filename: string;
  contentType: string;
  /**
   * The whole file in memory.
   *
   * Mirage accepts BYTES ONLY — there is no presigned flow and no way to hand
   * it a URL (createItems overwrites any caller-supplied `image`/`model` with
   * its own computed values, adminController.js:948-955). It then buffers the
   * upload to local disk and `readFileSync`s it (libs/s3.js), so streaming
   * would buy nothing on its side. Our own ceiling is MIRAGE_MAX_ASSET_BYTES
   * (90 MiB), enforced by the caller's preflight before the bytes are ever read.
   */
  bytes: Buffer;
}

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
  /**
   * Present on reads, but NO write endpoint accepts it: neither create- nor
   * update-restaurant destructures `description` from the body
   * (adminController.js:196-202, 305-312). A business description authored in
   * ReCapture therefore cannot reach the public page.
   */
  description?: string;
  clientType?: string;
  categoryIds: string[];
}

export interface MirageCategory {
  id: string;
  name: string;
  restaurantId?: string;
  image?: string;
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
  /**
   * Present in Mirage's schema and ALWAYS empty in practice: multer accepts only
   * the `image` and `object` fields (libs/multer.js) and no controller ever
   * writes `model.iosSrc`. iOS AR Quick Look cannot be served from a published
   * product today.
   */
  modelIosSrc?: string;
  categoryId?: string;
  restaurantId?: string;
  imgOnly?: boolean;
}

// ── Write inputs ────────────────────────────────────────────────────────────
// `CLOUD_FRONT_URL` and `BUCKET_NAME` are deliberately NOT part of any input
// below: the client injects them into every write body from config, because
// Mirage reads them from the request body and an omitted value silently stores
// a customer-facing URL beginning with the string "undefined".

export interface CreateRestaurantInput {
  name: string;
  /** Mirage 400s unless this is a string — send `''`, never undefined. */
  location: string;
  /** Digits only. Mirage prefixes `+91` itself (adminController.js:224). */
  phoneNo?: string;
  image?: MirageFileUpload;
}

export interface UpdateRestaurantInput {
  /** Both `name` and `location` are REQUIRED strings even for a partial edit:
   * update-restaurant 400s when either is not a string (adminController.js:304-318). */
  name: string;
  location: string;
  phoneNo?: string;
  image?: MirageFileUpload;
}

export interface CreateCategoryInput {
  /** Mirage lowercases it and replaces spaces with underscores. */
  name: string;
  /** Mirage restaurant id — must be a valid ObjectId or Mirage 400s. */
  restaurantId: string;
  image?: MirageFileUpload;
}

export interface UpdateCategoryInput {
  name: string;
  image?: MirageFileUpload;
}

export interface CreateItemInput {
  name: string;
  /** Mirage category id. REQUIRED — there is no uncategorized affordance. */
  categoryId: string;
  restaurantId: string;
  /** Dropped by Mirage when falsy or ≤ 0 — a free product has no price field. */
  price?: number;
  /** Applied on CREATE only (the body is spread into the document). */
  description?: string;
  isNonVeg?: boolean;
  /** The product photo. At least one of `image`/`object` is required. */
  image?: MirageFileUpload;
  /** The GLB. */
  object?: MirageFileUpload;
}

export interface UpdateItemInput {
  name?: string;
  price?: number;
  isNonVeg?: boolean;
  image?: MirageFileUpload;
  object?: MirageFileUpload;
  // NOTE there is deliberately no `description`, `categoryId` or `imgOnly`
  // here. update-item destructures them and never assigns them
  // (adminController.js:1038-1047), so accepting them would be a lie: the app
  // would report success and the public page would not change. Those edits are
  // handled by the planner as DELETE + CREATE instead.
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
