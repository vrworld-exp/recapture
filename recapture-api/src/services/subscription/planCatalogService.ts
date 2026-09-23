// src/services/subscription/planCatalogService.ts
//
// Resolves the plan catalog to use: the `subscriptionPlans` override on the
// `client_configs` document when there is a valid one, the baked defaults
// otherwise.
//
// Deliberately NOT part of `remoteConfigSchema` or the `candidate` object in
// getRemoteConfig — that schema is the client wire payload, and adding a key
// there changes what every app in the field parses. Putting the catalog on the
// wire is Stage 2's job; this stage only needs the server to know the numbers.
import { ClientConfig } from '@/models/ClientConfig';
import {
  applyTestingPrices,
  DEFAULT_PLAN_CATALOG,
  planCatalogSchema,
} from '@/config/subscriptionPlans';
import { env } from '@/config/env';
import type { PlanCatalog } from '@/models/types/subscription.types';

/**
 * A catalog as the STORE can hold one — `planCatalogSchema`'s own shape, i.e.
 * a PlanCatalog minus the three fields {@link resolve} stamps on. Naming it
 * keeps `resolve` honest about taking un-resolved input, and makes the compiler
 * the thing that notices if a fourth resolved field is ever added.
 */
type StoredPlanCatalog = Omit<
  PlanCatalog,
  'pendingPaymentDays' | 'pendingPaymentThreeDCap' | 'testingPrices'
>;

/** The store key an ops override is written under. */
export const PLAN_CATALOG_STORE_KEY = 'subscriptionPlans';

/**
 * The server-resolved constants stamped onto every catalog, whatever it came
 * from — the stored override, the defaults, or the defaults after a rejection.
 *
 * `planCatalogSchema` is `.strict()` and knows nothing about these three, so an
 * ops override that tries to set them is refused whole (which is the point:
 * a testing price and a deactivation deadline are deploy-time decisions, not a
 * one-line database edit). They are applied AFTER validation, here, so every
 * caller of getPlanCatalog sees the same resolved numbers — the checkout quote,
 * the status DTO, the wire config and the sweep included.
 */
function resolve(catalog: StoredPlanCatalog): PlanCatalog {
  const withConstants: PlanCatalog = {
    ...catalog,
    pendingPaymentDays: env.SUBSCRIPTION_PENDING_PAYMENT_DAYS,
    // The window's cap is the trial's, from whichever catalog won: a rep
    // publish and a trial hand out the same amount of 3D, so there is one
    // number to reason about and no second constant to keep in step.
    pendingPaymentThreeDCap: catalog.trialThreeDCap,
    testingPrices: false,
  };
  return env.SUBSCRIPTION_TESTING_PRICES ? applyTestingPrices(withConstants) : withConstants;
}

/**
 * NEVER throws for a store problem — the same reject-to-defaults policy as
 * getRemoteConfig, and for the same reason: a malformed override or an
 * unreachable store must degrade to the numbers we shipped with, not take the
 * publish gate (and with it every publish) down.
 *
 * Whole-object rejection, no field-level merge: a catalog with two valid plans
 * and one broken one is served entirely from defaults, so the plans a user is
 * quoted always came from ONE source.
 */
export async function getPlanCatalog(): Promise<PlanCatalog> {
  try {
    const doc = await ClientConfig.findOne().sort({ updatedAt: -1 }).lean().exec();
    const raw = (doc as Record<string, unknown> | null)?.[PLAN_CATALOG_STORE_KEY];
    if (raw === undefined || raw === null) return resolve(DEFAULT_PLAN_CATALOG);

    const parsed = planCatalogSchema.safeParse(raw);
    if (!parsed.success) {
      const issue = parsed.error.issues[0];
      const where = issue?.path.join('.') || PLAN_CATALOG_STORE_KEY;
      console.warn(
        `[plan-catalog] stored override failed validation at "${where}": ` +
          `${issue?.message ?? 'invalid'}; serving defaults`
      );
      return resolve(DEFAULT_PLAN_CATALOG);
    }

    return resolve(parsed.data);
  } catch (err) {
    const message = err instanceof Error ? err.message : 'unknown error';
    console.warn(`[plan-catalog] store read failed (${message}); serving defaults`);
    return resolve(DEFAULT_PLAN_CATALOG);
  }
}
