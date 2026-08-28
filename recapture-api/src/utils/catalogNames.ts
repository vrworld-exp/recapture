// src/utils/catalogNames.ts
//
// The ONE place a catalog, category or product NAME is turned into its stored
// form.
//
// Mirage slugifies every name it is given — `toCatalogSlug` in
// mirage-be/src/helper/helper.js:162 — because the name is written into a public
// URL and an S3 key, so `"Testing 02"` is stored there as `"testing_02"`.
// ReCapture used to keep the raw, spaced form and convert only on the way out
// to Mirage, which left the two databases holding DIFFERENT strings for the same
// thing: every name comparison across the boundary (restaurant adoption,
// category adoption, the publish diff) then had to normalise first, and any path
// that forgot to would silently create a duplicate instead of matching.
//
// So ReCapture now stores exactly what Mirage stores. The functions below are a
// FAITHFUL PORT of Mirage's, and must stay that way — if that file's rules
// change, these change with it, or the two sides diverge again in a way nothing
// fails loudly about.
//
// ⚠ Deliberately NOT applied to `Catalog.businessName`: that is customer-facing
// branding, never an identifier, and Mirage has no field it maps to.

/**
 * The stored form of a name: lowercase, underscore-separated, ASCII-ish.
 *
 * Order matters. Accents are folded onto their base letter BEFORE the strip,
 * or the strip eats them outright and "Café" becomes "caf".
 *
 * Returns `''` for input that has no letters or digits at all ("!!!", "   ",
 * an all-emoji name). Callers must treat that as a rejection rather than
 * storing it — the validation layer does, via {@link isValidCatalogSlug}.
 *
 * [maxLength] defaults to each field's own bound rather than a global one, so
 * this never truncates a name the schema already accepted. NOTE Mirage caps its
 * own slugs at 60, so a longer name is stored in full here and truncated there;
 * that divergence predates this module and is unchanged by it.
 */
export function toCatalogSlug(
  value: string | null | undefined,
  { maxLength = 120 }: { maxLength?: number } = {}
): string {
  if (value === undefined || value === null) return '';

  return (
    String(value)
      .trim()
      .toLowerCase()
      .normalize('NFD')
      .replace(/\p{Diacritic}/gu, '')
      // Every separator an admin might type collapses to the same one.
      .replace(/[\s\-.]+/g, '_')
      // Anything that is not a letter, digit or underscore is DROPPED rather
      // than transliterated — it would end up in a URL and an S3 key.
      .replace(/[^a-z0-9_]/g, '')
      .replace(/_+/g, '_')
      .replace(/^_+|_+$/g, '')
      .slice(0, maxLength)
      .replace(/_+$/g, '')
  );
}

/** Did [value] survive slugging? `false` means "there was no name in there". */
export function isValidCatalogSlug(value: string): boolean {
  return value.length > 0;
}

/**
 * The spaced form, for display or for pre-filling an input.
 *
 * The API does NOT apply this to responses: the client is shown the stored
 * name, which is what Mirage will show too, so the two never disagree. It is
 * here for the same reason Mirage has it — a UI that wants a friendlier label.
 */
export function toDisplayName(value: string | null | undefined): string {
  return value === undefined || value === null ? '' : String(value).replace(/_/g, ' ').trim();
}

/**
 * A regex body matching a stored slug whatever separator the caller typed.
 *
 * A search box or a hand-typed link can arrive as "cafe mocha", "cafe-mocha" or
 * "cafe_mocha"; all three have to find the one stored "cafe_mocha". Literal
 * chunks are escaped, so user text with regex metacharacters is matched as
 * text.
 *
 * Returns `''` when the input is all separators — a caller must treat that as
 * "no usable pattern" rather than dropping an empty (match-everything) regex
 * into a filter.
 */
export function flexibleSlugRegex(
  value: string,
  { anchored = false }: { anchored?: boolean } = {}
): string {
  const separatorClass = '[\\s_.-]*';

  const body = String(value)
    .trim()
    .toLowerCase()
    .split(/[\s_.-]+/)
    .filter(Boolean)
    .map((chunk) => chunk.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
    .join(separatorClass);

  if (!body) return anchored ? '^$' : '';

  return anchored ? `^${body}$` : body;
}

/**
 * Joins a disambiguating suffix onto an already-slugged name.
 *
 * Every auto-generated name in the codebase (a duplicate's "(copy)", a
 * provisioning "2") goes through this, so none of them can put a space back
 * into a slug by string-concatenating one.
 */
export function appendSlugSuffix(base: string, suffix: string | number): string {
  return toCatalogSlug(`${base}_${suffix}`);
}
