// tests/weekly-report.test.ts
//
// more-customization Stage 9 — the weekly value report.
//
//   • IST week boundaries and the Monday 09:30 send gate.
//   • The delta is suppressed below 20 previous-week views.
//   • Every insight rule, true and false; pickTips keeps the top two.
//   • deliverWeeklyReport is idempotent: run twice → one report, one
//     notification. Opted-out and quiet weeks behave as documented.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach } from 'vitest';
import mongoose, { Types } from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { Catalog } from '@/models/Catalog';
import { CatalogProduct } from '@/models/CatalogProduct';
import { Notification } from '@/models/Notification';
import { WeeklyReport } from '@/models/WeeklyReport';
import {
  arOutperforms,
  draftNotPublished,
  highViewLowOpen,
  noDescription,
  noPhotoPopular,
  pickTips,
  searchNoResult,
  soldOutViewed,
  type InsightContext,
  type InsightProduct,
} from '@/services/insights/rules';
import { resetMirageClient, setMirageClient, type MirageAnalyticsQuery } from '@/services/mirage';
import {
  deltaPct,
  deliverWeeklyReport,
  formatSlot,
  formatWeekLabel,
  isReportSendTime,
  lastCompletedWeekStart,
} from '@/services/weeklyReportService';
import { FakeMirage } from './fixtures/mirageFake';

// ── Week arithmetic ─────────────────────────────────────────────────────────

describe('week boundaries (Asia/Kolkata)', () => {
  it('at 01:00 IST on Monday 28 Sep the last complete week is 21–27 Sep', () => {
    // 01:00 IST = 19:30 UTC the previous day — still Sunday in UTC.
    expect(lastCompletedWeekStart(new Date('2026-09-27T19:30:00Z'))).toBe('2026-09-21');
  });

  it('at 23:00 IST on Sunday 27 Sep the week 21–27 is not over yet', () => {
    expect(lastCompletedWeekStart(new Date('2026-09-27T17:30:00Z'))).toBe('2026-09-14');
  });

  it('sends from Monday 09:30 IST, never before', () => {
    // 09:29 IST = 03:59 UTC; 09:30 IST = 04:00 UTC.
    expect(isReportSendTime(new Date('2026-09-28T03:59:00Z'))).toBe(false);
    expect(isReportSendTime(new Date('2026-09-28T04:00:00Z'))).toBe(true);
    // Tuesday: a worker that slept through Monday still sends (late, never early).
    expect(isReportSendTime(new Date('2026-09-29T01:00:00Z'))).toBe(true);
  });

  it('labels the week the way the notification prints it', () => {
    expect(formatWeekLabel('2026-09-21')).toMatch(/^21–27 Sept?$/);
    expect(formatWeekLabel('2026-09-29')).toMatch(/^29 Sept? – 5 Oct$/);
    expect(formatSlot(5, 20)).toBe('Saturday 8–9 pm');
    expect(formatSlot(0, 11)).toBe('Monday 11 am–12 pm');
  });
});

describe('deltaPct', () => {
  it('is null below 20 previous-week views', () => {
    expect(deltaPct(400, 19)).toBeNull();
    expect(deltaPct(400, null)).toBeNull();
  });

  it('is a one-decimal percent at or above it', () => {
    expect(deltaPct(24, 20)).toBe(20);
    expect(deltaPct(1240, 1051)).toBe(18);
    expect(deltaPct(10, 40)).toBe(-75);
  });
});

// ── Insight rules ───────────────────────────────────────────────────────────

const product = (id: string, over: Partial<InsightProduct> = {}): InsightProduct => ({
  id,
  name: `Dish ${id}`,
  type: 'IMAGE_ONLY',
  hasPhoto: true,
  hasDescription: true,
  availability: 'IN_STOCK',
  ...over,
});

const stats = (
  productId: string,
  over: Partial<{ views: number; impressions: number; opens: number; arViews: number }> = {}
) => ({
  productId,
  views: 0,
  impressions: 0,
  opens: 0,
  arViews: 0,
  ...over,
});

function ctx(over: Partial<InsightContext> = {}): InsightContext {
  return {
    now: new Date('2026-09-28T04:00:00Z'),
    products: new Map(),
    topDishes: [],
    funnel: [],
    searches: [],
    draftRevision: 1,
    publishedRevision: 1,
    lastPublishedAt: new Date('2026-09-27T00:00:00Z'),
    ...over,
  };
}

const withProducts = (...list: InsightProduct[]) => new Map(list.map((p) => [p.id, p]));

