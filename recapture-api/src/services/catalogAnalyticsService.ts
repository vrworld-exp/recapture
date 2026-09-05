// src/services/catalogAnalyticsService.ts
//
// The analytics dashboard: three scoped reads of Mirage's reports.
//
// NO NEW COLLECTION, AND NOTHING TO BACKFILL. Mirage's public catalog page has
// been emitting `session_start`, `client_page_view`, `product_page_view`,
// `product_detail_opened`, `model_loaded`, `model_load_failed`,
// `ar_view_clicked` and `ar_session_started` into `analyticsEventModel` all
// along, with a 365-day TTL. Features 61–65 are already COLLECTED; only the
// read surface was missing, and this file is it.
//
// WHY A PROXY AND NOT A REDIRECT. Mirage's three report endpoints are
// admin-scoped, and its own in-code note (analyticsRoutes.js:20-24) says they
// must not be opened to client scope by loosening `isAdmin` — the aggregations
// deliberately return cross-client panels (`byRestaurant`, `byDevice`,
// `topCategories`, `topZoomed`) that exist for the operator's dashboard. So
// ReCapture reads them with its own admin credential and FORCES the
// `restaurant` parameter from the caller's own mapping.
//
// ⚠ THE SCOPE IS NEVER CLIENT-SUPPLIED. A `restaurant` in the request is
// ignored — not validated, not echoed, ignored. Mirage's `buildMatch` omits the
// restaurant filter entirely when the parameter is empty
// (analyticsHelper.js:221-227), so a leaked-through empty value does not return
// nothing, it returns EVERY BUSINESS'S NUMBERS. That is the failure mode this
// module is shaped around.
import { Types } from 'mongoose';

import { Catalog } from '@/models/Catalog';
import { CatalogProduct } from '@/models/CatalogProduct';
import type { ProductType } from '@/models/types/catalog.types';
import {
  getMirageClient,
  isMirageConfigured,
  MirageError,
  type MirageAnalyticsQuery,
} from '@/services/mirage';

/** Mirage's own default and ceiling (analyticsHelper.js:183-184). */
export const ANALYTICS_DEFAULT_DAYS = 30;
export const ANALYTICS_MAX_DAYS = 365;
export const ANALYTICS_MAX_TOP_PRODUCTS = 100;

/** The one code the client renders as an empty state with a retry. */
export const ANALYTICS_UNAVAILABLE = 'ANALYTICS_UNAVAILABLE' as const;

export interface AnalyticsRange {
  /** `YYYY-MM-DD`, the form Mirage's parser expects. */
  from: string;
  to: string;
}

export interface AnalyticsKpisDto {
  pageViews: number;
  sessions: number;
  visitors: number;
  productViews: number;
  arViews: number;
  arSessions: number;
  contactClicks: number;
  searches: number;
}

export interface AnalyticsSummaryDto {
  range: { from: string; to: string; days: number };
  kpis: AnalyticsKpisDto;
  /** The immediately preceding window of equal length — the dashboard's delta. */
  previousKpis: AnalyticsKpisDto | null;
}

export interface AnalyticsTimeseriesPointDto {
  /**
   * `YYYY-MM-DD`, UTC. THE BOUNDARY RULE: Mirage stores `receivedAt` in UTC and
   * buckets on it with an explicit `timezone: "UTC"`
   * (analyticsController.js:399-401), so a "day" here is a UTC day, not the
   * business's local one. A shop closing at 1 a.m. sees that evening split
   * across two rows. Left as-is deliberately — inventing a local day on our side
   * would disagree with the range filter, which is also UTC, and produce totals
   * that do not add up to the summary's.
   */
  date: string;
  pageViews: number;
  productViews: number;
  arViews: number;
  sessions: number;
}

/** Feature 65: whether a row is a 3D product, an image-only one, or unmatched. */
export const TOP_PRODUCT_KINDS = ['3D', 'IMAGE_ONLY', 'UNKNOWN'] as const;
export type TopProductKind = (typeof TOP_PRODUCT_KINDS)[number];

export interface TopProductDto {
  /** The Mirage item id the public page reported. */
  productId: string;
  /** OUR product id where the row still maps to one. */
  catalogProductId: string | null;
  name: string;
  kind: TopProductKind;
  views: number;
  arViews: number;
  modelLoads: number;
  sessions: number;
}

export interface TopProductsDto {
  rows: TopProductDto[];
  /**
   * Per-type totals (feature 65). UNKNOWN rows are counted here as well as
   * returned — dropping them would make the totals disagree with the public
   * page's own numbers, and "we deleted the product but people still viewed it"
   * is real information.
   */
  totals: Record<TopProductKind, { views: number; arViews: number; products: number }>;
}

