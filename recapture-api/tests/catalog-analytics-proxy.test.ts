// tests/catalog-analytics-proxy.test.ts
//
// GET /catalog/analytics/{summary,timeseries,top-products} — features 61–66.
//
// THE FIRST TEST IS THE IMPORTANT ONE. Mirage's `buildMatch` omits the
// restaurant filter entirely when the parameter is empty
// (analyticsHelper.js:221-227), so a scope that leaks through as blank does not
// return nothing — it returns EVERY BUSINESS'S NUMBERS. A cross-tenant leak
// through an analytics endpoint is quiet, plausible-looking, and would be found
// by a customer rather than by us. Hence: a client-supplied `restaurant` is
// proved to be ignored, and an unprovisioned catalog is proved to make no call
// at all.
import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose, { Types } from 'mongoose';
import jwt from 'jsonwebtoken';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { env } from '@/config/env';
import { Catalog } from '@/models/Catalog';
import { CatalogProduct } from '@/models/CatalogProduct';
import { User } from '@/models/User';
import {
  clearAnalyticsCache,
  resolveRange,
  ANALYTICS_MAX_DAYS,
} from '@/services/catalogAnalyticsService';
import {
  MirageError,
  MirageErrorCode,
  resetMirageClient,
  setMirageClient,
  type MirageAnalyticsQuery,
  type MirageTopProductRow,
} from '@/services/mirage';
import { FakeMirage } from './fixtures/mirageFake';

const app = createApp();
let mongod: MongoMemoryServer;

/** Records every query Mirage was asked, so the scope can be asserted. */
class RecordingMirage extends FakeMirage {
  readonly queries: MirageAnalyticsQuery[] = [];
  topRows: MirageTopProductRow[] = [];
  summaryKpis: Record<string, number> = {};

  async analyticsSummary(query: MirageAnalyticsQuery) {
    this.queries.push(query);
    const base = await super.analyticsSummary(query);
    return {
      ...base,
      kpis: { ...base.kpis, ...this.summaryKpis },
      // Cross-client panels Mirage really returns. Nothing here may reach a
      // per-business response.
      byRestaurant: [{ name: 'Someone Else Cafe', events: 9999 }],
      byDevice: [{ device: 'ios', events: 12 }],
      topCategories: [{ name: 'chairs' }],
      topZoomed: [{ name: 'Their Product' }],
    };
  }

  async analyticsTimeseries(query: MirageAnalyticsQuery) {
    this.queries.push(query);
    return [
      { date: '2026-01-01', pageViews: 3, productViews: 2, arViews: 1, sessions: 2 },
      { date: '2026-01-02', pageViews: 0, productViews: 0, arViews: 0, sessions: 0 },
    ];
  }

  async analyticsTopProducts(query: MirageAnalyticsQuery) {
    this.queries.push(query);
    return this.topRows;
  }
}

const mirage = new RecordingMirage();

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
  await Catalog.syncIndexes();
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

beforeEach(() => {
  mirage.reset();
  mirage.queries.length = 0;
  mirage.topRows = [];
  mirage.summaryKpis = {};
  setMirageClient(mirage);
  clearAnalyticsCache();
  Object.assign(env, {
    MIRAGE_BASE_URL: 'https://mirage.test',
    MIRAGE_API_KEY: 'test-api-key',
    MIRAGE_ADMIN_TOKEN: 'test-admin-token',
    MIRAGE_PUBLIC_BASE_URL: 'https://menu.test',
  });
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
});

afterEach(async () => {
  vi.restoreAllMocks();
  resetMirageClient();
  clearAnalyticsCache();
  await Promise.all([
    User.deleteMany({}),
    Catalog.deleteMany({}),
    CatalogProduct.deleteMany({}),
    mongoose.connection.collection('ratewindows').deleteMany({}),
  ]);
});

type Auth = { Authorization: string };

async function makeUser(): Promise<{ id: string; auth: Auth }> {
  const user = await User.create({
    authProvider: 'custom',
    authUid: `test|${new Types.ObjectId().toHexString()}`,
  });
  const id = user.id as string;
  const token = jwt.sign({ userId: id, authUid: user.authUid }, env.JWT_SECRET, {
    expiresIn: '15m',
  });
  return { id, auth: { Authorization: `Bearer ${token}` } };
}