describe('insight rules', () => {
  it('NO_PHOTO_POPULAR: a top dish without a photo', () => {
    const products = withProducts(product('a'), product('b', { hasPhoto: false }));
    const tip = noPhotoPopular(ctx({ products, topDishes: [stats('a'), stats('b')] }));
    expect(tip).toMatchObject({ id: 'NO_PHOTO_POPULAR', productId: 'b', action: 'PRODUCT' });
    expect(tip!.text).toContain('Dish b');
    expect(
      noPhotoPopular(ctx({ products: withProducts(product('a')), topDishes: [stats('a')] }))
    ).toBeNull();
  });

  it('HIGH_VIEW_LOW_OPEN: seen often, opened < 5%', () => {
    const products = withProducts(product('a'), product('b'));
    const funnel = [
      stats('a', { impressions: 100, opens: 4 }),
      stats('b', { impressions: 40, opens: 0 }),
    ];
    expect(highViewLowOpen(ctx({ products, funnel }))).toMatchObject({ productId: 'a' });
    expect(
      highViewLowOpen(ctx({ products, funnel: [stats('a', { impressions: 100, opens: 5 })] }))
    ).toBeNull();
    // Too few impressions to judge.
    expect(
      highViewLowOpen(ctx({ products, funnel: [stats('b', { impressions: 49, opens: 0 })] }))
    ).toBeNull();
  });

  it('AR_OUTPERFORMS: 3D dishes average ≥ 2× the opens of photo dishes', () => {
    const products = withProducts(
      product('t1', { type: 'THREE_D' }),
      product('t2', { type: 'THREE_D' }),
      product('t3', { type: 'THREE_D' }),
      product('p1'),
      product('p2'),
      product('p3')
    );
    const funnel = [
      stats('t1', { opens: 20 }),
      stats('t2', { opens: 20 }),
      stats('t3', { opens: 20 }),
      stats('p1', { opens: 8 }),
      stats('p2', { opens: 4 }),
      stats('p3', { opens: 3 }),
    ];
    const tip = arOutperforms(ctx({ products, funnel }));
    expect(tip).toMatchObject({
      id: 'AR_OUTPERFORMS',
      productId: 'p1',
      action: 'MODEL_GENERATION',
    });
    expect(tip!.text).toContain('4×');

    const even = funnel.map((row) => ({ ...row, opens: 10 }));
    expect(arOutperforms(ctx({ products, funnel: even }))).toBeNull();
    // Too few dishes of one kind.
    expect(arOutperforms(ctx({ products, funnel: funnel.slice(0, 5) }))).toBeNull();
  });

  it('SOLD_OUT_VIEWED: an out-of-stock dish opened more than 20 times', () => {
    const products = withProducts(product('a', { availability: 'OUT_OF_STOCK' }), product('b'));
    const tip = soldOutViewed(
      ctx({ products, funnel: [stats('a', { opens: 34 }), stats('b', { opens: 90 })] })
    );
    expect(tip).toMatchObject({ id: 'SOLD_OUT_VIEWED', productId: 'a' });
    expect(tip!.text).toContain('34 people');
    expect(soldOutViewed(ctx({ products, funnel: [stats('a', { opens: 20 })] }))).toBeNull();
  });

  it('NO_DESCRIPTION: names the rank of the top dish missing one', () => {
    const products = withProducts(product('a'), product('b', { hasDescription: false }));
    const tip = noDescription(ctx({ products, topDishes: [stats('a'), stats('b')] }));
    expect(tip!.text).toContain('#2');
    expect(
      noDescription(ctx({ products: withProducts(product('a')), topDishes: [stats('a')] }))
    ).toBeNull();
  });

  it('DRAFT_NOT_PUBLISHED: pending changes and last publish > 3 days ago', () => {
    const old = new Date('2026-09-20T00:00:00Z');
    expect(
      draftNotPublished(ctx({ draftRevision: 3, publishedRevision: 2, lastPublishedAt: old }))
    ).toMatchObject({
      id: 'DRAFT_NOT_PUBLISHED',
      action: 'PUBLISH',
    });
    expect(
      draftNotPublished(ctx({ draftRevision: 2, publishedRevision: 2, lastPublishedAt: old }))
    ).toBeNull();
    // Published yesterday: not stale yet.
    expect(draftNotPublished(ctx({ draftRevision: 3, publishedRevision: 2 }))).toBeNull();
  });

  it('SEARCH_NO_RESULT: a query that found nothing at least 5 times', () => {
    expect(
      searchNoResult(
        ctx({
          searches: [
            { query: 'momos', zeroResults: 6 },
            { query: 'tea', zeroResults: 2 },
          ],
        })
      )
    ).toMatchObject({ id: 'SEARCH_NO_RESULT', action: 'ADD_PRODUCT' });
    expect(searchNoResult(ctx({ searches: [{ query: 'momos', zeroResults: 4 }] }))).toBeNull();
  });

  it('pickTips keeps the two highest-priority tips', () => {
    const products = withProducts(
      product('a', { hasPhoto: false, hasDescription: false }),
      product('b', { availability: 'OUT_OF_STOCK' })
    );
    const tips = pickTips(
      ctx({
        products,
        topDishes: [stats('a')],
        funnel: [stats('b', { opens: 50 })],
        searches: [{ query: 'momos', zeroResults: 9 }],
      })
    );
    expect(tips.map((t) => t.id)).toEqual(['NO_PHOTO_POPULAR', 'SOLD_OUT_VIEWED']);
  });
});

// ── Delivery (idempotency) ──────────────────────────────────────────────────

class ReportMirage extends FakeMirage {
  pageViews = 1240;
  restaurantId = '';

