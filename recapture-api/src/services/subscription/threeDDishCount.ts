// src/services/subscription/threeDDishCount.ts
//
// Which dishes count against a plan's 3D cap — RECAPTURE_SUBSCRIPTION_PLAN.md
// §3b, in one place so the request-time gate and the worker's audit write can
// never disagree about the rule.
//
// PURE. No IO, no clock, no model imports beyond types. The caller hands in
// the list it is about to publish — `publishableProducts()` at request time,
// the snapshot's products in the worker — and this file does NOT re-filter
// `deletedAt` / `archivedAt`. That is deliberate (README C1): the count must be
// derived from exactly the list the publish sends, and a second filter here
// would be a second opinion about what that list is.
import { effectiveModelStatus, type ProductModelStatus } from '@/models/types/catalog.types';

/** The minimum a product needs to carry for the rule to be decidable. */
export interface ThreeDCountable {
  modelStatus?: ProductModelStatus;
  assets?: { glbUrl?: string };
}

/**
 * A dish counts as 3D when it has a usable model RIGHT NOW — `READY`, and
 * ONLY that. A THREE_D product still generating, or whose generation failed,
 * is a photo dish because that is what the customer will see (§3b). A product
 * whose REPLACEMENT is generating reads PROCESSING from effectiveModelStatus
 * and therefore does not count either, even though it still carries its old
 * GLB and will publish with it — the cap is about what the plan is being asked
 * to cover next, and that is settled when the new model lands.
 *
 * Reads the status through `effectiveModelStatus`, never raw — a legacy row
 * with a `glbUrl` and no stored status is READY, and must count.
 */
export function countsAsThreeD(product: ThreeDCountable): boolean {
  return effectiveModelStatus(product) === 'READY';
}

export function countThreeDDishes(products: readonly ThreeDCountable[]): number {
  let count = 0;
  for (const product of products) if (countsAsThreeD(product)) count += 1;
  return count;
}
