// src/services/menuImport/sanitize.ts
//
// Menu import (more-customization Stage 13.1): turning what the model read from
// each page into ONE clean draft. Pure — no I/O — so messy model output is
// tested with literals.
//
// NEVER TRUST THE MODEL AS-IS. Structured outputs guarantee the SHAPE; this file
// enforces the SENSE: nameless dishes dropped, prices clamped to 0 < p < 100000
// (anything else becomes "no price"), strings trimmed and capped, sections with
// the same name on different pages merged, and a dish name used twice kept once
// (Mirage refuses two items with one name in a restaurant).

/** What one page's extraction looks like before cleaning (loose on purpose). */
export interface RawPage {
  currency?: unknown;
  categories?: unknown;
}

export interface DraftVariant {
  label: string;
  price: number;
}

export interface DraftItem {
  /** Stable within the import — the review screen and apply refer to it. */
  key: string;
  name: string;
  description: string | null;
  price: number | null;
  variants: DraftVariant[];
  foodType: 'VEG' | 'NON_VEG' | 'NONE';
  /** 0–1; below LOW_CONFIDENCE the review screen highlights it. */
  confidence: number;
  /** 1-based page (file) it came from. */
  sourcePage: number;
}

export interface DraftCategory {
  name: string;
  items: DraftItem[];
}

export interface MenuDraft {
  currency: string;
  categories: DraftCategory[];
  /** Dish names seen twice — kept once, listed so the reviewer knows. */
  duplicatesDropped: string[];
}

export const LOW_CONFIDENCE = 0.7;
export const MAX_PRICE = 100_000;
const NAME_MAX = 120;
const CATEGORY_MAX = 80;
const DESCRIPTION_MAX = 500;

const text = (v: unknown, max: number): string =>
  typeof v === 'string' ? v.replace(/\s+/g, ' ').trim().slice(0, max) : '';

/** "₹ 1,250", "250/-", 250 → 250; anything outside (0, MAX_PRICE) → null. */
export function cleanPrice(v: unknown): number | null {
  let n: number;
  if (typeof v === 'number') n = v;
  else if (typeof v === 'string') n = Number(v.replace(/[^\d.]/g, ''));
  else return null;
  if (!Number.isFinite(n) || n <= 0 || n >= MAX_PRICE) return null;
  return Math.round(n * 100) / 100;
}

/** The key a dish name is compared by: case, spacing and punctuation ignored. */
export const normalizeDishName = (name: string): string =>
  name
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, ' ')
    .trim();

const asArray = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const asRecord = (v: unknown): Record<string, unknown> =>
  v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : {};

/** Merges the pages (in order) into one draft. */
export function sanitizeMenu(pages: RawPage[]): MenuDraft {
  const byName = new Map<string, DraftCategory>();
  const seenDish = new Set<string>();
  const duplicatesDropped: string[] = [];
  let currency = '';
  let counter = 0;

  pages.forEach((page, pageIndex) => {
    if (!currency) currency = text(page.currency, 8).toUpperCase();
    for (const rawCategory of asArray(page.categories)) {
      const c = asRecord(rawCategory);
      const categoryName = text(c.name, CATEGORY_MAX) || 'Menu';
      const categoryKey = normalizeDishName(categoryName) || 'menu';
      let category = byName.get(categoryKey);
      for (const rawItem of asArray(c.items)) {
        const i = asRecord(rawItem);
        const name = text(i.name, NAME_MAX);
        if (!name) continue;
        const dishKey = normalizeDishName(name);
        if (!dishKey) continue;
        if (seenDish.has(dishKey)) {
          duplicatesDropped.push(name);
          continue;
        }
        seenDish.add(dishKey);

        const variants = asArray(i.variants)
          .map((v) => {
            const r = asRecord(v);
            const price = cleanPrice(r.price);
            const label = text(r.label, 30);
            return label && price !== null ? { label, price } : null;
          })
          .filter((v): v is DraftVariant => v !== null)
          .slice(0, 6);
        const price = cleanPrice(i.price) ?? variants[0]?.price ?? null;
        const confidence =
          typeof i.confidence === 'number' && Number.isFinite(i.confidence)
            ? Math.min(1, Math.max(0, i.confidence))
            : 0.5;
        const foodType = i.foodType === 'VEG' || i.foodType === 'NON_VEG' ? i.foodType : 'NONE';

        if (!category) {
          category = { name: categoryName, items: [] };
          byName.set(categoryKey, category);
        }
        counter += 1;
        category.items.push({
          key: `d${counter}`,
          name,
          description: text(i.description, DESCRIPTION_MAX) || null,
          price,
          // A single "variant" is just the price, not a choice.
          variants: variants.length > 1 ? variants : [],
          foodType,
          // A dish with no readable price is always worth a second look.
          confidence: price === null ? Math.min(confidence, LOW_CONFIDENCE - 0.01) : confidence,
          sourcePage: pageIndex + 1,
        });
      }
    }
  });

  return {
    currency: /^[A-Z]{3}$/.test(currency) ? currency : 'INR',
    categories: [...byName.values()].filter((c) => c.items.length > 0),
    duplicatesDropped,
  };
}

/** "Half ₹120 · Full ₹220" — how variants reach a product (dishes have one price). */
export function variantsLine(variants: DraftVariant[]): string {
  return variants.map((v) => `${v.label} ₹${v.price}`).join(' · ');
}