  async analyticsSummary(query: MirageAnalyticsQuery) {
    const base = await super.analyticsSummary(query);
    return {
      ...base,
      kpis: { ...base.kpis, pageViews: this.pageViews, visitors: 800, arViews: 310 },
      previousKpis: { ...base.kpis, pageViews: 1051, visitors: 700, arViews: 300 },
      topSearches: [],
      // Stage 11: grouped by restaurant like every per-dish panel; the second row
      // names someone else and must never surface as this owner's "most added".
      plateStats: {
        plates: 86,
        avgValue: 640,
        shownToWaiter: 40,
        sentWhatsapp: 3,
        topDishes: [
          { productId: 'other', restaurantId: 'someone-else', name: 'Not ours', adds: 99 },
          { productId: 'mi-1', restaurantId: this.restaurantId, name: 'Paneer Tikka', adds: 12 },
        ],
      },
    };
  }

  async analyticsTopProducts(_query: MirageAnalyticsQuery) {
    return [
      {
        productId: 'mi-1',
        name: 'Paneer Tikka',
        views: 182,
        arViews: 40,
        modelLoads: 0,
        sessions: 90,
      },
    ];
  }

  async analyticsHourly(_query: MirageAnalyticsQuery) {
    return [{ dow: 5, hour: 20, views: 97 }];
  }
}

let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await WeeklyReport.syncIndexes();
  await Notification.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

let mirage: ReportMirage;

beforeEach(() => {
  mirage = new ReportMirage();
  setMirageClient(mirage);
});

afterEach(async () => {
  resetMirageClient();
  await Promise.all([
    Catalog.deleteMany({}),
    CatalogProduct.deleteMany({}),
    WeeklyReport.deleteMany({}),
    Notification.deleteMany({}),
  ]);
});

async function seedCatalog(over: Record<string, unknown> = {}): Promise<Types.ObjectId> {
  const restaurantId = new Types.ObjectId().toHexString();
  const catalog = await Catalog.create({
    userId: new Types.ObjectId(),
    name: 'Café Mocha',
    status: 'PUBLISHED',
    draftRevision: 1,
    publishedRevision: 1,
    lastPublishedAt: new Date('2026-09-27T00:00:00Z'),
    mirageRestaurantId: restaurantId,
    publicUrl: `https://menu.test/${restaurantId}`,
    publicUrlScheme: 'MIRAGE_OBJECT_ID',
    ...over,
  });
  return catalog._id as Types.ObjectId;
}

const NOW = new Date('2026-09-28T04:30:00Z'); // Monday 10:00 IST

describe('deliverWeeklyReport', () => {
  it('run twice → one report, one notification', async () => {
    const catalogId = await seedCatalog();

    mirage.restaurantId = (await Catalog.findById(catalogId).lean())!.mirageRestaurantId!;
    const first = await deliverWeeklyReport(catalogId, '2026-09-21', NOW);
    const second = await deliverWeeklyReport(catalogId, '2026-09-21', NOW);

    expect(first).toMatchObject({ outcome: 'SENT', notified: true });
    expect(second).toMatchObject({ outcome: 'ALREADY_DONE' });
    expect(await WeeklyReport.countDocuments({ catalogId })).toBe(1);

    const notes = await Notification.find({}).lean();
    expect(notes).toHaveLength(1);
    expect(notes[0].kind).toBe('ANALYTICS');
    expect(notes[0].title).toContain('Café Mocha');
    expect(notes[0].message).toContain('1,240 menu views');
    expect(notes[0].message).toContain('▲ 18%');
    expect(notes[0].message).toContain('Busiest: Saturday 8–9 pm');
    expect(notes[0].action?.url).toBe('/catalog/reports/2026-09-21');

    // Stage 11: the week's plates, scoped to this restaurant.
    const stored = await WeeklyReport.findOne({ catalogId }).lean();
    expect(stored!.metrics.plates).toEqual({ built: 86, avgValue: 640, topDish: 'Paneer Tikka' });
  });

  it('skips a catalog whose owner switched weekly reports off', async () => {
    const catalogId = await seedCatalog({ reportPrefs: { weekly: false, channels: ['IN_APP'] } });
    expect(await deliverWeeklyReport(catalogId, '2026-09-21', NOW)).toEqual({
      outcome: 'SKIPPED',
      reason: 'OPTED_OUT',
    });
    expect(await WeeklyReport.countDocuments({})).toBe(0);
    expect(await Notification.countDocuments({})).toBe(0);
  });

  it('a quiet week is stored, and gets the QR nudge at most once a month', async () => {
    mirage.pageViews = 4;
    const catalogId = await seedCatalog();

    expect(await deliverWeeklyReport(catalogId, '2026-09-07', NOW)).toMatchObject({
      outcome: 'QUIET',
    });
    expect(await deliverWeeklyReport(catalogId, '2026-09-14', NOW)).toMatchObject({
      outcome: 'QUIET',
    });

    expect(await WeeklyReport.countDocuments({ catalogId })).toBe(2);
    const notes = await Notification.find({}).lean();
    expect(notes).toHaveLength(1);
    expect(notes[0].title).toBe('Your menu had a quiet week');
  });
});
