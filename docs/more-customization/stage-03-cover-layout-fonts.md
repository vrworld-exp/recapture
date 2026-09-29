# Stage 3 — Cover image, layout style, fonts

**Side:** recapture-api + Flutter + Mirage BE/FE.
**Depends on:** Stage 2 (the `appearance` subdoc and screen).
**Size:** M

---

## 3.1 Cover image / hero banner

The upload half already exists: `Catalog.coverImageKey`, the branding-slot presign flow, and
`coverImageUrl` in `BusinessProfileDto`. Only the Mirage half is missing (README G2).

- **Mirage-be**: `restaurantModel.js` add `coverImage: { type: String, default: "" }`. In
  create/update accept `coverUrl` through `pickAssetSource(req.files?.cover?.[0], req.body.coverUrl, "cover")`
  (G3); `''` clears. Add `cover` to the multer fields list in `adminRouter.js`. Project
  `coverImage` in `itemController.js:561`.
- **ReCapture**: `syncCatalogBranding()` sends `coverUrl: cdnUrlForKey(coverImageKey) ?? ''`.
  Add `'coverImageUrl'` to `PUBLIC_PROFILE_FIELDS` and update the stale comment in
  `catalogService.ts` that says the cover never reaches the public page.
- **Mirage-fe** `MenuScreen.tsx` header: if `coverImage` set, render a 16:9 (max 220px tall)
  hero behind the logo + name with a bottom `card-fade` gradient; lazy + `fetchpriority=high`.
  No cover → today's header unchanged.
- **Flutter**: cover picker already exists on the profile screen? If not, add it there, with a
  1600×900 crop guide; show it in the Stage 2 preview.

## 3.2 Layout style

`appearance.layout: 'grid' | 'list' | 'large'` (default `grid` = today).

| Value | Card | Use case |
|---|---|---|
| `grid` | current 2-column `MenuItemCard` | default |
| `list` | row: 72px thumb left, name/desc/price right, compact | long menus, dhabas, bars |
| `large` | full-width photo card, 4:3 | few, photogenic dishes, cafés, desserts |

- Mirage-fe: `MenuList.tsx` picks the card variant; `MenuItemCard.tsx` gets a `variant` prop.
  AR / "View in 3D" affordance must exist in every variant; `arEnabled=false` behaviour unchanged.
- Optional per-category override `CatalogCategory.layout` (same enum, nullable = inherit).
  Needs a Mirage `categoryModel.js` field + projection. Ship restaurant-level first.
- ReCapture: enum on `appearance`, segmented control on the Appearance screen with thumbnails,
  reflected in the preview.

## 3.3 Font pairing

`appearance.fontId` from a curated list (D4), defined in Mirage-fe `src/theme/fonts.ts` and
mirrored in `config/themePresets.ts`:

| id | Heading / Body | Feel |
|---|---|---|
| `default` | current fonts | — |
| `classic` | Playfair Display / Inter | fine dine |
| `modern` | Poppins / Poppins | clean |
| `friendly` | Baloo 2 / Nunito | casual, supports Devanagari |
| `bold` | Bebas Neue / Roboto | street food |
| `elegant` | Cormorant Garamond / Lato | café, bakery |
| `hindi` | Tiro Devanagari Hindi / Mukta | Hindi-first menus (pairs with Stage 6) |

- Mirage-fe `applyTheme` injects the Google Fonts `<link>` (with `display=swap`, only the
  weights used) and sets `--font-heading` / `--font-body`. `default` loads nothing.
- Headings (restaurant name, category titles, dish names) use `font-[var(--font-heading)]`.

## Tests

- Mirage-be: cover via URL and via file; `''` clears; projection returns it.
- Mirage-fe: `MenuItemCard` renders all 3 variants with/without image, with/without AR.
- ReCapture: sync sends `coverUrl`, `layout`, `fontId`; unknown `fontId` → 400.

## Done when

- [ ] A restaurant with a cover shows the hero on the phone; one without looks unchanged.
- [ ] Switching layout to `list` and publishing changes the menu; AR still opens from a list row.
- [ ] Font choice visibly changes headings; Lighthouse LCP on 4G does not regress > 300ms.
