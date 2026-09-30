// src/services/insights/rules.ts
//
// The weekly report's "tips" (more-customization Stage 9, Part B). Each rule is
// a PURE function of an already-gathered context — no database, no Mirage, no
// clock except `ctx.now` — so every rule is testable with a literal and the
// report builder owns all the I/O.
//
// A rule returns at most ONE tip, about the single worst case it found; the
// report shows two tips in total, and three tips about three dishes from the
// same rule would crowd out everything else. `pickTips` ranks by priority.
//
// Wording rule: a tip names a real dish and a real number, and it is phrased as
// something the owner can do this week. A tip the owner cannot act on is noise
// and teaches them to stop reading.
import type { ProductAvailability, ProductType } from '@/models/types/catalog.types';
import type { WeeklyReportTip } from '@/models/types/weeklyReport.types';

/** One of OUR products, as the rules need it. */
export interface InsightProduct {
  id: string;
  name: string;
  type: ProductType;
  hasPhoto: boolean;
  hasDescription: boolean;
  availability: ProductAvailability;
}

/** A dish's week, joined to OUR product where it still maps to one. */
export interface InsightDishStats {
  /** OUR product id; rows that no longer map are dropped before the rules run. */
  productId: string;
  views: number;
  impressions: number;
  opens: number;
  arViews: number;
}

export interface InsightContext {
  now: Date;
  /** By OUR product id. */
  products: Map<string, InsightProduct>;
  /** Most-viewed first, at most ten. */
  topDishes: InsightDishStats[];
  /** Every dish Mirage reported a card impression, open or AR view for. */
  funnel: InsightDishStats[];
  searches: { query: string; zeroResults: number }[];
  draftRevision: number;
  publishedRevision: number;
  lastPublishedAt: Date | null;
}

export type InsightRule = (ctx: InsightContext) => WeeklyReportTip | null;

// ── Thresholds ──────────────────────────────────────────────────────────────
// Named so the tests can read them and so tuning one is one edit.

/** HIGH_VIEW_LOW_OPEN: a card has to have been seen this often to judge it. */
export const LOW_OPEN_MIN_IMPRESSIONS = 50;
/** …and opened by fewer than this share of the people who saw it. */
export const LOW_OPEN_RATE = 0.05;
/** AR_OUTPERFORMS: at least this many dishes of each kind with activity. */
export const AR_COMPARE_MIN_DISHES = 3;
/** …and the 3D dishes' average opens must be at least this, so 2× means something. */
export const AR_COMPARE_MIN_AVG_OPENS = 5;
export const AR_OUTPERFORM_FACTOR = 2;
/** SOLD_OUT_VIEWED: opened MORE than this many times while marked out of stock. */
export const SOLD_OUT_MIN_OPENS = 20;
/** SEARCH_NO_RESULT: searches that matched nothing, at least this often. */
export const SEARCH_MIN_ZERO_RESULTS = 5;
/** DRAFT_NOT_PUBLISHED: unpublished changes older than this. */
export const DRAFT_STALE_DAYS = 3;

const DAY_MS = 86_400_000;

/** Dish names in tips are quoted and clipped, so one long name cannot swallow the message. */
function dish(name: string): string {
  const clean = name.trim();
  return clean.length <= 40 ? clean : `${clean.slice(0, 39)}…`;
}

// ── The rules ───────────────────────────────────────────────────────────────

export const noPhotoPopular: InsightRule = (ctx) => {
  for (const row of ctx.topDishes.slice(0, 10)) {
    const product = ctx.products.get(row.productId);
    if (product && !product.hasPhoto) {
      return {
        id: 'NO_PHOTO_POPULAR',
        priority: 90,
        text: `“${dish(product.name)}” is popular but has no photo — add one.`,
        action: 'PRODUCT',
        productId: product.id,
      };
    }
  }
  return null;
};

export const soldOutViewed: InsightRule = (ctx) => {
  let worst: { product: InsightProduct; opens: number } | null = null;
  for (const row of ctx.funnel) {
    const product = ctx.products.get(row.productId);
    if (!product || product.availability !== 'OUT_OF_STOCK') continue;
    if (row.opens <= SOLD_OUT_MIN_OPENS) continue;
    if (!worst || row.opens > worst.opens) worst = { product, opens: row.opens };
  }
  if (!worst) return null;
  return {
    id: 'SOLD_OUT_VIEWED',
    priority: 80,
    text: `“${dish(worst.product.name)}” was sold out but ${worst.opens} people looked at it.`,
    action: 'PRODUCT',
    productId: worst.product.id,
  };
};

