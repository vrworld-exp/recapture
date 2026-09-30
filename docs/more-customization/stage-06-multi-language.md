# ✅ Stage 6 — Multi-language menu

> **Status (2026-09-30): built, uncommitted; tests written, not yet run (run after the last
> stage).** Q3 answered: all 9 languages selectable (up to 3 per menu), **owner types
> everything** — no `POST /catalog/translate`, no provider.
>
> **API:** `MENU_LANGUAGES` (en + the 9), `Catalog.languages` (replaced on the profile PATCH;
> changing it touches every category so the planner re-pushes their names),
> `CatalogProduct.i18n` / `CatalogCategory.i18n` / `Catalog.i18n` (Mixed, **merged per
> language** with dotted `$set`/`$unset` — `null` or all-blank removes a language). Catalog-level
> text is `Catalog.i18n[lang] = { announcement, badges: { badgeId: label } }` rather than an
> `i18n` inside the announcement / badge blocks, so the Stage 4/5 editors (which replace those
> blocks whole) can never drop a translation. Keys are only checked against the language list,
> NOT against the enabled languages — text for a switched-off language is kept and simply not
> published. Publish: `services/catalog/menuTranslations.ts`; product translations are ONE new
> diffed field `i18n` (key of the enabled languages only; a pre-Stage-6 snapshot reads as
> empty, so no menu-wide republish); badge labels ride inside `details` only when translated
> (untranslated badges keep the old key); the announcement JSON carries `i18n`; restaurant gets
> `languages`. Tests: `tests/catalog-languages.test.ts`.
>
> **Mirage-be:** `helper/i18nFields.js`; item / category `i18n`, restaurant `languages`, badge +
> announcement `i18n` accepted and projected. Test: `test/i18nFields.test.js`.
>
> **Mirage-fe:** `src/i18n/` (`languages.ts`, `ui.ts`, `en.json` + `hi.json`,
> `MenuLanguageContext.tsx`), `features/menu/localize.ts` (items localized ONCE in MenuScreen;
> ids unchanged, `primaryName` kept for analytics), `LanguageSwitcher.tsx` (native `<select>` in
> the header, hidden with 0 extra), `<html lang>`, Noto fallback via `--font-script` appended to
> every font stack, `props.lang` on every event (only on a menu that offers a choice). Search
> matches either language. Test: `features/menu/languages.test.tsx`.
>
> **Flutter:** `domain/catalog/menu_languages.dart`, `MenuTranslationsRepository` (its own
> interface, so no existing test fake changed), Menu languages screen, Translations screen
> (per-language %, untranslated first, quick-edit dialogs for dishes / sections /
> announcement + badges), "Other languages" tile in the product editor (saves on its own
> call). Entry: catalog header ⋮ → *Languages & translations*. Test:
> `test/catalog/menu_languages_test.dart`.
>
> **Deviations / not done:** completeness is computed in the app from the product list (no
> separate endpoint); UI chrome ships in English + Hindi only — other languages show English
> chrome with the owner's translated text; the category manager has no language tabs (sections
> are translated on the Translations screen); rep surfaces have no translation editing yet
> (owner only, like Stage 5's badges); `client_page_view` fires before the restaurant (and so
> its languages) has loaded, so it carries no `lang` — later events do.

**Side:** recapture-api + Flutter + Mirage BE/FE.
**Depends on:** Stage 2 (Stage 3's `hindi` font pairing helps).
**Size:** L
**Blocked on:** ~~Q3~~ answered — see status.

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
