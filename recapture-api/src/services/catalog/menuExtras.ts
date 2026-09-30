// src/services/catalog/menuExtras.ts
//
// Stage 7's published blocks (more-customization): the 3D viewer's branding,
// the spotlight carousel, the customer buttons, and each dish's "goes well
// with" list.
//
// DISHES ARE REFERRED TO BY THEIR STORED NAME, NOT BY MIRAGE ITEM ID. Names are
// unique per restaurant on Mirage (its create-item refuses a duplicate), and the
// public page already has every item — so it resolves a name from the list it
// loaded, with no extra request. An id would need the partner to exist on
// Mirage BEFORE the dish pointing at it is pushed, which a first publish of a
// new menu cannot promise (products are created in position order). A name is
// known at plan time. A rename changes the name, which changes the key of every
// dish pairing with it, so the next publish updates them too.
import { Types } from 'mongoose';

import { CatalogProduct } from '@/models/CatalogProduct';
import type { ICatalog } from '@/models/Catalog';
import { toCatalogSlug } from '@/utils/catalogNames';

/** The name Mirage stores for a product (productSync's `mirageProductName`). */
export const publishedDishName = (name: string): string => toCatalogSlug(name, { maxLength: 120 });

// ── Pairings (a diffed product field) ──────────────────────────────────────

/** `["dal_makhani","jeera_rice"]`, in the owner's order, only dishes still on the menu. */
export function pairingsKey(
  pairsWith: readonly (Types.ObjectId | string)[] | undefined,
  liveNames: ReadonlyMap<string, string>
): string {
  const names = (pairsWith ?? [])
    .map((id) => liveNames.get(typeof id === 'string' ? id : id.toHexString()))
    .filter((name): name is string => Boolean(name))
    .map(publishedDishName);
  return JSON.stringify(names);
}

/** What a dish with no pairings reads as — and what a pre-Stage-7 snapshot means. */
export const EMPTY_PAIRINGS_KEY = '[]';

/** The multipart value: the JSON list, or `''` to CLEAR — always sent. */
export function miragePairsField(key: string | undefined): string {
  return !key || key === EMPTY_PAIRINGS_KEY ? '' : key;
}

// ── Restaurant blocks (sent on every branding sync) ────────────────────────

/** `restaurant.arBranding` as JSON, or `''` for the plain viewer. */
export function mirageArBrandingField(catalog: Pick<ICatalog, 'arBranding'>): string {
  const a = catalog.arBranding;
  if (!a) return '';
  return JSON.stringify({
    watermarkLogo: a.watermarkLogo === true,
    loaderStyle: a.loaderStyle ?? 'default',
    stage: a.stage ?? 'none',
    showDishName: a.showDishName === true,
  });
}

/** `restaurant.engagement` as JSON, or `''` for no buttons. */
export function mirageEngagementField(catalog: Pick<ICatalog, 'engagement'>): string {
  const e = catalog.engagement;
  if (!e) return '';
  return JSON.stringify({
    reviewUrl: e.reviewUrl ?? '',
    whatsappOrder: e.whatsappOrder === true,
    callWaiter: e.callWaiter === true,
    wifi: e.wifi?.ssid ? { ssid: e.wifi.ssid, password: e.wifi.password ?? '' } : null,
    feedbackForm: e.feedbackForm === true,
  });
}

/**
 * `restaurant.spotlight` as JSON (`{ enabled, title, items: [name] }`), or `''`.
 * Reads the spotlighted products' CURRENT names, dropping any archived or
 * deleted one — so it is async, and resolved at sync time, not at edit time.
 */
export async function mirageSpotlightField(
  catalog: Pick<ICatalog, 'spotlight'> & { _id: unknown }
): Promise<string> {
  const s = catalog.spotlight;
  if (!s || !s.enabled || (s.productIds ?? []).length === 0) return '';
  const ids = s.productIds.filter((id) => Types.ObjectId.isValid(id));
  const rows = await CatalogProduct.find({
    _id: { $in: ids.map((id) => new Types.ObjectId(id)) },
    catalogId: catalog._id,
    deletedAt: null,
    archivedAt: null,
  })
    .select({ _id: 1, name: 1 })
    .lean()
    .exec();
  const byId = new Map(rows.map((r) => [(r._id as Types.ObjectId).toHexString(), r.name]));
  const items = ids.map((id) => byId.get(id)).filter((n): n is string => Boolean(n));
  if (items.length === 0) return '';
  return JSON.stringify({
    enabled: true,
    title: s.title ?? '',
    items: items.map(publishedDishName),
  });
}