async function seed(
  userId: string,
  options: { provisioned?: boolean } = {}
): Promise<{ catalogId: Types.ObjectId; restaurantId: string }> {
  const restaurantId = new Types.ObjectId().toHexString();
  const catalog = await Catalog.create({
    userId: new Types.ObjectId(userId),
    name: 'Blue Cafe',
    status: options.provisioned === false ? 'DRAFT' : 'PUBLISHED',
    draftRevision: 1,
    publishedRevision: options.provisioned === false ? -1 : 1,
    ...(options.provisioned === false
      ? {}
      : {
          mirageRestaurantId: restaurantId,
          publicUrl: `https://menu.test/${restaurantId}`,
          publicUrlScheme: 'MIRAGE_OBJECT_ID',
        }),
  });
  return { catalogId: catalog._id as Types.ObjectId, restaurantId };
}

// ── Scope ───────────────────────────────────────────────────────────────────

describe('the scope is never client-supplied', () => {
  it('forces the caller’s own restaurant id on every report', async () => {
    const { id, auth } = await makeUser();
    const { restaurantId } = await seed(id);

    await request(app).get('/catalog/analytics/summary').set(auth);
    await request(app).get('/catalog/analytics/timeseries').set(auth);
    await request(app).get('/catalog/analytics/top-products').set(auth);

    expect(mirage.queries).toHaveLength(3);
    for (const query of mirage.queries) expect(query.restaurantId).toBe(restaurantId);
  });

  it('rejects a client-supplied `restaurant` outright', async () => {
    const { id, auth } = await makeUser();
    const { restaurantId } = await seed(id);
    const stranger = new Types.ObjectId().toHexString();

    const res = await request(app)
      .get(`/catalog/analytics/summary?restaurant=${stranger}`)
      .set(auth);

    // `.strict()` on the query schema is the loudest possible way to say the
    // scope is not the client's to choose.
    expect(res.status).toBe(400);
    expect(mirage.queries).toHaveLength(0);

    // And even if it had passed validation, the service never reads it.
    const allowed = await request(app).get('/catalog/analytics/summary').set(auth);
    expect(allowed.status).toBe(200);
    expect(mirage.queries[0].restaurantId).toBe(restaurantId);
  });

  it('returns empty and makes ZERO Mirage calls for an unprovisioned catalog', async () => {
    const { id, auth } = await makeUser();
    await seed(id, { provisioned: false });

    const summary = await request(app).get('/catalog/analytics/summary').set(auth);
    const series = await request(app).get('/catalog/analytics/timeseries').set(auth);
    const top = await request(app).get('/catalog/analytics/top-products').set(auth);

    expect(summary.status).toBe(200);
    expect(summary.body.kpis).toMatchObject({ pageViews: 0, sessions: 0 });
    expect(series.body.points).toEqual([]);
    expect(top.body.rows).toEqual([]);
    // An unscoped read is the failure mode; not calling at all is the fix.
    expect(mirage.queries).toHaveLength(0);
  });
});

// ── Envelope translation ────────────────────────────────────────────────────

describe('the boundary translation', () => {
  it('returns the house envelope and never Mirage’s boolean status', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    mirage.summaryKpis = { pageViews: 41, arViews: 7 };

    const res = await request(app).get('/catalog/analytics/summary').set(auth);

    expect(res.body.status).toBe('success');
    expect(typeof res.body.status).toBe('string');
    expect(res.body.kpis).toMatchObject({ pageViews: 41, arViews: 7 });
  });

  it('strips every cross-client panel', async () => {
    const { id, auth } = await makeUser();
    await seed(id);

    const res = await request(app).get('/catalog/analytics/summary').set(auth);

    const body = JSON.stringify(res.body);
    // These are OTHER BUSINESSES' numbers, sitting one level down in the same
    // object a spread would have copied.
    expect(body).not.toContain('Someone Else Cafe');
    expect(body).not.toContain('byRestaurant');
    expect(body).not.toContain('byDevice');
    expect(body).not.toContain('topCategories');
    expect(body).not.toContain('topZoomed');
    expect(Object.keys(res.body).sort()).toEqual(['kpis', 'previousKpis', 'range', 'status']);
  });

  it('passes the timeseries through without re-filling or re-sorting', async () => {
    const { id, auth } = await makeUser();
    await seed(id);

    const res = await request(app).get('/catalog/analytics/timeseries').set(auth);

    expect(res.body.points).toEqual([
      { date: '2026-01-01', pageViews: 3, productViews: 2, arViews: 1, sessions: 2 },
      { date: '2026-01-02', pageViews: 0, productViews: 0, arViews: 0, sessions: 0 },
    ]);
  });
});

// ── Type partitioning (feature 65) ──────────────────────────────────────────

