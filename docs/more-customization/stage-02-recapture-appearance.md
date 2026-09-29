✅✅✅✅✅✅
# Stage 2 — Appearance screen in ReCapture

**Side:** recapture-api + Flutter app.
**Depends on:** Stage 1 deployed to Mirage (else the field is stored but ignored — harmless).
**Size:** L

## Outcome

The owner (and a rep on a delegated catalog — Q2) opens **Catalog → Appearance**, taps a preset
card, optionally picks a primary/accent colour, sees a **live phone preview**, saves, and the next
**Publish** makes it live on Mirage.

---

## Part A — recapture-api

1. **Model** `models/Catalog.ts` — add an `appearance` subdocument (`_id: false`):

   ```ts
   export interface CatalogAppearance {
     presetId?: string;            // must be in THEME_PRESET_IDS
     mode?: 'dark' | 'light';      // optional override of the preset's mode
     primary?: string;             // '#RRGGBB'
     accent?: string;              // '#RRGGBB'
   }
   ```

   Type lives in `models/types/catalog.types.ts` next to `CatalogContact`. Later stages add to
   this same subdoc (layout, font, cover…) — **one** `appearance` object, not scattered fields.

2. **Preset mirror** `config/themePresets.ts` — `THEME_PRESET_IDS` + for each: label, mode, and
   the swatch hexes (bg, surface, text, primary, accent). Must match Mirage-fe `presets.ts`
   exactly; add a comment at the top of both files pointing at the other. Served to the app on
   `/remote-config` as a validated field (same pattern the plan catalog uses: its own Zod schema,
   reject-to-defaults) so new presets can appear without an app release.

3. **Validation** (Zod, next to the business-profile schema): `presetId` ∈ ids; colours
   `^#[0-9a-fA-F]{6}$`; contrast rules **exactly as Mirage-fe enforces them** in
   `src/theme/applyTheme.ts` (`primaryPasses` / `accentPasses` / `deriveFromPrimary`, built in
   Stage 1) — port that file's maths 1:1 and reuse its test vectors:
   - `primary` ≥ 4.5 vs its derived `onPrimary` (and both CTA gradient stops ≥ 4.5 vs it),
     and ≥ 3.0 vs the preset `bg` (price/icons are large + bold → AA-large);
   - `accent` ≥ 4.5 vs the preset `bg` and ≥ 3.0 vs black (Featured badge on the photo scrim).
   (A flat "primary vs bg ≥ 4.5" would reject Basalt's own red — 3.05:1 on #0B0B0E.)
   Failing → 400 `APPEARANCE_LOW_CONTRAST` with the failing pair. `null` on a key = clear it.
   Put the contrast function in `utils/colorContrast.ts` (pure, tested).

4. **Write path**: extend the business-profile update (or a new `PATCH /catalog/appearance`
   calling the **same** `applyCatalogPatch`) — must `$inc draftRevision` (D6). Rep twin route
   through `resolveDelegatedCatalog`, mirroring existing rep profile edits.

5. **DTO**: add `appearance` to `BusinessProfileDto` / `toBusinessProfileDto()` (field by field,
   no spread). Add `'appearance'` to `PUBLIC_PROFILE_FIELDS` so the app marks it as public.

6. **Sync**: in `syncCatalogBranding()` (`catalogProvisioningService.ts`), send
   `theme: JSON.stringify({ presetId, mode, primary, accent })` — always send every key, `''`
   for unset, same reasoning as `mirageLinks()` (an omitted key would leave a stale Mirage value).
   Add `theme` to `UpdateRestaurantInput` / `CreateRestaurantInput` in `mirageTypes.ts`,
   `fields` in `mirageClient.ts` create/update, and `toRestaurant()` parsing.

## Part B — Flutter

1. **Route** `appearance` under catalog in `lib/app/routes/app_router.dart`; entry tile on
   `catalog_screen.dart` and `business_profile_screen.dart` ("Appearance — colours & style").
2. **Screen** `lib/presentation/screens/catalog/appearance_screen.dart`:
   - Preset grid: cards showing a mini menu (bg, one dish card, primary button) per preset.
   - "Customize colours" expander: primary + accent pickers (a fixed swatch row of ~16 colours +
     hex input). Show an inline warning when contrast fails and disable Save.
   - Light/Dark toggle only if the preset allows both.
   - **Live preview**: `widgets/catalog/menu_theme_preview.dart` — a phone-frame widget rendering
     header (logo + name), 2 real product cards from this catalog, a category chip row, the
     primary button, in the selected tokens. Keep it a static approximation, not a WebView.
   - "Reset to default" → clears `appearance`.
   - Footer note: "Changes go live when you Publish." with a Publish shortcut.
3. **State**: `lib/application/catalog/appearance_notifier.dart` (Riverpod, same shape as
   `business_profile_notifier.dart`); repository methods in `business_profile_repository.dart`.
4. **Domain**: `lib/domain/catalog/appearance.dart` model + `color_contrast.dart` (same formula
   as the API — keep a shared test vector list so both agree).
5. **Web build**: screen must work on web (colour picker without platform plugins).

## Tests

- API: contrast util vectors; PATCH validates, bumps `draftRevision`, rep route needs delegation;
  `syncCatalogBranding` sends `theme` with all keys; old catalog with no appearance sends `''`s.
- Flutter: appearance notifier save/reset; preview widget golden for 2 presets; contrast warning
  disables Save.

## Done when

- [ ] Owner picks "Café", publishes, scans the QR → brown/cream menu on the phone.
- [ ] Custom primary that fails contrast cannot be saved (app) and is refused (API).
- [ ] Reset + publish → back to Basalt.
- [ ] Draft badge lights after an appearance edit and clears after publish.
- [ ] Rep can do the same on a delegated catalog (if Q2 = yes).