export const highViewLowOpen: InsightRule = (ctx) => {
  let worst: { product: InsightProduct; impressions: number } | null = null;
  for (const row of ctx.funnel) {
    if (row.impressions < LOW_OPEN_MIN_IMPRESSIONS) continue;
    if (row.opens / row.impressions >= LOW_OPEN_RATE) continue;
    const product = ctx.products.get(row.productId);
    if (!product) continue;
    if (!worst || row.impressions > worst.impressions) {
      worst = { product, impressions: row.impressions };
    }
  }
  if (!worst) return null;
  return {
    id: 'HIGH_VIEW_LOW_OPEN',
    priority: 70,
    text: `Many people scroll past “${dish(worst.product.name)}”. Try a better photo or price.`,
    action: 'PRODUCT',
    productId: worst.product.id,
  };
};

export const searchNoResult: InsightRule = (ctx) => {
  const worst = ctx.searches
    .filter((s) => s.query.trim().length > 0 && s.zeroResults >= SEARCH_MIN_ZERO_RESULTS)
    .sort((a, b) => b.zeroResults - a.zeroResults)[0];
  if (!worst) return null;
  return {
    id: 'SEARCH_NO_RESULT',
    priority: 65,
    text: `Customers searched “${dish(worst.query)}” and found nothing.`,
    action: 'ADD_PRODUCT',
  };
};

/**
 * "Your 3D dishes get N× more attention" — average detail opens per dish, 3D
 * against photo-only, over the dishes that had any activity this week. The
 * suggested dish is the photo-only dish people opened most: it is the one a
 * model would do most for.
 */
export const arOutperforms: InsightRule = (ctx) => {
  const threeD: number[] = [];
  const photo: { product: InsightProduct; opens: number }[] = [];
  for (const row of ctx.funnel) {
    const product = ctx.products.get(row.productId);
    if (!product) continue;
    if (product.type === 'THREE_D') threeD.push(row.opens);
    else photo.push({ product, opens: row.opens });
  }
  if (threeD.length < AR_COMPARE_MIN_DISHES || photo.length < AR_COMPARE_MIN_DISHES) return null;

  const avg3D = threeD.reduce((a, b) => a + b, 0) / threeD.length;
  const avgPhoto = photo.reduce((a, b) => a + b.opens, 0) / photo.length;
  if (avg3D < AR_COMPARE_MIN_AVG_OPENS) return null;
  // A photo average of zero makes any 3D number "infinitely better" — true, but
  // not a sentence to print. Treat it as 1 open per dish.
  const factor = avg3D / Math.max(avgPhoto, 1);
  if (factor < AR_OUTPERFORM_FACTOR) return null;

  const best = photo.sort((a, b) => b.opens - a.opens)[0];
  const n = Math.round(factor * 10) / 10;
  return {
    id: 'AR_OUTPERFORMS',
    priority: 60,
    text: `Your 3D dishes get ${n}× more attention. Add 3D to “${dish(best.product.name)}”?`,
    action: 'MODEL_GENERATION',
    productId: best.product.id,
  };
};

export const noDescription: InsightRule = (ctx) => {
  const top = ctx.topDishes.slice(0, 3);
  for (let i = 0; i < top.length; i += 1) {
    const product = ctx.products.get(top[i].productId);
    if (product && !product.hasDescription) {
      return {
        id: 'NO_DESCRIPTION',
        priority: 50,
        text: `Add a description to “${dish(product.name)}” — it's your #${i + 1} dish.`,
        action: 'PRODUCT',
        productId: product.id,
      };
    }
  }
  return null;
};

/**
 * "You have unpublished changes." There is no stored "draft since" instant, so
 * the age is measured from the LAST PUBLISH: changes pending on a catalog last
 * published more than three days ago have waited at least that long or were
 * made since — either way the menu customers see is three days behind.
 */
export const draftNotPublished: InsightRule = (ctx) => {
  if (ctx.draftRevision <= ctx.publishedRevision) return null;
  if (!ctx.lastPublishedAt) return null;
  if (ctx.now.getTime() - ctx.lastPublishedAt.getTime() < DRAFT_STALE_DAYS * DAY_MS) return null;
  return {
    id: 'DRAFT_NOT_PUBLISHED',
    priority: 40,
    text: 'You have unpublished changes — customers still see the old menu.',
    action: 'PUBLISH',
  };
};

export const INSIGHT_RULES: readonly InsightRule[] = [
  noPhotoPopular,
  soldOutViewed,
  highViewLowOpen,
  searchNoResult,
  arOutperforms,
  noDescription,
  draftNotPublished,
];

/** How many tips a report carries. */
export const MAX_TIPS = 2;

/** Every rule, highest priority first, the top {@link MAX_TIPS}. */
export function pickTips(
  ctx: InsightContext,
  rules: readonly InsightRule[] = INSIGHT_RULES
): WeeklyReportTip[] {
  return rules
    .map((rule) => rule(ctx))
    .filter((tip): tip is WeeklyReportTip => tip !== null)
    .sort((a, b) => b.priority - a.priority)
    .slice(0, MAX_TIPS);
}