describe('top-products partitioning', () => {
  it('labels every row 3D / IMAGE_ONLY / UNKNOWN with correct totals', async () => {
    const { id, auth } = await makeUser();
    const { catalogId } = await seed(id);

    await CatalogProduct.create([
      {
        catalogId,
        userId: new Types.ObjectId(id),
        type: 'THREE_D',
        name: 'Garden Chair',
        position: 0,
        mirageItemId: 'mi-3d',
        assets: { glbUrl: 'https://test.cloudfront.net/m.glb' },
      },
      {
        catalogId,
        userId: new Types.ObjectId(id),
        type: 'IMAGE_ONLY',
        name: 'Stool',
        position: 1,
        mirageItemId: 'mi-img',
        assets: { imageKey: 'dev/x.jpg' },
      },
    ]);

    mirage.topRows = [
      { productId: 'mi-3d', name: 'Chair (as it was)', views: 10, arViews: 4, modelLoads: 8, sessions: 6 },
      { productId: 'mi-img', name: 'Stool', views: 5, arViews: 0, modelLoads: 0, sessions: 4 },
      // A product deleted locally since the events were collected.
      { productId: 'mi-gone', name: 'Old Table', views: 3, arViews: 1, modelLoads: 0, sessions: 2 },
    ];

    const res = await request(app).get('/catalog/analytics/top-products').set(auth);

    expect(res.status).toBe(200);
    expect(res.body.rows.map((r: { kind: string }) => r.kind)).toEqual([
      '3D',
      'IMAGE_ONLY',
      'UNKNOWN',
    ]);
    // Our name wins where we have one — Mirage's is the name as it was at event
    // time, which is stale by definition.
    expect(res.body.rows[0].name).toBe('Garden Chair');
    expect(res.body.rows[0].catalogProductId).toMatch(/^[a-f0-9]{24}$/);
    expect(res.body.rows[2].catalogProductId).toBeNull();

    expect(res.body.totals).toEqual({
      '3D': { views: 10, arViews: 4, products: 1 },
      IMAGE_ONLY: { views: 5, arViews: 0, products: 1 },
      UNKNOWN: { views: 3, arViews: 1, products: 1 },
    });
  });

  it('keeps an unmatched row instead of dropping it', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    mirage.topRows = [
      { productId: 'mi-gone', name: 'Old Table', views: 99, arViews: 3, modelLoads: 0, sessions: 9 },
    ];

    const res = await request(app).get('/catalog/analytics/top-products').set(auth);

    // Dropping it would make the totals disagree with the public page's own,
    // and "the product we deleted was the most viewed one" is real information.
    expect(res.body.rows).toHaveLength(1);
    expect(res.body.totals.UNKNOWN.views).toBe(99);
  });

  it('does not resolve another catalog’s product id', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    const stranger = await makeUser();
    const theirs = await seed(stranger.id);
    await CatalogProduct.create({
      catalogId: theirs.catalogId,
      userId: new Types.ObjectId(stranger.id),
      type: 'THREE_D',
      name: 'Their Secret Product',
      position: 0,
      mirageItemId: 'mi-theirs',
      assets: { glbUrl: 'https://test.cloudfront.net/m.glb' },
    });

    mirage.topRows = [
      { productId: 'mi-theirs', name: 'Unknown product', views: 1, arViews: 0, modelLoads: 0, sessions: 1 },
    ];

    const res = await request(app).get('/catalog/analytics/top-products').set(auth);

    expect(res.body.rows[0].kind).toBe('UNKNOWN');
    expect(JSON.stringify(res.body)).not.toContain('Their Secret Product');
  });

  it('clamps the limit Mirage is asked for', async () => {
    const { id, auth } = await makeUser();
    await seed(id);

    await request(app).get('/catalog/analytics/top-products?limit=100').set(auth);
    expect(mirage.queries[0].limit).toBe(100);

    const rejected = await request(app).get('/catalog/analytics/top-products?limit=500').set(auth);
    expect(rejected.status).toBe(400);
  });
});

// ── Range ───────────────────────────────────────────────────────────────────

