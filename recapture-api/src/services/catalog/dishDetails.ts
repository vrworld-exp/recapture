// src/services/catalog/dishDetails.ts
//
// A product's badges and dietary detail as they are PUBLISHED (more-
// customization Stage 5).
//
// Badges live in the catalog's library (`Catalog.badges`) and a product holds
// only their ids. Mirage never joins: the publish step DENORMALISES each
// product's badges to `{ label, icon, color }` on the item. That is why the
// whole block travels as ONE diffed field (`details`, see publishPlanner): the
// key is built from the RESOLVED badges, so renaming "Chef's special" changes
// the key of every dish carrying it and the next publish updates them — while a
// product nobody touched keeps the same key and is skipped.
import type { CatalogBadge, MenuLanguage } from '@/models/types/catalog.types';

/** Stage 6: a badge's label per enabled language (menuTranslations.badgeTranslations). */
export type BadgeLabelTranslations = ReadonlyMap<string, Partial<Record<MenuLanguage, string>>>;

/** One badge as it travels to Mirage. `i18n` only when it has a translation. */
export interface PublishedBadge {
  label: string;
  icon: string;
  color: string;
  i18n?: Partial<Record<MenuLanguage, string>>;
}

export interface DishDetailsSource {
  badgeIds?: readonly string[];
  dietary?: readonly string[];
  allergens?: readonly string[];
  spiceLevel?: number | null;
  calories?: number | null;
  servesCount?: number | null;
  prepMinutes?: number | null;
}

export interface DishDetailsPayload {
  badges: PublishedBadge[];
  dietary: string[];
  allergens: string[];
  spiceLevel: number | null;
  calories: number | null;
  servesCount: number | null;
  prepMinutes: number | null;
}

const num = (v: number | null | undefined): number | null =>
  typeof v === 'number' && Number.isFinite(v) ? v : null;

/**
 * The block for one product, badges resolved against the library, in its order.
 *
 * Stage 6: a badge with a label in an enabled language carries it as `i18n`.
 * A badge WITHOUT one carries no `i18n` key at all, so every dish published
 * before Stage 6 keeps exactly the key it had — no menu-wide republish.
 */
export function dishDetailsOf(
  product: DishDetailsSource,
  library: readonly CatalogBadge[] | undefined,
  badgeLabels?: BadgeLabelTranslations
): DishDetailsPayload {
  const byId = new Map((library ?? []).map((b) => [b.id, b]));
  return {
    badges: (product.badgeIds ?? [])
      .map((id) => byId.get(id))
      .filter((b): b is CatalogBadge => Boolean(b))
      .map((b) => {
        const i18n = badgeLabels?.get(b.id);
        return {
          label: b.label,
          icon: b.icon,
          color: b.color,
          ...(i18n && Object.keys(i18n).length > 0 ? { i18n: { ...i18n } } : {}),
        };
      }),
    dietary: [...(product.dietary ?? [])],
    allergens: [...(product.allergens ?? [])],
    spiceLevel: num(product.spiceLevel),
    calories: num(product.calories),
    servesCount: num(product.servesCount),
    prepMinutes: num(product.prepMinutes),
  };
}

/**
 * The diff key: a stable JSON of the payload. Keys are written in a fixed
 * order, so the same content always gives the same string.
 */
export function dishDetailsKey(payload: DishDetailsPayload): string {
  return JSON.stringify({
    badges: payload.badges.map((b) => ({
      label: b.label,
      icon: b.icon,
      color: b.color,
      ...(b.i18n ? { i18n: b.i18n } : {}),
    })),
    dietary: payload.dietary,
    allergens: payload.allergens,
    spiceLevel: payload.spiceLevel,
    calories: payload.calories,
    servesCount: payload.servesCount,
    prepMinutes: payload.prepMinutes,
  });
}

/**
 * What a product with NONE of this reads as. A published snapshot written
 * before Stage 5 has no `details`; reading it as this key means only a product
 * someone actually gave a badge or diet info to plans an UPDATE — no one-time
 * republish of the whole menu.
 */
export const EMPTY_DISH_DETAILS_KEY = dishDetailsKey(dishDetailsOf({}, []));

/**
 * The multipart fields Mirage's item endpoints take (helper/dishDetailFields.js):
 * JSON arrays, numbers as strings, and `''` to CLEAR — every field always sent,
 * so removing a badge or an allergen reaches the menu.
 */
export function mirageDishFields(detailsKey: string): {
  badges: string;
  dietary: string;
  allergens: string;
  spiceLevel: string;
  calories: string;
  servesCount: string;
  prepMinutes: string;
} {
  const d = JSON.parse(detailsKey) as DishDetailsPayload;
  const n = (v: number | null) => (v === null ? '' : String(v));
  return {
    badges: d.badges.length ? JSON.stringify(d.badges) : '',
    dietary: d.dietary.length ? JSON.stringify(d.dietary) : '',
    allergens: d.allergens.length ? JSON.stringify(d.allergens) : '',
    spiceLevel: n(d.spiceLevel),
    calories: n(d.calories),
    servesCount: n(d.servesCount),
    prepMinutes: n(d.prepMinutes),
  };
}
