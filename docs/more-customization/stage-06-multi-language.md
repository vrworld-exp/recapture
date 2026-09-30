# Stage 6 — Multi-language menu

**Side:** recapture-api + Flutter + Mirage BE/FE.
**Depends on:** Stage 2 (Stage 3's `hindi` font pairing helps).
**Size:** L
**Blocked on:** Q3 (languages, machine translation yes/no).

## Outcome

Owner enables up to 3 extra languages (e.g. Hindi). The customer sees a language switcher on the
menu; dish names, descriptions, category names, badges and the announcement appear in that
language, falling back to the primary text wherever a translation is missing.

---

## Design

- **Primary language** stays in the existing fields (`name`, `description`) — nothing moves.
- Translations live **beside** them:

  ```ts
  type Translations = Partial<Record<LangCode, { name?: string; description?: string }>>;
  // LangCode: 'hi' | 'mr' | 'gu' | 'ta' | 'te' | 'kn' | 'bn' | 'pa' | 'ml'
  ```

  on `CatalogProduct.i18n`, `CatalogCategory.i18n`, `Catalog.i18n` (description, announcement text),
  badge `i18n` (label).
- `Catalog.languages: { primary: LangCode | 'en'; extra: LangCode[] (≤ 3) }`.
- **UI chrome** of the Mirage page ("View in AR", "Sold out", "Open now", filters) is translated by
  Mirage-fe itself: `src/i18n/{en,hi,…}.json` — not authored by owners.

## recapture-api

1. Schemas + Zod (length limits same as the primary field). `i18n` keys only allowed for
   languages in `Catalog.languages.extra` — a removed language's text is kept but not published.
2. Publish worker sends `i18n` as JSON string on item/category create/update; restaurant sync sends
   `languages` and `i18n`.
3. **Optional (Q3)**: `POST /catalog/translate` — machine-translates missing strings for one
   language into **draft** translations the owner reviews (never auto-published without review).
   Rate-limited per catalog; provider behind an interface; off unless its env key is set.
4. Completeness endpoint/DTO field: per language `% of items translated`, shown in the app.

## Mirage

- BE: `i18n` Mixed fields on restaurant/category/item (validated shape), `languages` on restaurant;
  projected publicly.
- FE: language switcher in the header (only if `languages.extra.length > 0`); default = browser
  language if offered, else primary; choice remembered in localStorage. A `t(item, 'name')` helper
  resolves translation → primary. Set `<html lang>`. Font fallback: if the chosen language uses a
  non-Latin script and the theme font lacks it, switch body/heading to a Noto family for that script.
- Analytics: add `lang` to menu-view events (`analyticsEventModel` props).

## Flutter

- Settings: "Menu languages" (pick up to 3).
- Product editor / category manager: language tabs above name + description.
- "Translations" screen: list of untranslated items per language, quick-edit, optional
  "Suggest translations" (if the translate endpoint is on).

## Tests

- Fallback: missing translation → primary; removed language not published; switcher hidden with 0 extra.
- Devanagari rendering snapshot; `<html lang>` updates.

## Done when

- [ ] Hindi enabled, 5 dishes translated → switching to हिन्दी shows those 5 in Hindi and the rest in English, no layout breakage.
- [ ] Menu with no extra languages looks unchanged (no switcher).
