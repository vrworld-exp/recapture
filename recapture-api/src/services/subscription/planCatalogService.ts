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
import { DEFAULT_PLAN_CATALOG, planCatalogSchema } from '@/config/subscriptionPlans';
import type { PlanCatalog } from '@/models/types/subscription.types';

/** The store key an ops override is written under. */
export const PLAN_CATALOG_STORE_KEY = 'subscriptionPlans';

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
    if (raw === undefined || raw === null) return DEFAULT_PLAN_CATALOG;

    const parsed = planCatalogSchema.safeParse(raw);
    if (!parsed.success) {
      const issue = parsed.error.issues[0];
      const where = issue?.path.join('.') || PLAN_CATALOG_STORE_KEY;
      console.warn(
        `[plan-catalog] stored override failed validation at "${where}": ` +
          `${issue?.message ?? 'invalid'}; serving defaults`
      );
      return DEFAULT_PLAN_CATALOG;
    }

    return parsed.data;
  } catch (err) {
    const message = err instanceof Error ? err.message : 'unknown error';
    console.warn(`[plan-catalog] store read failed (${message}); serving defaults`);
    return DEFAULT_PLAN_CATALOG;
  }
}
