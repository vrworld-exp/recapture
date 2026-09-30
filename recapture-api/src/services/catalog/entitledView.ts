// src/services/catalog/entitledView.ts
//
// The catalog AS ITS PLAN ALLOWS IT TO BE PUBLISHED (more-customization
// Stage 8.1). Everything the plan does not cover is replaced by its default —
// never deleted: this is a read-only view built at publish time, and the
// owner's saved choices stay on the document, so an upgrade and a re-publish
// bring them straight back.
//
// With the gates flag off (today) the entitlements are FULL and this returns
// the catalog's own values unchanged.
import type { ICatalog } from '@/models/Catalog';
import type { CustomizationEntitlements } from '@/models/types/subscription.types';

/** The publish-relevant catalog fields, trimmed to what [e] covers. */
export type EntitledCatalogFields = Pick<
  ICatalog,
  'appearance' | 'badges' | 'languages' | 'arBranding' | 'spotlight' | 'engagement' | 'slug'
> &
  Partial<Pick<ICatalog, 'plate'>>;

export function entitledView<T extends EntitledCatalogFields>(
  catalog: T,
  e: CustomizationEntitlements
): T {
  const a = catalog.appearance;
  const appearance = a
    ? {
        ...(a.presetId !== undefined ? { presetId: a.presetId } : {}),
        ...(a.mode !== undefined ? { mode: a.mode } : {}),
        ...(e.customColors && a.primary ? { primary: a.primary } : {}),
        ...(e.customColors && a.accent ? { accent: a.accent } : {}),
        ...(e.layoutAndFonts && a.layout ? { layout: a.layout } : {}),
        ...(e.layoutAndFonts && a.fontId ? { fontId: a.fontId } : {}),
        ...(a.showFilters !== undefined ? { showFilters: a.showFilters } : {}),
      }
    : undefined;

  const engagement =
    catalog.engagement && e.engagement === 'review'
      ? catalog.engagement.reviewUrl
        ? {
            reviewUrl: catalog.engagement.reviewUrl,
            whatsappOrder: false,
            callWaiter: false,
            feedbackForm: false,
          }
        : undefined
      : catalog.engagement;

  // A plain object carrying the document's fields plus the trimmed ones. The
  // mirage* builders only READ properties, so a spread-free Object.create keeps
  // every other getter (name, contact, logoKey…) working on documents too.
  const view = Object.create(catalog) as T;
  Object.defineProperties(view, {
    appearance: { value: appearance, enumerable: true },
    badges: { value: (catalog.badges ?? []).slice(0, e.maxBadges), enumerable: true },
    languages: {
      value: catalog.languages
        ? { primary: catalog.languages.primary, extra: (catalog.languages.extra ?? []).slice(0, e.extraLanguages) }
        : catalog.languages,
      enumerable: true,
    },
    arBranding: { value: e.arBrandingAndSpotlight ? catalog.arBranding : undefined, enumerable: true },
    spotlight: { value: e.arBrandingAndSpotlight ? catalog.spotlight : undefined, enumerable: true },
    engagement: { value: engagement, enumerable: true },
    slug: { value: e.customDomain ? catalog.slug : undefined, enumerable: true },
    // Stage 11: not covered = sent as off. (Offers are a collection, not a
    // field; the branding sync drops them itself — see mirageStage7Fields.)
    plate: {
      value:
        e.plate === false
          ? { enabled: false, showTotal: catalog.plate?.showTotal !== false }
          : catalog.plate,
      enumerable: true,
    },
  });
  return view;
}
