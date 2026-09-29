# ✅ Stage 1 — Theme foundations (Mirage only)

> **Status (2026-09-29): built, tests green, not yet committed.** mirage-fe `src/theme/`
> (presets, `applyTheme.ts`, 18 tests), token swap in the menu, boot script in `index.html`;
> mirage-be `theme` field + `parseThemeField` + `test/theme.test.js` (`npm test`).
> Still open: the manual screenshot / phone checks below.

**Side:** Mirage BE + Mirage FE. ReCapture is untouched.
**Ships behind:** nothing. A restaurant with no `theme` renders exactly as today.
**Size:** M

## Why this stage exists

Mirage-fe cannot be themed today: its palette is hardcoded in `tailwind.config.js:33-60` and in
component literals (`MenuScreen.tsx:663` `bg-[#000000aa]`, `:848` `bg-[#1a1a24]`, the white modal
at `:867`, `ProductBadges.tsx` `bg-black/50`…). This stage makes the palette **data-driven** and
adds a place to store a theme, without changing a single pixel for existing restaurants.

---

## Part A — Mirage-fe: tokens become CSS variables

1. In `src/index.css` `:root`, define the full token set (current values = the default "Basalt" look):

   ```css
   :root {
     --c-bg: 11 11 14;          /* #0B0B0E  — stored as R G B so Tailwind alpha works */
     --c-surface: 21 21 24;     /* #151518 */
     --c-surface-2: 26 26 36;   /* #1a1a24 */
     --c-text: 245 245 247;     /* #F5F5F7 */
     --c-text-2: 179 179 184;   /* #B3B3B8 */
     --c-primary: 225 6 0;      /* #E10600 accent.red */
     --c-accent: 201 162 77;    /* #C9A24D accent.gold */
     --c-overlay: 0 0 0;        /* header / sheet scrims */
     --radius-card: 20px;
     --font-heading: inherit;
     --font-body: inherit;
   }
   ```

2. In `tailwind.config.js`, point the existing token names at the variables so **no class name
   changes**: `'bg': { base: 'rgb(var(--c-bg) / <alpha-value>)' }`, `surface.1`, `text.primary`,
   `text.secondary`, `accent.red → --c-primary`, `accent.gold → --c-accent`. Add `surface.2`
   and `overlay`. Update `red-energy`, `card-fade`, `red-glow` to use the variables.
3. Replace hex literals in the menu feature (`src/features/menu/**`, `components/layout/**`)
   with token classes (`bg-[#1a1a24]` → `bg-surface-2`, `bg-[#000000aa]` → `bg-overlay/65`).
   Grep target: `rg "#[0-9a-fA-F]{3,8}" src/features/menu src/components/layout` should return
   only SVG/QR literals afterwards. Leave admin/photographer screens alone.
4. Existing `--bg-theme`, `--accent-red`, `--text-primary`, `--text-secondary` in `index.css`
   become aliases of the new variables so the old CSS keeps working.

**Gate:** screenshot the menu of 2 real restaurants before and after — they must be identical.

## Part B — Mirage-fe: presets and applying a theme

1. New `src/theme/presets.ts`:

   ```ts
   export type ThemeMode = 'dark' | 'light';
   export interface ThemePreset {
     id: string; label: string; mode: ThemeMode;
     tokens: Record<'bg'|'surface'|'surface2'|'text'|'text2'|'primary'|'accent'|'overlay', string>; // hex
     radius?: number;
   }
   export const DEFAULT_PRESET_ID = 'basalt';
   export const PRESETS: Record<string, ThemePreset> = { /* see table */ };
   ```

   | id | Label | Mode | Feel |
   |---|---|---|---|
   | `basalt` | Basalt (current) | dark | black + red + gold — **default** |
   | `midnight-gold` | Fine Dine | dark | navy + gold |
   | `espresso` | Café | dark | coffee brown + cream |
   | `street` | Street Food | dark | charcoal + yellow |
   | `garden` | Fresh & Green | light | off-white + leaf green |
   | `bakery` | Bakery | light | cream + pastel pink |
   | `ocean` | Seafood | light | white + deep teal |
   | `royal` | Royal Indian | dark | maroon + saffron |

2. New `src/theme/applyTheme.ts`:
   - `resolveTheme(raw: unknown): ResolvedTheme` — unknown `presetId` → default; `primary`/`accent`
     overrides accepted only if valid `#RRGGBB` **and** contrast ≥ 4.5 against the preset's `text`
     (or `bg` for primary buttons, whichever the component uses) — else fall back to the preset's
     value (D3). Pure function, unit-tested.
   - `applyTheme(t)` — writes the variables onto `document.documentElement.style`, sets
     `data-theme-mode`, and updates `<meta name="theme-color">`.
3. **No flash:** in `useFetchApiForNewUi.ts`, apply the theme from the **cached**
   `restaurantData` synchronously before the first render (the cache already exists at lines 71-92),
   then re-apply when the fresh response arrives. Also add a tiny inline script in `index.html`
   that reads the same localStorage key and sets the variables before React boots.
4. Light mode check: walk every menu surface (grid, detail sheet, AR modal, contact sheet
   `BusinessLinks.tsx`, `PaymentDueBanner.tsx`, `CatalogUnavailable.tsx`) under `garden` and fix
   anything that assumed a dark background (white-on-white text, `bg-black/50` badges).
5. Add `theme?: RestaurantTheme` to `TypeRestaurantData` (`src/Types.ts`).

## Part C — Mirage-be: store and serve the theme

1. `restaurantModel.js` — add:

   ```js
   theme: {
     presetId: { type: String, trim: true, default: "" },   // "" = default look
     mode:     { type: String, enum: ["", "dark", "light"], default: "" },
     primary:  { type: String, trim: true, default: "" },  // "#RRGGBB" or ""
     accent:   { type: String, trim: true, default: "" },
   },
   ```

2. `adminController.js` create + update restaurant: accept `theme` via `parseObjectField`
   (same as `socialLinks`), **merge key by key** like socialLinks does, validate each key
   (`presetId` ≤ 40 chars `[a-z0-9-]`, colours `^#[0-9a-fA-F]{6}$` or `''`), 400 on bad input.
3. `itemController.js:561` public projection: add `theme: restaurantDetails?.theme || {}`.
4. Mirage admin UI: no change this stage (optional read-only display).

## Tests

- Mirage-fe: `applyTheme.test.ts` — unknown preset → basalt; bad hex → preset value; low-contrast
  override → preset value; light preset sets `data-theme-mode="light"`.
- Mirage-fe: existing `MenuItemCard.test.tsx` / `PaymentDueBanner.test.tsx` still pass unchanged.
- Mirage-be: update-restaurant with `theme` JSON string merges; invalid colour → 400; omitted
  `theme` leaves stored value alone; public endpoint returns `theme`.

## Done when

- [ ] Menu of an existing restaurant is visually identical before/after (screenshots attached).
- [ ] Setting `theme.presetId = "garden"` directly in Atlas turns that one menu light, with no
      unreadable text anywhere, including AR modal and contact sheet.
- [ ] Reloading a themed menu shows **no** flash of the Basalt colours.
- [x] Older ReCapture (no `theme` sent) publishes without touching the stored theme. *(unit-tested: absent `theme` → untouched)*