describe('the date range', () => {
  it('defaults to the last 30 days', async () => {
    const { id, auth } = await makeUser();
    await seed(id);

    const res = await request(app).get('/catalog/analytics/summary').set(auth);

    expect(res.body.range.days).toBe(30);
    expect(mirage.queries[0].from).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });

  it('400s a range whose from is after its to', async () => {
    const { id, auth } = await makeUser();
    await seed(id);

    const res = await request(app)
      .get('/catalog/analytics/summary?from=2026-05-01&to=2026-04-01')
      .set(auth);

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('INVALID_REQUEST');
    expect(res.body.fields).toBeDefined();
    expect(mirage.queries).toHaveLength(0);
  });

  it('400s a malformed date rather than guessing', async () => {
    const { id, auth } = await makeUser();
    await seed(id);

    const res = await request(app).get('/catalog/analytics/summary?from=last-tuesday').set(auth);

    expect(res.status).toBe(400);
  });

  it('caps the span at a year', () => {
    const capped = resolveRange({ from: '2020-01-01', to: '2026-01-01' });
    const spanDays =
      (new Date(`${capped.to}T00:00:00Z`).getTime() -
        new Date(`${capped.from}T00:00:00Z`).getTime()) /
      86_400_000;
    expect(Math.round(spanDays)).toBe(ANALYTICS_MAX_DAYS);
  });
});

// ── Caching and degradation ─────────────────────────────────────────────────

describe('caching', () => {
  it('serves a repeat request for the same range without a second Mirage call', async () => {
    const { id, auth } = await makeUser();
    await seed(id);

    await request(app).get('/catalog/analytics/summary?from=2026-01-01&to=2026-01-31').set(auth);
    await request(app).get('/catalog/analytics/summary?from=2026-01-01&to=2026-01-31').set(auth);

    // Mirage runs on a tier that sleeps; a dashboard refresh must not wake it
    // twice.
    expect(mirage.queries).toHaveLength(1);
  });

  it('does not serve one range’s numbers for another', async () => {
    const { id, auth } = await makeUser();
    await seed(id);

    await request(app).get('/catalog/analytics/summary?from=2026-01-01&to=2026-01-31').set(auth);
    await request(app).get('/catalog/analytics/summary?from=2026-02-01&to=2026-02-28').set(auth);

    expect(mirage.queries).toHaveLength(2);
  });

  it('is keyed per catalog, so one business never sees another’s cached page', async () => {
    const a = await makeUser();
    await seed(a.id);
    const b = await makeUser();
    await seed(b.id);

    await request(app).get('/catalog/analytics/summary?from=2026-01-01&to=2026-01-31').set(a.auth);
    await request(app).get('/catalog/analytics/summary?from=2026-01-01&to=2026-01-31').set(b.auth);

    expect(mirage.queries).toHaveLength(2);
    expect(mirage.queries[0].restaurantId).not.toBe(mirage.queries[1].restaurantId);
  });
});

describe('degradation', () => {
  it('answers ANALYTICS_UNAVAILABLE, not a 500, when Mirage is down', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    setMirageClient({
      ...mirage,
      analyticsSummary: async () => {
        throw new MirageError(
          MirageErrorCode.UNREACHABLE,
          'retryable',
          'Mirage is unreachable.',
          'analytics summary'
        );
      },
    } as unknown as typeof mirage);

    const res = await request(app).get('/catalog/analytics/summary').set(auth);

    expect(res.status).toBe(503);
    expect(res.body).toMatchObject({ status: 'error', code: 'ANALYTICS_UNAVAILABLE' });
    expect(res.body.message).not.toMatch(/unreachable/i);
  });

  it('does the same when the admin credential is rejected', async () => {
    const { id, auth } = await makeUser();
    await seed(id);
    setMirageClient({
      ...mirage,
      analyticsTopProducts: async () => {
        throw new MirageError(
          MirageErrorCode.AUTH_REJECTED,
          'auth',
          'Mirage rejected the admin credential.',
          'analytics top products'
        );
      },
    } as unknown as typeof mirage);

    const res = await request(app).get('/catalog/analytics/top-products').set(auth);

    expect(res.status).toBe(503);
    expect(res.body.code).toBe('ANALYTICS_UNAVAILABLE');
  });
});

// ── Ownership ───────────────────────────────────────────────────────────────

describe('ownership', () => {
  it('404s a user with no catalog, identically to a nonexistent one', async () => {
    const { auth } = await makeUser();
    const stranger = await makeUser();
    await seed(stranger.id);

    const res = await request(app).get('/catalog/analytics/summary').set(auth);

    expect(res.status).toBe(404);
    expect(res.body.code).toBe('CATALOG_NOT_FOUND');
    expect(mirage.queries).toHaveLength(0);
  });

  it('rejects an unauthenticated call', async () => {
    const res = await request(app).get('/catalog/analytics/summary');
    expect(res.status).toBe(401);
  });
});
