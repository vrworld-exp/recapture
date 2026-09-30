// src/services/catalog/menuTranslations.ts
//
// Translations as they are PUBLISHED (more-customization Stage 6).
//
// The owner may keep text for a language they have switched off; only the
// catalog's ENABLED extra languages reach Mirage. Everything here filters to
// those, drops empty strings, and writes keys in a fixed order — so the same
// content always gives the same string, and the product's translations can
// travel as ONE diffed field (`i18n`, see publishPlanner) exactly like Stage 5's
// `details`. Turning a language on or off changes the key of every dish that
// has text in it, and the next publish updates just those dishes.
import {
  MENU_LANGUAGES,
  effectiveLanguages,
  type CatalogLanguages,
  type CatalogTranslations,
  type MenuLanguage,
} from '@/models/types/catalog.types';

/** Per-language text, filtered and ordered: `{ hi: { name, description } }`. */
export type PublishedTranslations = Partial<Record<MenuLanguage, Record<string, string>>>;

const textOf = (value: unknown): string | undefined =>
  typeof value === 'string' && value.trim() ? value.trim() : undefined;

/** The languages whose text is published — the enabled extras, in MENU_LANGUAGES order. */
export function publishedLanguages(catalog: { languages?: CatalogLanguages | null }): MenuLanguage[] {
  const { primary, extra } = effectiveLanguages(catalog);
  return MENU_LANGUAGES.filter((lang) => lang !== primary && extra.includes(lang));
}

/**
 * [raw] filtered to [languages] and [fields], in a fixed key order. A language
 * with no text left in it is dropped entirely.
 */
export function publishedTranslations(
  raw: unknown,
  languages: readonly MenuLanguage[],
  fields: readonly string[]
): PublishedTranslations {
  const out: PublishedTranslations = {};
  if (!raw || typeof raw !== 'object') return out;
  const byLang = raw as Record<string, unknown>;
  for (const lang of MENU_LANGUAGES) {
    if (!languages.includes(lang)) continue;
    const entry = byLang[lang];
    if (!entry || typeof entry !== 'object') continue;
    const texts: Record<string, string> = {};
    for (const field of fields) {
      const text = textOf((entry as Record<string, unknown>)[field]);
      if (text !== undefined) texts[field] = text;
    }
    if (Object.keys(texts).length > 0) out[lang] = texts;
  }
  return out;
}

/** The diff key. `publishedTranslations` already fixes the key order. */
export function translationsKey(value: PublishedTranslations): string {
  return JSON.stringify(value);
}

/**
 * What a dish with no published translations reads as. A snapshot written
 * before Stage 6 has no `i18n`; reading it as this means only a dish that
 * actually has text in an enabled language plans an UPDATE.
 */
export const EMPTY_TRANSLATIONS_KEY = translationsKey({});

/** The multipart value Mirage takes: JSON, or `''` to CLEAR — always sent. */
export function mirageTranslationsField(key: string | undefined): string {
  return !key || key === EMPTY_TRANSLATIONS_KEY ? '' : key;
}

/** A dish's published translations key (name + description). */
export function productTranslationsKey(
  product: { i18n?: unknown },
  languages: readonly MenuLanguage[]
): string {
  return translationsKey(publishedTranslations(product.i18n, languages, ['name', 'description']));
}

/** A category's published translations (name only), as the object Mirage stores. */
export function categoryTranslations(
  category: { i18n?: unknown },
  languages: readonly MenuLanguage[]
): PublishedTranslations {
  return publishedTranslations(category.i18n, languages, ['name']);
}

/** `{ hi: "आज 20% छूट" }` — the announcement text per enabled language. */
export function announcementTranslations(
  i18n: CatalogTranslations | undefined | null,
  languages: readonly MenuLanguage[]
): Partial<Record<MenuLanguage, string>> {
  const out: Partial<Record<MenuLanguage, string>> = {};
  for (const lang of languages) {
    const text = textOf(i18n?.[lang]?.announcement);
    if (text !== undefined) out[lang] = text;
  }
  return out;
}

/**
 * Badge id → `{ hi: "शेफ़ स्पेशल" }`, per enabled language. Consumed by
 * dishDetailsOf, which denormalises it onto each dish's badge copy.
 */
export function badgeTranslations(
  i18n: CatalogTranslations | undefined | null,
  languages: readonly MenuLanguage[]
): Map<string, Partial<Record<MenuLanguage, string>>> {
  const out = new Map<string, Partial<Record<MenuLanguage, string>>>();
  for (const lang of languages) {
    const labels = i18n?.[lang]?.badges;
    if (!labels || typeof labels !== 'object') continue;
    for (const [badgeId, label] of Object.entries(labels)) {
      const text = textOf(label);
      if (text === undefined) continue;
      const entry = out.get(badgeId) ?? {};
      entry[lang] = text;
      out.set(badgeId, entry);
    }
  }
  return out;
}

/** `restaurant.languages` as Mirage takes it — always sent, JSON. */
export function mirageLanguagesField(catalog: { languages?: CatalogLanguages | null }): string {
  const { primary } = effectiveLanguages(catalog);
  return JSON.stringify({ primary, extra: publishedLanguages(catalog) });
}

// ── Authoring writes ────────────────────────────────────────────────────────

/** Trims strings and drops empty strings / empty objects, recursively. */
function cleanTranslation(value: unknown): unknown {
  if (typeof value === 'string') return textOf(value);
  if (!value || typeof value !== 'object' || Array.isArray(value)) return undefined;
  const out: Record<string, unknown> = {};
  for (const [key, inner] of Object.entries(value as Record<string, unknown>)) {
    const cleaned = cleanTranslation(inner);
    if (cleaned !== undefined) out[key] = cleaned;
  }
  return Object.keys(out).length > 0 ? out : undefined;
}

/**
 * A per-language PATCH (`{ hi: {...}, ta: null }`) as dotted Mongo writes on
 * [path]. Only the languages named are touched: an entry with text REPLACES
 * that language, and `null` — or an entry left with nothing in it once blanks
 * are dropped — removes it.
 */
export function translationWrites(
  patch: Partial<Record<string, unknown>> | undefined,
  path = 'i18n'
): { set: Record<string, unknown>; unset: Record<string, 1> } {
  const set: Record<string, unknown> = {};
  const unset: Record<string, 1> = {};
  for (const [lang, entry] of Object.entries(patch ?? {})) {
    const cleaned = entry === null ? undefined : cleanTranslation(entry);
    if (cleaned === undefined) unset[`${path}.${lang}`] = 1;
    else set[`${path}.${lang}`] = cleaned;
  }
  return { set, unset };
}

/** The same patch as a whole object, for a CREATE (nothing to merge with). */
export function translationsForCreate(
  patch: Partial<Record<string, unknown>> | undefined
): Record<string, unknown> | undefined {
  const out: Record<string, unknown> = {};
  for (const [lang, entry] of Object.entries(patch ?? {})) {
    const cleaned = entry === null ? undefined : cleanTranslation(entry);
    if (cleaned !== undefined) out[lang] = cleaned;
  }
  return Object.keys(out).length > 0 ? out : undefined;
}
