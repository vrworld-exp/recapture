// tests/subscription-testing-prices.test.ts
//
// Requirement 1: `SUBSCRIPTION_TESTING_PRICES=true` re-prices the three plans to
// a few rupees so a real Razorpay flow can be walked end to end.
//
// The properties that matter are mostly about what it does NOT change. A testing
// price is a price: it must not quietly become a different product (different
// caps, standees, features or durations), it must not diverge between the numbers
// a client is SHOWN and the number an order is MINTED for, and it must not reach
// a period that was already bought.
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest';
import mongoose from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';

import { ClientConfig } from '@/models/ClientConfig';
import {
  applyTestingPrices,
  DEFAULT_PLAN_CATALOG,
  planCatalogSchema,
} from '@/config/subscriptionPlans';
import { PLAN_IDS, yearlyPricePaise, type PlanCatalog } from '@/models/types/subscription.types';
import {
  getPlanCatalog,
  PLAN_CATALOG_STORE_KEY,
} from '@/services/subscription/planCatalogService';
import { quoteFor } from '@/services/subscription/checkoutService';
import { env } from '@/config/env';

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

/** Turns the flag on for one test, at the resolved env the service reads. */
function withTestingPrices(): void {
  vi.spyOn(env, 'SUBSCRIPTION_TESTING_PRICES', 'get').mockReturnValue(true);
}

describe('applyTestingPrices', () => {
  it('re-prices all three tiers and flags itself', () => {
    const priced = applyTestingPrices(DEFAULT_PLAN_CATALOG);
    expect(priced.plans.TASTE.priceMonthlyPaise).toBe(300);
    expect(priced.plans.SIGNATURE.priceMonthlyPaise).toBe(500);
    expect(priced.plans.MASTERCHEF.priceMonthlyPaise).toBe(700);
    expect(priced.testingPrices).toBe(true);
  });

  it('changes the PRICE and nothing else about the product', () => {
    // The trap this pins: a testing mode that also relaxed a cap would test a
    // plan nobody sells, and every cap-related bug would hide behind it.
    const priced = applyTestingPrices(DEFAULT_PLAN_CATALOG);
    for (const planId of PLAN_IDS) {
      const before = DEFAULT_PLAN_CATALOG.plans[planId];
      const after = priced.plans[planId];
      expect(after.threeDDishCap).toBe(before.threeDDishCap);
      expect(after.includedStandeeCount).toBe(before.includedStandeeCount);
      expect(after.yearlyDiscountPct).toBe(before.yearlyDiscountPct);
      expect(after.features).toEqual(before.features);
      expect(after.displayName).toBe(before.displayName);
    }
    expect(priced.trialDays).toBe(DEFAULT_PLAN_CATALOG.trialDays);
    expect(priced.graceDays).toBe(DEFAULT_PLAN_CATALOG.graceDays);
    expect(priced.orderTtlHours).toBe(DEFAULT_PLAN_CATALOG.orderTtlHours);
  });

  it('is pure — the input catalog is untouched', () => {
    const snapshot = structuredClone(DEFAULT_PLAN_CATALOG);
    applyTestingPrices(DEFAULT_PLAN_CATALOG);
    expect(DEFAULT_PLAN_CATALOG).toEqual(snapshot);
  });

  it('keeps the real yearly formula, so the discount arithmetic is exercised', () => {
    const priced = applyTestingPrices(DEFAULT_PLAN_CATALOG);
    // 300 x 12 = 3600, less 30% = 2520 paise. Well over Razorpay's 100-paise
    // floor, which is what the env schema's min(100) protects.
    expect(yearlyPricePaise(priced.plans.TASTE)).toBe(2520);
    expect(yearlyPricePaise(priced.plans.TASTE)).toBeGreaterThanOrEqual(100);
    expect(yearlyPricePaise(priced.plans.MASTERCHEF)).toBeGreaterThanOrEqual(100);
  });
});

