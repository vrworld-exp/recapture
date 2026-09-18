// tests/remote-config-subscription-plans.test.ts
//
// The plan catalog on the wire: `subscriptionPlans` rides on GET /remote-config
// (RECAPTURE_SUBSCRIPTION_PLAN.md §3c) — served from defaults when the store is
// empty, from a valid override when there is one, and from defaults again (with
// the REST of the config untouched) when the override is malformed.
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest';
import request from 'supertest';
import mongoose from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { createApp } from '@/app';
import { ClientConfig } from '@/models/ClientConfig';
import { DEFAULT_PLAN_CATALOG } from '@/config/subscriptionPlans';
import { PLAN_CATALOG_STORE_KEY } from '@/services/subscription/planCatalogService';
import { DEFAULT_REMOTE_CONFIG, remoteConfigSchema } from '@/validation/remoteConfigSchema';

const app = createApp();
let mongod: MongoMemoryServer;

beforeAll(async () => {
  mongod = await MongoMemoryServer.create();
  await mongoose.connect(mongod.getUri());
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongod.stop();
});

afterEach(async () => {
  vi.restoreAllMocks();
  await ClientConfig.deleteMany({});
});

/** A stored config that satisfies the served schema, WITHOUT the plans key. */
function storedConfig(overrides: Record<string, unknown> = {}) {
  return {
    version: 9,
    pitchBands: DEFAULT_REMOTE_CONFIG.pitchBands,
    thresholds: DEFAULT_REMOTE_CONFIG.thresholds,
    segmentCounts: DEFAULT_REMOTE_CONFIG.segmentCounts,
    guided_capture_variant_segments: DEFAULT_REMOTE_CONFIG.guided_capture_variant_segments,
    ...overrides,
  };
}

describe('GET /remote-config — subscriptionPlans', () => {
  it('the baked defaults carry the three plans and validate against the served schema', () => {
    expect(DEFAULT_REMOTE_CONFIG.subscriptionPlans).toEqual(DEFAULT_PLAN_CATALOG);
    expect(DEFAULT_REMOTE_CONFIG.version).toBe(6);
    expect(remoteConfigSchema.safeParse(DEFAULT_REMOTE_CONFIG).success).toBe(true);
  });

  it('an empty store serves the plans from defaults, 200', async () => {
    const res = await request(app).get('/remote-config');

    expect(res.status).toBe(200);
    expect(Object.keys(res.body.subscriptionPlans.plans).sort()).toEqual([
      'MASTERCHEF',
      'SIGNATURE',
      'TASTE',
    ]);
    expect(res.body.subscriptionPlans).toEqual(DEFAULT_PLAN_CATALOG);
  });

  it('a stored config without the key still serves the plans (from defaults)', async () => {
    await ClientConfig.create(storedConfig());

    const res = await request(app).get('/remote-config');

    expect(res.status).toBe(200);
    expect(res.body.version).toBe(9);
    expect(res.body.subscriptionPlans).toEqual(DEFAULT_PLAN_CATALOG);
  });

  it('a valid override on the document is served', async () => {
    const custom = structuredClone(DEFAULT_PLAN_CATALOG);
    custom.plans.TASTE.priceMonthlyPaise = 129_900;
    await ClientConfig.create(storedConfig({ [PLAN_CATALOG_STORE_KEY]: custom }));

    const res = await request(app).get('/remote-config');

    expect(res.status).toBe(200);
    expect(res.body.subscriptionPlans.plans.TASTE.priceMonthlyPaise).toBe(129_900);
  });

  it('a malformed override costs only the plans — the rest of the config is served as stored', async () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    const custom = structuredClone(DEFAULT_PLAN_CATALOG) as { graceDays: unknown };
    custom.graceDays = 'seven';
    await ClientConfig.create(storedConfig({ [PLAN_CATALOG_STORE_KEY]: custom }));

    const res = await request(app).get('/remote-config');

    expect(res.status).toBe(200);
    expect(res.body.version).toBe(9); // not rejected to defaults
    expect(res.body.subscriptionPlans).toEqual(DEFAULT_PLAN_CATALOG);
  });

  it('304 still works with the key in the hash', async () => {
    const first = await request(app).get('/remote-config');
    const etag = first.headers.etag as string;
    expect(etag).toBeTruthy();

    const again = await request(app).get('/remote-config').set('If-None-Match', etag);
    expect(again.status).toBe(304);
  });
});
