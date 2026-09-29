# ✅ Stage 5 — Custom badges and dietary / allergen info

> **Status (2026-09-30): built, uncommitted; tests written, not yet run (run after the last
> stage).** Mirage-be: `helper/dishDetailFields.js`, item `badges` / `dietary` / `allergens` /
> `spiceLevel` / `calories` / `servesCount` / `prepMinutes`, restaurant `badges` + `showFilters`,
> all projected. Mirage-fe: `dishDetails.tsx` (`CustomBadge` in theme colours, `DishFacts`,
> filter rules + `DietFilterBar`), 2 badges on grid/large cards and list rows, all + facts in the
> detail sheet, filter bar under the tabs (AND, only relevant filters). API: `Catalog.badges`
> (profile PATCH, replace, server assigns ids, deleted badge `$pull`ed from products in the same
> request), product fields with `UNKNOWN_BADGE` / `DIET_CONFLICT` (judged on the end state),
> `appearance.showFilters`. Publish: ONE diffed field `details` (`services/catalog/dishDetails.ts`)
> built from RESOLVED badges — a rename re-publishes the dishes carrying it; an old snapshot reads
> as "none", so no menu-wide republish. Flutter: `badge_manager_screen.dart` (suggestions on first
> open, unsaved until Save), `dish_details_section.dart` in the product editor (saved via a
> separate `updateDishDetails` call), "Diet filters" switch on the Appearance screen.
> **Not done:** the REP dish editor has no badge / diet section yet (owner only); per-product
> badges are capped at 6 (the doc only said "max 2 shown").

**Side:** recapture-api + Flutter + Mirage BE/FE.
**Depends on:** Stage 2.
**Size:** M

Today a product has free-text `tags` (rendered as `TagChips`), a `featured` star, and the
tri-state `foodType`. This stage adds **visual badges** the owner designs once and reuses, and
**structured** dietary info customers can filter on. Tags stay as they are.

---

## 5.1 Badge library

- **ReCapture** `Catalog.badges: { id: string; label: string (≤ 18); icon: BadgeIcon; color: 'primary'|'accent'|'red'|'green'|'blue'|'orange' }[]`
  (max 12). `BadgeIcon` is a fixed enum mapped to lucide icons in Mirage-fe
  (`flame`, `star`, `sparkles`, `leaf`, `chef-hat`, `crown`, `heart`, `thumbs-up`, `clock`, `percent`).
- Seed on first open with suggestions (not saved until the owner saves):
  Bestseller, Chef's special, New, Spicy 🌶️, Must try, Limited.
- **Product** `CatalogProduct.badgeIds: string[]` (max 2 shown on a card). Deleting a badge
  pulls its id from all products in the same write (`updateMany $pull`).
- **Mirage**: restaurant `badges` array (replace), item `badges: {label, icon, color}[]`
  **denormalised by the publish worker** (so Mirage never has to join; a badge rename
  requires a publish, consistent with D6). Project both.
- **Mirage-fe** `ProductBadges.tsx`: new `CustomBadge` next to `FeaturedBadge`; card shows up to
  2, detail sheet shows all. Colours from theme tokens so they match every preset.
- **Flutter**: "Badges" manager (from catalog screen) + multi-select chips in
  `product_editor_screen.dart`.

## 5.2 Dietary and allergen info

- **ReCapture** `CatalogProduct.dietary: ('JAIN'|'VEGAN'|'GLUTEN_FREE'|'EGGLESS'|'SUGAR_FREE'|'KETO'|'HIGH_PROTEIN')[]`,
  `allergens: ('NUTS'|'DAIRY'|'GLUTEN'|'SOY'|'EGG'|'SHELLFISH'|'SESAME')[]`,
  `spiceLevel?: 0|1|2|3`, `calories?: number`, `servesCount?: number`, `prepMinutes?: number`.
- Keep `foodType` exactly as-is (see memory: tri-state, `isNonVeg` derived on Mirage). Validation:
  `VEGAN` or `JAIN` with `foodType = NON_VEG` → 400.
- **Mirage** item fields of the same names; projected publicly.
- **Mirage-fe**:
  - Detail sheet: allergen row ("Contains: nuts, dairy") + icons for dietary, chilli icons for spice,
    "Serves 2 · 15 min · 450 kcal" line — each only if set.
  - **Filter bar** (new, optional per restaurant `appearance.showFilters`): Veg only, Jain, Vegan,
    Gluten-free, "No nuts". Filters combine with category pills. Only show a filter if ≥ 1 item has it.
- **Flutter**: "Diet & allergens" collapsible section in the product editor with chip groups.

## Tests

- Badge delete pulls from products; worker denormalises label/icon/colour; rename + publish updates items.
- Dietary validation conflicts; filter logic (AND across filters, hides empty filters).
- Old items with none of the fields render unchanged (existing card tests pass).

## Done when

- [ ] Owner creates "Chef's special", puts it on 3 dishes, publishes → badge shows in theme colours.
- [ ] Customer taps "Jain" filter → only Jain dishes remain; filter hidden on a menu with none.