export type AnalyticsResult<T> =
  | { outcome: 'OK'; data: T }
  | { outcome: 'NOT_FOUND' }
  /** Never published, so there is nothing to report and no call to make. */
  | { outcome: 'EMPTY' }
  | { outcome: 'UNAVAILABLE'; code: typeof ANALYTICS_UNAVAILABLE };

// ── Range ───────────────────────────────────────────────────────────────────

const DAY_MS = 24 * 60 * 60 * 1000;

const dayString = (date: Date): string => date.toISOString().slice(0, 10);

export interface RangeInput {
  from?: string;
  to?: string;
}

/**
 * Resolves the requested window, defaulting and capping the same way Mirage
 * does.
 *
 * Doing it HERE as well as there is not redundancy: our cache key is built from
 * the resolved range, and a range Mirage silently narrows would otherwise give
 * two different cache entries the same key.
 */
export function resolveRange(input: RangeInput): AnalyticsRange {
  const to = input.to ? new Date(`${input.to}T00:00:00.000Z`) : new Date();
  const from = input.from
    ? new Date(`${input.from}T00:00:00.000Z`)
    : new Date(to.getTime() - ANALYTICS_DEFAULT_DAYS * DAY_MS);

  const span = to.getTime() - from.getTime();
  const capped =
    span > ANALYTICS_MAX_DAYS * DAY_MS ? new Date(to.getTime() - ANALYTICS_MAX_DAYS * DAY_MS) : from;

  return { from: dayString(capped), to: dayString(to) };
}

// ── Cache ───────────────────────────────────────────────────────────────────

/**
 * In-process, per (catalog, report, range), short TTL.
 *
 * NOT REDIS — that is a stack decision (AGENTS.md §0.4) and this is not the
 * feature to revisit it in. The point is narrower than a shared cache anyway:
 * Mirage runs on a tier that sleeps, its own report cache is five minutes, and
 * a dashboard that polls or that a user reloads twice should not wake it twice.
 * A second API instance keeping its own copy is fine; these are read-only
 * aggregates that are already minutes stale by construction.
 */
interface CacheEntry {
  at: number;
  value: unknown;
}

const cache = new Map<string, CacheEntry>();
const CACHE_TTL_MS = 60_000;
/** Bounded so a busy deployment cannot grow this map without limit. */
const CACHE_MAX_ENTRIES = 500;

function cached<T>(key: string): T | undefined {
  const entry = cache.get(key);
  if (!entry) return undefined;
  if (Date.now() - entry.at > CACHE_TTL_MS) {
    cache.delete(key);
    return undefined;
  }
  return entry.value as T;
}

function putCache(key: string, value: unknown): void {
  if (cache.size >= CACHE_MAX_ENTRIES) {
    // Oldest-inserted first; Map preserves insertion order.
    const oldest = cache.keys().next().value;
    if (oldest !== undefined) cache.delete(oldest);
  }
  cache.set(key, { at: Date.now(), value });
}

/** Test seam, and the thing to call if a report ever needs invalidating. */
export function clearAnalyticsCache(): void {
  cache.clear();
}

// ── Shared plumbing ─────────────────────────────────────────────────────────

/** The caller's Mirage restaurant id, or null when they have never published. */
async function scopeFor(
  userId: string
): Promise<{ outcome: 'OK'; catalogId: Types.ObjectId; restaurantId: string } | { outcome: 'NOT_FOUND' } | { outcome: 'EMPTY' }> {
  const catalog = await Catalog.findOne({ userId: new Types.ObjectId(userId), deletedAt: null })
    .select({ _id: 1, mirageRestaurantId: 1 })
    .lean()
    .exec();

  if (!catalog) return { outcome: 'NOT_FOUND' };
  if (!catalog.mirageRestaurantId) return { outcome: 'EMPTY' };
  return {
    outcome: 'OK',
    catalogId: catalog._id as Types.ObjectId,
    restaurantId: catalog.mirageRestaurantId,
  };
}

/**
 * Runs one report, translating Mirage's failures into ONE documented code.
 *
 * Mirage being asleep, rate-limited, or rejecting our credential must DEGRADE
 * the dashboard, not break it: the client renders an empty state with a retry.
 * A 500 would be the wrong shape — nothing the user did is wrong, and nothing
 * they can do fixes it.
 */