describe('getPlanCatalog with the flag on', () => {
  it('serves testing prices, and says so', async () => {
    withTestingPrices();
    const catalog = await getPlanCatalog();
    expect(catalog.plans.TASTE.priceMonthlyPaise).toBe(300);
    expect(catalog.testingPrices).toBe(true);
  });

  it('serves the real prices with the flag off, and says so', async () => {
    const catalog = await getPlanCatalog();
    expect(catalog.plans.TASTE.priceMonthlyPaise).toBe(119_900);
    expect(catalog.testingPrices).toBe(false);
  });

  it('wins over an ops override — testing prices are applied LAST', async () => {
    const override = structuredClone(DEFAULT_PLAN_CATALOG) as PlanCatalog;
    override.plans.TASTE.priceMonthlyPaise = 999_900;
    await ClientConfig.create({ [PLAN_CATALOG_STORE_KEY]: override });

    withTestingPrices();
    const catalog = await getPlanCatalog();
    expect(catalog.plans.TASTE.priceMonthlyPaise).toBe(300);
    // The override's OTHER fields still came through: testing mode re-prices,
    // it does not discard the override.
    expect(catalog.plans.SIGNATURE.threeDDishCap).toBe(
      DEFAULT_PLAN_CATALOG.plans.SIGNATURE.threeDDishCap
    );
  });

  it('quotes the SAME number it serves, monthly and yearly', async () => {
    // The divergence this pins is the expensive one: a screen showing ₹3 while
    // checkout mints an order for ₹1,199 (or the reverse) is a charge the
    // customer did not agree to. Both come from getPlanCatalog, once.
    withTestingPrices();
    const catalog = await getPlanCatalog();

    const monthly = quoteFor(catalog, 'TASTE', 'MONTHLY');
    expect(monthly.totalPaise).toBe(300);
    expect(monthly.planSnapshot.priceMonthlyPaise).toBe(
      catalog.plans.TASTE.priceMonthlyPaise
    );

    const yearly = quoteFor(catalog, 'TASTE', 'YEARLY');
    expect(yearly.totalPaise).toBe(yearlyPricePaise(catalog.plans.TASTE));
  });

  it('freezes the testing price onto the quote snapshot, so flipping the flag off does not re-bill', async () => {
    withTestingPrices();
    const quote = quoteFor(await getPlanCatalog(), 'SIGNATURE', 'MONTHLY');
    expect(quote.planSnapshot.priceMonthlyPaise).toBe(500);

    // The flag goes off. The snapshot already taken is the plan AS BOUGHT and
    // is unchanged — `applyPaidPeriod` writes THIS onto the row, so a
    // restaurant that paid ₹5 keeps a ₹5 snapshot until its next renewal.
    vi.restoreAllMocks();
    const real = await getPlanCatalog();
    expect(real.plans.SIGNATURE.priceMonthlyPaise).toBe(179_900);
    expect(quote.planSnapshot.priceMonthlyPaise).toBe(500);
  });
});

describe('the ops override round trip', () => {
  it('accepts and ignores the three server-resolved keys', () => {
    // An operator GETs /remote-config, edits a price and writes the object back
    // — and the served catalog carries these three. Under a bare .strict() that
    // round trip would refuse the WHOLE override and silently serve defaults.
    const parsed = planCatalogSchema.safeParse({
      ...structuredClone(DEFAULT_PLAN_CATALOG),
      pendingPaymentDays: 99,
      pendingPaymentThreeDCap: 99,
      testingPrices: true,
    });
    expect(parsed.success).toBe(true);
  });

  it('still refuses a key nobody knows', () => {
    const parsed = planCatalogSchema.safeParse({
      ...structuredClone(DEFAULT_PLAN_CATALOG),
      somethingInvented: true,
    });
    expect(parsed.success).toBe(false);
  });

  it('cannot switch testing prices on from the store', async () => {
    // Prices are a deploy-time decision. A stored `testingPrices: true` parses
    // (above) but is overwritten by the env-resolved value, so nobody can start
    // charging three rupees with a one-line database edit.
    await ClientConfig.create({
      [PLAN_CATALOG_STORE_KEY]: {
        ...structuredClone(DEFAULT_PLAN_CATALOG),
        testingPrices: true,
      },
    });
    const catalog = await getPlanCatalog();
    expect(catalog.testingPrices).toBe(false);
    expect(catalog.plans.TASTE.priceMonthlyPaise).toBe(119_900);
  });
});
