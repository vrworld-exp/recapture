// src/services/subscription/customizationEntitlements.ts
//
// Which menu customizations a catalog's plan covers (more-customization
// Stage 8.1, Q4 answered 2026-09-30 with the proposed split):
//
//   Feature                         Taste (Basic)   Signature (Pro)   MasterChef (Premium)
//   theme presets                   ✓               ✓                 ✓
//   custom primary / accent         —               ✓                 ✓
//   cover image                     ✓               ✓                 ✓
//   layout + fonts                  —               ✓                 ✓
//   hours, announcement             ✓               ✓                 ✓
//   time-windowed categories        —               ✓                 ✓
//   badges                          3               12                12
//   diet detail / filters           ✓               ✓                 ✓
//   extra languages                 0               1                 3
//   AR branding, spotlight, pairings—               ✓                 ✓
//   customer buttons                review link     all               all
//   branded QR                      —               ✓                 ✓
//   custom subdomain                —               —                 ✓
//
// RULES (stage-08 §8.1):
//   • Enforced AT PUBLISH, never at save. The owner designs anything; the
//     publish sends the default for what the plan does not cover and the publish
//     status lists it as "held back". Nothing is ever refused, and nothing the
//     owner saved is deleted — upgrading and re-publishing restores it all.
//   • Behind `subscriptionGatesEnabled`: flag off (today) = everything allowed.
//   • A trial, a comp and the rep-publish window show the product at its BEST
//     (MasterChef) — the trial is the sales pitch. No row / paused / cancelled
//     is Taste. GRACE keeps the plan it came from.
//
// The table is the DEFAULT; ops may override a plan's `entitlements` through
// the plan catalog override like any other plan field (optional there, so an
// override written before this existed stays valid).
import { Types } from 'mongoose';

import { CatalogCategory } from '@/models/CatalogCategory';
import { CatalogProduct } from '@/models/CatalogProduct';
import { CatalogSubscription } from '@/models/CatalogSubscription';
import type { ICatalog } from '@/models/Catalog';
import type { CustomizationEntitlements, PlanId } from '@/models/types/subscription.types';
import { getPlanCatalog } from '@/services/subscription/planCatalogService';
import { isSubscriptionGateEnabled } from '@/services/subscription/subscriptionGate';

export type { CustomizationEntitlements };

export const FULL_CUSTOMIZATION: CustomizationEntitlements = {
  customColors: true,
  layoutAndFonts: true,
  categorySchedules: true,
  maxBadges: 12,
  extraLanguages: 3,
  arBrandingAndSpotlight: true,
  engagement: 'all',
  brandedQr: true,
  customDomain: true,
};

export const DEFAULT_PLAN_ENTITLEMENTS: Record<PlanId, CustomizationEntitlements> = {
  TASTE: {
    customColors: false,
    layoutAndFonts: false,
    categorySchedules: false,
    maxBadges: 3,
    extraLanguages: 0,
    arBrandingAndSpotlight: false,
    engagement: 'review',
    brandedQr: false,
    customDomain: false,
  },
  SIGNATURE: {
    ...FULL_CUSTOMIZATION,
    extraLanguages: 1,
    customDomain: false,
  },
  MASTERCHEF: { ...FULL_CUSTOMIZATION },
};

/** The lowest plan that covers each gated feature — for "needs Signature" copy. */
export const REQUIRED_PLAN: Record<HeldBackFeature, PlanId> = {
  customColors: 'SIGNATURE',
  layoutAndFonts: 'SIGNATURE',
  categorySchedules: 'SIGNATURE',
  badges: 'SIGNATURE',
  languages: 'SIGNATURE',
  arBranding: 'SIGNATURE',
  spotlight: 'SIGNATURE',
  pairings: 'SIGNATURE',
  engagement: 'SIGNATURE',
  brandedQr: 'SIGNATURE',
  customDomain: 'MASTERCHEF',
};

export type HeldBackFeature =
  | 'customColors'
  | 'layoutAndFonts'
  | 'categorySchedules'
  | 'badges'
  | 'languages'
  | 'arBranding'
  | 'spotlight'
  | 'pairings'
  | 'engagement'
  | 'brandedQr'
  | 'customDomain';

export interface HeldBackItem {
  feature: HeldBackFeature;
  requiredPlan: PlanId;
  message: string;
}

export interface ResolvedEntitlements {
  entitlements: CustomizationEntitlements;
  /** False while the gates flag is off — everything allowed, nothing held back. */
  enforced: boolean;
  /** The tier the entitlements came from, for copy; null = full (trial / comp / flag off). */
  planId: PlanId | null;
}

/** A stable string of the entitlements, for "did the plan change since the last publish". */
export function entitlementsKey(e: CustomizationEntitlements): string {
  return JSON.stringify([
    e.customColors,
    e.layoutAndFonts,
    e.categorySchedules,
    e.maxBadges,
    e.extraLanguages,
    e.arBrandingAndSpotlight,
    e.engagement,
    e.brandedQr,
    e.customDomain,
  ]);
}

/**
 * The catalog's customization entitlements. Fail-OPEN like every other
 * subscription read: a store error reads as "everything allowed", never as a
 * menu stripped of its colours.
 */