async function report<T>(
  key: string,
  run: (query: MirageAnalyticsQuery) => Promise<T>,
  query: MirageAnalyticsQuery
): Promise<{ outcome: 'OK'; data: T } | { outcome: 'UNAVAILABLE'; code: typeof ANALYTICS_UNAVAILABLE }> {
  const hit = cached<T>(key);
  if (hit !== undefined) return { outcome: 'OK', data: hit };

  try {
    const data = await run(query);
    putCache(key, data);
    return { outcome: 'OK', data };
  } catch (err) {
    if (!(err instanceof MirageError)) throw err;
    // The adapter has already spent its one token refresh on an auth failure,
    // so by here every class is equally "not right now".
    console.warn(`[catalog] analytics unavailable (${err.code})`);
    return { outcome: 'UNAVAILABLE', code: ANALYTICS_UNAVAILABLE };
  }
}

const cacheKey = (report: string, catalogId: Types.ObjectId, range: AnalyticsRange): string =>
  `${report}:${catalogId.toHexString()}:${range.from}:${range.to}`;

// ── Summary ─────────────────────────────────────────────────────────────────

const ZERO_KPIS: AnalyticsKpisDto = {
  pageViews: 0,
  sessions: 0,
  visitors: 0,
  productViews: 0,
  arViews: 0,
  arSessions: 0,
  contactClicks: 0,
  searches: 0,
};

/**
 * Field by field, and only the eight the dashboard shows.
 *
 * Mirage's summary also carries `byRestaurant`, `byDevice`, `topCategories` and
 * `topZoomed` — CROSS-CLIENT panels that exist for the operator's own dashboard.
 * A spread here would put every other business's numbers in one business's
 * response. That is not a hypothetical: those keys are in the same object, one
 * level down, and `MirageAnalyticsSummary` keeps them typed as `unknown`
 * precisely so nothing reads them by accident.
 */
function toKpis(raw: unknown): AnalyticsKpisDto {
  const value = (raw ?? {}) as Partial<Record<keyof AnalyticsKpisDto, unknown>>;
  const num = (key: keyof AnalyticsKpisDto): number =>
    typeof value[key] === 'number' && Number.isFinite(value[key]) ? (value[key] as number) : 0;
  return {
    pageViews: num('pageViews'),
    sessions: num('sessions'),
    visitors: num('visitors'),
    productViews: num('productViews'),
    arViews: num('arViews'),
    arSessions: num('arSessions'),
    contactClicks: num('contactClicks'),
    searches: num('searches'),
  };
}

export async function getCatalogAnalyticsSummary(
  userId: string,
  input: RangeInput
): Promise<AnalyticsResult<AnalyticsSummaryDto>> {
  const scope = await scopeFor(userId);
  if (scope.outcome !== 'OK') return scope;
  if (!isMirageConfigured()) return { outcome: 'UNAVAILABLE', code: ANALYTICS_UNAVAILABLE };

  const range = resolveRange(input);
  const result = await report(
    cacheKey('summary', scope.catalogId, range),
    (query) => getMirageClient().analyticsSummary(query),
    { restaurantId: scope.restaurantId, from: range.from, to: range.to }
  );
  if (result.outcome !== 'OK') return result;

  const days = Math.max(
    1,
    Math.round(
      (new Date(`${range.to}T00:00:00.000Z`).getTime() -
        new Date(`${range.from}T00:00:00.000Z`).getTime()) /
        DAY_MS
    )
  );

  return {
    outcome: 'OK',
    data: {
      range: { from: range.from, to: range.to, days },
      kpis: toKpis(result.data.kpis),
      previousKpis: result.data.previousKpis ? toKpis(result.data.previousKpis) : null,
    },
  };
}

// ── Timeseries ──────────────────────────────────────────────────────────────

export async function getCatalogAnalyticsTimeseries(
  userId: string,
  input: RangeInput
): Promise<AnalyticsResult<{ range: AnalyticsRange; points: AnalyticsTimeseriesPointDto[] }>> {
  const scope = await scopeFor(userId);
  if (scope.outcome !== 'OK') return scope;
  if (!isMirageConfigured()) return { outcome: 'UNAVAILABLE', code: ANALYTICS_UNAVAILABLE };

  const range = resolveRange(input);
  const result = await report(
    cacheKey('timeseries', scope.catalogId, range),
    (query) => getMirageClient().analyticsTimeseries(query),
    { restaurantId: scope.restaurantId, from: range.from, to: range.to }
  );
  if (result.outcome !== 'OK') return result;

  const num = (value: unknown): number =>
    typeof value === 'number' && Number.isFinite(value) ? value : 0;

  return {
    outcome: 'OK',
    data: {
      range,
      // Mirage already fills gaps so the chart draws a continuous axis
      // (analyticsController.js:428-445); we do not re-fill or re-sort.
      points: result.data.map((point) => ({
        date: String(point.date ?? ''),
        pageViews: num(point.pageViews),
        productViews: num(point.productViews),
        arViews: num(point.arViews),
        sessions: num(point.sessions),
      })),
    },
  };
}

