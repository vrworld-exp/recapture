// src/services/subscription/subscriptionGate.ts
//
// The two subscription publish gates — RECAPTURE_SUBSCRIPTION_PLAN.md §5 — and
// the switch that keeps them off until Stage 5.
//
// `evaluateSubscriptionGate` is PURE: a subscription row (or none) and a 3D
// count in, zero or one gates out. It reads nothing, so it can be pinned by a
// table of cases and the wiring in evaluatePublishGates stays a two-line
// addition. `isSubscriptionGateEnabled` is the only thing here that touches IO.
import type { ICatalogSubscription } from '@/models/CatalogSubscription';
import { isUncapped } from '@/models/types/subscription.types';
// Type-only, deliberately: catalogPublishService imports this file, and a
// value import back would make the two a require cycle.
import type { PublishGate, PublishGateCodeValue } from '@/services/catalogPublishService';
import { getServerFlag } from '@/services/remoteConfigService';

/** The `client_configs` key ops flip to turn the gates on. Absent = off. */
export const SUBSCRIPTION_GATES_FLAG_KEY = 'subscriptionGatesEnabled';

const SUBSCRIPTION_REQUIRED: PublishGateCodeValue = 'SUBSCRIPTION_REQUIRED';
const SUBSCRIPTION_CAPACITY_EXCEEDED: PublishGateCodeValue = 'SUBSCRIPTION_CAPACITY_EXCEEDED';

export type SubscriptionGateSubscription = Pick<
  ICatalogSubscription,
  'status' | 'threeDDishCap' | 'planId' | 'planSnapshot'
>;

export interface SubscriptionGateInput {
  /** The catalog's row, or null when it has none yet. */
  subscription: SubscriptionGateSubscription | null;
  /** From countThreeDDishes over the list the publish will send. */
  threeDDishCount: number;
}

/**
 * Rules, in order:
 *
 *   1. No row at all → SUBSCRIPTION_REQUIRED, whatever the menu holds. A
 *      catalog that has never been on any plan does not publish (§5).
 *   2. PAUSED / CANCELLED → SUBSCRIPTION_REQUIRED only when the menu carries
 *      ≥ 1 3D dish. A photo-only menu still publishes (README C5): the plan
 *      lapsing takes the AR away, not the menu.
 *   3. TRIAL / PENDING_PAYMENT / ACTIVE / GRACE / COMPED →
 *      SUBSCRIPTION_CAPACITY_EXCEEDED when the count is over a cap that exists.
 *      A comp is uncapped and never trips this; GRACE keeps full access but not
 *      extra capacity, so it can.
 *   4. Otherwise nothing. GRACE never produces a gate of its own — "your plan
 *      has lapsed, pay soon" is a banner (Stage 2), not a blocker.
 *
 * PENDING_PAYMENT FALLS THROUGH RULE 3 AND PASSES, which is the whole point of
 * requirement 2: a rep's publish goes live before anybody has paid. The
 * pressure is the deadline on the row, the banner on both UIs, and the sweep
 * that switches the page off — not a refusal here. What it does NOT get is
 * extra capacity: the window carries the trial's 3D cap and rule 3 enforces it,
 * so a rep cannot publish thirty free 3D dishes on a restaurant that owes us
 * money.
 */
export function evaluateSubscriptionGate(input: SubscriptionGateInput): PublishGate[] {
  const { subscription, threeDDishCount } = input;

  if (subscription === null) {
    return [
      {
        code: SUBSCRIPTION_REQUIRED,
        message: 'No subscription yet — start a free trial or activate a plan to publish.',
      },
    ];
  }

  if (subscription.status === 'PAUSED' || subscription.status === 'CANCELLED') {
    if (threeDDishCount >= 1) {
      return [
        {
          code: SUBSCRIPTION_REQUIRED,
          message: 'Your 3D menu needs an active plan. Photo-only menus can still be published.',
        },
      ];
    }
    return [];
  }

  const cap = subscription.threeDDishCap;
  if (!isUncapped(cap) && threeDDishCount > cap) {
    const planLabel = subscription.planSnapshot?.displayName ?? 'free trial';
    return [
      {
        code: SUBSCRIPTION_CAPACITY_EXCEEDED,
        message:
          `Menu has ${threeDDishCount} 3D dishes; your ${planLabel} covers ${cap}. ` +
          'Upgrade to publish all of them.',
        meta: {
          threeDDishCount,
          threeDDishCap: cap,
          ...(subscription.planId ? { planId: subscription.planId } : {}),
        },
      },
    ];
  }

  return [];
}

/**
 * Whether the gates run on this request. `true` only when ops has written
 * `subscriptionGatesEnabled: true` onto the config document; absent, false,
 * or a non-boolean all mean off.
 *
 * FAIL-OPEN on a store error — the OPPOSITE of the model-generation flags,
 * deliberately. Those fail closed because guessing wrong spends money. Here
 * guessing wrong would invent a paywall: an unreadable config must not turn
 * into "no subscription" and block every publish in the fleet. getServerFlag
 * throws on a store failure so callers decide; this caller decides "off".
 */
export async function isSubscriptionGateEnabled(): Promise<boolean> {
  try {
    return (await getServerFlag(SUBSCRIPTION_GATES_FLAG_KEY)) === true;
  } catch (err) {
    const message = err instanceof Error ? err.message : 'unknown error';
    console.warn(
      `[subscription-gate] could not read ${SUBSCRIPTION_GATES_FLAG_KEY} (${message}); ` +
        'gate disabled for this request'
    );
    return false;
  }
}
