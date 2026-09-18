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
import { PLAN_FEATURES, PLAN_IDS, type PlanCatalog } from '@/models/types/subscription.types';

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
  })
  .strict();
