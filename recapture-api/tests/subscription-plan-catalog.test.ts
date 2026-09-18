// tests/subscription-plan-catalog.test.ts
//
// The plan catalog: the numbers Stage 0 froze, the yearly formula (AC-8.1),
// and the reject-to-defaults policy on the `client_configs` override.
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest';
import mongoose from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { ClientConfig } from '@/models/ClientConfig';
import { DEFAULT_PLAN_CATALOG, planCatalogSchema } from '@/config/subscriptionPlans';
import { yearlyPricePaise, type PlanCatalog } from '@/models/types/subscription.types';
import {
  getPlanCatalog,
  PLAN_CATALOG_STORE_KEY,
} from '@/services/subscription/planCatalogService';

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

/** A deep copy of the defaults a test can mutate. */
function override(): PlanCatalog {
  return structuredClone(DEFAULT_PLAN_CATALOG);
}

describe('the frozen constants', () => {
  it('prices the three plans as decided', () => {
    expect(DEFAULT_PLAN_CATALOG.plans.TASTE).toMatchObject({
      priceMonthlyPaise: 119_900,
      threeDDishCap: 10,
      includedStandeeCount: 10,
      yearlyDiscountPct: 30,
    });
    expect(DEFAULT_PLAN_CATALOG.plans.SIGNATURE).toMatchObject({
      priceMonthlyPaise: 179_900,
      threeDDishCap: 15,
      includedStandeeCount: 15,
    });
    expect(DEFAULT_PLAN_CATALOG.plans.MASTERCHEF).toMatchObject({
      priceMonthlyPaise: 249_900,
      threeDDishCap: 30,
      includedStandeeCount: 30,
    });
    expect(DEFAULT_PLAN_CATALOG).toMatchObject({
      trialDays: 30,
      trialThreeDCap: 10,
      graceDays: 7,
      grandfatherDays: 30,
      orderTtlHours: 24,
    });
  });

  it('is itself a valid override — the schema and the defaults cannot drift', () => {
    expect(planCatalogSchema.safeParse(DEFAULT_PLAN_CATALOG).success).toBe(true);
  });

  it('computes the yearly price as monthly × 12 × 0.70, in integer paise', () => {
    expect(yearlyPricePaise(DEFAULT_PLAN_CATALOG.plans.TASTE)).toBe(1_007_160);
    expect(yearlyPricePaise(DEFAULT_PLAN_CATALOG.plans.SIGNATURE)).toBe(1_511_160);
    expect(yearlyPricePaise(DEFAULT_PLAN_CATALOG.plans.MASTERCHEF)).toBe(2_099_160);
  });

  it('rounds a yearly price that does not divide evenly to whole paise', () => {
    const plan = { ...DEFAULT_PLAN_CATALOG.plans.TASTE, priceMonthlyPaise: 1, yearlyDiscountPct: 30 };
    expect(yearlyPricePaise(plan)).toBe(8); // 8.4 → 8
    expect(Number.isInteger(yearlyPricePaise(plan))).toBe(true);
  });
});

describe('getPlanCatalog', () => {
  it('serves defaults when there is no config document', async () => {
    expect(await getPlanCatalog()).toEqual(DEFAULT_PLAN_CATALOG);
  });

  it('serves defaults when the document has no override key', async () => {
    await ClientConfig.create({ version: 1, subscriptionGatesEnabled: true });
    expect(await getPlanCatalog()).toEqual(DEFAULT_PLAN_CATALOG);
  });

  it('serves a valid override', async () => {
    const custom = override();
    custom.plans.TASTE.priceMonthlyPaise = 129_900;
    custom.graceDays = 10;
    await ClientConfig.create({ [PLAN_CATALOG_STORE_KEY]: custom });

    const served = await getPlanCatalog();
    expect(served.plans.TASTE.priceMonthlyPaise).toBe(129_900);
    expect(served.graceDays).toBe(10);
    expect(served.plans.MASTERCHEF).toEqual(DEFAULT_PLAN_CATALOG.plans.MASTERCHEF);
  });

  it('serves defaults, whole, when the override is malformed — and warns', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const custom = override();
    custom.plans.SIGNATURE.priceMonthlyPaise = 1799.5; // rupees, not paise
    await ClientConfig.create({ [PLAN_CATALOG_STORE_KEY]: custom });

    expect(await getPlanCatalog()).toEqual(DEFAULT_PLAN_CATALOG);
    expect(warn).toHaveBeenCalledTimes(1);
    expect(String(warn.mock.calls[0]?.[0])).toContain('plans.SIGNATURE.priceMonthlyPaise');
  });

  it('refuses an override missing a plan rather than merging it', async () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    const custom = override() as { plans: Partial<PlanCatalog['plans']> };
    delete custom.plans.MASTERCHEF;
    await ClientConfig.create({ [PLAN_CATALOG_STORE_KEY]: custom });

    expect(await getPlanCatalog()).toEqual(DEFAULT_PLAN_CATALOG);
  });

  it('refuses an unknown key (strict), so a typo cannot silently do nothing', async () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    await ClientConfig.create({
      [PLAN_CATALOG_STORE_KEY]: { ...override(), graceDay: 10 },
    });

    expect(await getPlanCatalog()).toEqual(DEFAULT_PLAN_CATALOG);
  });

  it('bounds the yearly discount so a ₹0 yearly order is impossible (E42)', async () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    const custom = override();
    custom.plans.TASTE.yearlyDiscountPct = 100;
    await ClientConfig.create({ [PLAN_CATALOG_STORE_KEY]: custom });

    const served = await getPlanCatalog();
    expect(served.plans.TASTE.yearlyDiscountPct).toBe(30);
    expect(yearlyPricePaise(served.plans.TASTE)).toBeGreaterThan(0);

    // 90 is the ceiling and is accepted.
    expect(
      planCatalogSchema.safeParse({
        ...override(),
        plans: { ...override().plans, TASTE: { ...override().plans.TASTE, yearlyDiscountPct: 90 } },
      }).success
    ).toBe(true);
  });

  it('serves defaults when the store read throws', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    vi.spyOn(ClientConfig, 'findOne').mockImplementationOnce(() => {
      throw new Error('store down');
    });

    await expect(getPlanCatalog()).resolves.toEqual(DEFAULT_PLAN_CATALOG);
    expect(String(warn.mock.calls[0]?.[0])).toContain('store down');
  });
});