export async function resolveCustomizationEntitlements(
  catalogId: Types.ObjectId
): Promise<ResolvedEntitlements> {
  const full: ResolvedEntitlements = { entitlements: FULL_CUSTOMIZATION, enforced: false, planId: null };
  if (!(await isSubscriptionGateEnabled())) return full;

  try {
    const [subscription, catalog] = await Promise.all([
      CatalogSubscription.findOne({ catalogId }).lean().exec(),
      getPlanCatalog(),
    ]);
    const tier = tierFor(subscription);
    if (tier === null) return { ...full, enforced: true };
    const override = catalog.plans[tier]?.entitlements;
    return {
      entitlements: { ...DEFAULT_PLAN_ENTITLEMENTS[tier], ...(override ?? {}) },
      enforced: true,
      planId: tier,
    };
  } catch (err) {
    console.warn(
      `[entitlements] could not resolve for ${catalogId.toHexString()} (${(err as Error).message}); allowing all`
    );
    return full;
  }
}

/**
 * The tier whose entitlements apply, or null for FULL (trial / comp / window).
 * No row, paused or cancelled → Taste.
 */
function tierFor(
  subscription: { status: string; planId?: PlanId; planSnapshot?: { planId?: PlanId } } | null
): PlanId | null {
  if (!subscription) return 'TASTE';
  switch (subscription.status) {
    case 'TRIAL':
    case 'COMPED':
    case 'PENDING_PAYMENT':
      return null;
    case 'ACTIVE':
    case 'GRACE':
      // A grace that followed a trial has no plan — it keeps the trial's view.
      return subscription.planId ?? subscription.planSnapshot?.planId ?? null;
    default:
      return 'TASTE';
  }
}

/**
 * The held-back list for a catalog document, with the two lookups it needs.
 * Empty whenever the entitlements are not enforced (flag off, trial, comp).
 */
export async function heldBackForCatalog(
  catalog: Parameters<typeof heldBackFor>[0] & { _id: unknown },
  resolved: ResolvedEntitlements
): Promise<HeldBackItem[]> {
  if (!resolved.enforced) return [];
  const catalogId = catalog._id as Types.ObjectId;
  const [schedule, pairing] = await Promise.all([
    CatalogCategory.exists({ catalogId, deletedAt: null, schedule: { $ne: null } }).exec(),
    CatalogProduct.exists({
      catalogId,
      deletedAt: null,
      archivedAt: null,
      'pairsWith.0': { $exists: true },
    }).exec(),
  ]);
  return heldBackFor(catalog, resolved.entitlements, {
    hasCategorySchedules: schedule !== null,
    hasPairings: pairing !== null,
  });
}

const PLAN_LABEL: Record<PlanId, string> = {
  TASTE: 'Taste',
  SIGNATURE: 'Signature',
  MASTERCHEF: 'MasterChef',
};

/**
 * What the owner has CHOSEN that the plan does not cover — the "held back"
 * list the publish screen shows. Computed from the saved catalog, so it is
 * true before a publish ("this will be held back") and after one.
 */
export function heldBackFor(
  catalog: Pick<
    ICatalog,
    'appearance' | 'badges' | 'languages' | 'arBranding' | 'spotlight' | 'engagement' | 'qrStyle' | 'slug'
  >,
  e: CustomizationEntitlements,
  extras: { hasCategorySchedules: boolean; hasPairings: boolean }
): HeldBackItem[] {
  const out: HeldBackItem[] = [];
  const add = (feature: HeldBackFeature, what: string) =>
    out.push({
      feature,
      requiredPlan: REQUIRED_PLAN[feature],
      message: `${what} needs the ${PLAN_LABEL[REQUIRED_PLAN[feature]]} plan.`,
    });

  const a = catalog.appearance;
  if (!e.customColors && (a?.primary || a?.accent)) add('customColors', 'Custom colours');
  if (!e.layoutAndFonts && ((a?.layout && a.layout !== 'grid') || (a?.fontId && a.fontId !== 'default'))) {
    add('layoutAndFonts', 'Layout and fonts');
  }
  if (!e.categorySchedules && extras.hasCategorySchedules) add('categorySchedules', 'Section timings');
  if ((catalog.badges?.length ?? 0) > e.maxBadges) {
    out.push({
      feature: 'badges',
      requiredPlan: REQUIRED_PLAN.badges,
      message: `Your plan shows ${e.maxBadges} badges; the others need the Signature plan.`,
    });
  }
  const extra = catalog.languages?.extra?.length ?? 0;
  if (extra > e.extraLanguages) {
    out.push({
      feature: 'languages',
      requiredPlan: e.extraLanguages === 0 ? 'SIGNATURE' : 'MASTERCHEF',
      message:
        e.extraLanguages === 0
          ? 'Extra menu languages need the Signature plan.'
          : `Your plan shows ${e.extraLanguages} extra language; more need the MasterChef plan.`,
    });
  }
  if (!e.arBrandingAndSpotlight) {
    if (catalog.arBranding) add('arBranding', '3D & AR style');
    if (catalog.spotlight?.enabled && (catalog.spotlight.productIds?.length ?? 0) > 0) {
      add('spotlight', 'The spotlight carousel');
    }
    if (extras.hasPairings) add('pairings', '"Goes well with"');
  }
  const g = catalog.engagement;
  if (e.engagement === 'review' && g && (g.whatsappOrder || g.callWaiter || g.feedbackForm || g.wifi?.ssid)) {
    add('engagement', 'WhatsApp, waiter, Wi-Fi and feedback buttons');
  }
  if (!e.brandedQr && catalog.qrStyle) add('brandedQr', 'The branded QR');
  if (!e.customDomain && catalog.slug) add('customDomain', 'Your menu web address');
  return out;
}
