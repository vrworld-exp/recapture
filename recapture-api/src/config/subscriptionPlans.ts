// src/config/subscriptionPlans.ts
//
// The plan catalog: the three plans and the shared constants, as decided in
// RECAPTURE_SUBSCRIPTION_PLAN.md §3 and frozen in docs/subscription/README.md
// ("Constants").
//
// This is DATA, not a secret, which is why it does not live in env.ts. The
// defaults below are what the API serves until ops writes a
// `subscriptionPlans` override onto the `client_configs` document; the
// override is validated WHOLE against `planCatalogSchema` and rejected to these
// defaults on any issue (services/subscription/planCatalogService.ts).
import { z } from 'zod';
import { env } from '@/config/env';
import {
  PLAN_FEATURES,
  PLAN_IDS,
  type PlanCatalog,
  type PlanDefinition,
  type PlanId,
} from '@/models/types/subscription.types';

export const DEFAULT_PLAN_CATALOG: PlanCatalog = {
  plans: {
    TASTE: {
      planId: 'TASTE',
      displayName: 'Taste plan',
      priceMonthlyPaise: 119_900,
      yearlyDiscountPct: 30,
      threeDDishCap: 10,
      includedStandeeCount: 10,
      features: [],
    },
    SIGNATURE: {
      planId: 'SIGNATURE',
      displayName: 'Signature plan',
      priceMonthlyPaise: 179_900,
      yearlyDiscountPct: 30,
      threeDDishCap: 15,
      includedStandeeCount: 15,
      features: ['whatsapp_instagram_buttons'],
    },
    MASTERCHEF: {
      planId: 'MASTERCHEF',
      displayName: 'MasterChef plan',
      priceMonthlyPaise: 249_900,
      yearlyDiscountPct: 30,
      threeDDishCap: 30,
      includedStandeeCount: 30,
      features: [
        'whatsapp_instagram_buttons',
        'website_embed',
        'per_dish_analytics',
        'priority_support',
      ],
    },
  },
  trialDays: 30,
  trialThreeDCap: 10,
  graceDays: 7,
  grandfatherDays: 30,
  orderTtlHours: 24,
  // Server-resolved, never stored: planCatalogService overwrites both from env
  // on every read. The values here are what the defaults would resolve to with
  // an unset environment, so a hand-built DEFAULT_PLAN_CATALOG is still whole.
  pendingPaymentDays: 7,
  pendingPaymentThreeDCap: 10,
  testingPrices: false,
};

const planDefinitionSchema = z
  .object({
    planId: z.enum(PLAN_IDS),
    displayName: z.string().trim().min(1).max(60),
    priceMonthlyPaise: z.number().int().positive(),
    // Bounded ABOVE as well as below. A typo of 100 (or 99) would quote a ₹0
    // (or ₹1) yearly order that Razorpay rejects — or worse, honours — and the
    // whole override is refused instead (edge case E42).
    yearlyDiscountPct: z.number().int().min(0).max(90),
    threeDDishCap: z.number().int().positive(),
    includedStandeeCount: z.number().int().positive(),
    features: z.array(z.enum(PLAN_FEATURES)).readonly(),
  })
  .strict();

/**
 * The override's shape. `.strict()` throughout, every number an integer, and
 * ALL THREE plans required — an override that names two plans is not "two
 * plans changed", it is a malformed catalog and the defaults are served.
 */
export const planCatalogSchema = z
  .object({
    plans: z
      .object({
        TASTE: planDefinitionSchema,
        SIGNATURE: planDefinitionSchema,
        MASTERCHEF: planDefinitionSchema,
      } satisfies Record<(typeof PLAN_IDS)[number], z.ZodTypeAny>)
      .strict(),
    trialDays: z.number().int().positive(),
    trialThreeDCap: z.number().int().positive(),
    graceDays: z.number().int().positive(),
    grandfatherDays: z.number().int().positive(),
    orderTtlHours: z.number().int().positive(),
    // ACCEPTED AND IGNORED, not refused. These three are resolved from env on
    // every read (planCatalogService.resolve) and a stored value for them can
    // never take effect. They are listed anyway because of how an override is
    // actually written: an operator GETs /remote-config, edits one price, and
    // writes the object back — and the served catalog carries all three. Under
    // a bare `.strict()` that round trip refuses the WHOLE override and
    // silently serves defaults, which is a booby trap for the one workflow this
    // feature has. Unknown keys are still refused; these are known and dropped.
    pendingPaymentDays: z.number().int().positive().optional(),
    pendingPaymentThreeDCap: z.number().int().positive().optional(),
    testingPrices: z.boolean().optional(),
  })
  .strict();

// ── Testing prices ──────────────────────────────────────────────────────────

/**
 * The testing price for each tier, in integer paise, straight from env — the
 * ONE place the three variables are read together.
 */
function testingPricesPaise(): Record<PlanId, number> {
  return {
    TASTE: env.SUBSCRIPTION_TESTING_PRICE_TASTE_PAISE,
    SIGNATURE: env.SUBSCRIPTION_TESTING_PRICE_SIGNATURE_PAISE,
    MASTERCHEF: env.SUBSCRIPTION_TESTING_PRICE_MASTERCHEF_PAISE,
  };
}

/**
 * Re-prices a catalog at the testing prices, leaving EVERYTHING ELSE alone.
 *
 * What it touches: `priceMonthlyPaise`, on each of the three plans, and the
 * `testingPrices` flag. What it deliberately does not touch:
 *
 *   • `yearlyDiscountPct` — the yearly total stays the real formula over the
 *     testing monthly figure (`yearlyPricePaise`), so the arithmetic a real
 *     yearly order goes through is the arithmetic being tested. At the default
 *     3/5/7 that is ₹25.20 / ₹42 / ₹58.80 a year, all well over Razorpay's
 *     one-rupee floor.
 *   • the caps, the standee counts, the features, the durations — a testing
 *     price is a price, not a different product. Testing a ₹3 plan that also
 *     quietly carried a different 3D cap would test nothing anybody sells.
 *
 * Pure, and applied LAST (after an ops override has been validated), so the
 * numbers a client is quoted and the numbers checkoutService mints an order
 * for come from one function and cannot drift apart.
 */
export function applyTestingPrices(catalog: PlanCatalog): PlanCatalog {
  const prices = testingPricesPaise();
  const plans = {} as Record<PlanId, PlanDefinition>;
  for (const planId of PLAN_IDS) {
    plans[planId] = { ...catalog.plans[planId], priceMonthlyPaise: prices[planId] };
  }
  return { ...catalog, plans, testingPrices: true };
}