// ── Top products ────────────────────────────────────────────────────────────

const KIND_FOR_TYPE: Record<ProductType, TopProductKind> = {
  THREE_D: '3D',
  IMAGE_ONLY: 'IMAGE_ONLY',
};

/**
 * Labels each row 3D / IMAGE_ONLY / UNKNOWN — feature 65.
 *
 * Mirage does not tag events by product type; it has no notion of one. The join
 * back through `CatalogProduct.mirageItemId` is the only place that knowledge
 * exists, which is exactly why this proxy adds value over exposing Mirage's
 * endpoint directly.
 *
 * ⚠ THE LOOKUP IS SCOPED TO THIS CATALOG. `mirageItemId` is globally unique in
 * Mirage, but querying it without the catalog filter would let another
 * business's product id resolve to a name from this user's catalog if the two
 * ever collided — and the index `{catalogId, ...}` makes the scoped query the
 * cheap one anyway.
 *
 * A row that no longer maps is UNKNOWN and is KEPT. Dropping it would make the
 * totals disagree with the public page's own, and "the product we deleted was
 * the most viewed one" is a thing a business wants to know.
 */
export async function getCatalogAnalyticsTopProducts(
  userId: string,
  input: RangeInput & { limit?: number }
): Promise<AnalyticsResult<{ range: AnalyticsRange } & TopProductsDto>> {
  const scope = await scopeFor(userId);
  if (scope.outcome !== 'OK') return scope;
  if (!isMirageConfigured()) return { outcome: 'UNAVAILABLE', code: ANALYTICS_UNAVAILABLE };

  const range = resolveRange(input);
  const limit = Math.min(ANALYTICS_MAX_TOP_PRODUCTS, Math.max(1, input.limit ?? 20));

  const result = await report(
    `${cacheKey('top-products', scope.catalogId, range)}:${limit}`,
    (query) => getMirageClient().analyticsTopProducts(query),
    { restaurantId: scope.restaurantId, from: range.from, to: range.to, limit }
  );
  if (result.outcome !== 'OK') return result;

  const mirageItemIds = result.data
    .map((row) => String(row.productId ?? ''))
    .filter((id) => id.length > 0);

  const products = mirageItemIds.length
    ? await CatalogProduct.find({
        catalogId: scope.catalogId,
        mirageItemId: { $in: mirageItemIds },
      })
        .select({ _id: 1, name: 1, type: 1, mirageItemId: 1 })
        .lean()
        .exec()
    : [];

  const byMirageId = new Map(products.map((product) => [product.mirageItemId as string, product]));

  const totals: TopProductsDto['totals'] = {
    '3D': { views: 0, arViews: 0, products: 0 },
    IMAGE_ONLY: { views: 0, arViews: 0, products: 0 },
    UNKNOWN: { views: 0, arViews: 0, products: 0 },
  };

  const num = (value: unknown): number =>
    typeof value === 'number' && Number.isFinite(value) ? value : 0;

  const rows: TopProductDto[] = result.data.map((row) => {
    const productId = String(row.productId ?? '');
    const local = byMirageId.get(productId);
    const kind: TopProductKind = local ? KIND_FOR_TYPE[local.type] : 'UNKNOWN';
    const views = num(row.views);
    const arViews = num(row.arViews);

    totals[kind].views += views;
    totals[kind].arViews += arViews;
    totals[kind].products += 1;

    return {
      productId,
      catalogProductId: local ? String(local._id) : null,
      // OUR name wins where we have one: Mirage's is whatever the public page
      // reported at event time, which is the name as it was then.
      name: local?.name ?? String(row.name ?? 'Unknown product'),
      kind,
      views,
      arViews,
      modelLoads: num(row.modelLoads),
      sessions: num(row.sessions),
    };
  });

  return { outcome: 'OK', data: { range, rows, totals } };
}

/** The empty payloads an unprovisioned catalog gets, with no Mirage call. */
export const EMPTY_SUMMARY = (range: AnalyticsRange): AnalyticsSummaryDto => ({
  range: { from: range.from, to: range.to, days: 0 },
  kpis: ZERO_KPIS,
  previousKpis: null,
});
