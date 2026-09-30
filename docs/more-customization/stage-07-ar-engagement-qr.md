# ✅ Stage 7 — AR branding, pairings, engagement buttons, branded QR

> **Status (2026-09-30): built, uncommitted. NO tests written or run — the user asked for
> none from Stage 7 on; tests are written and run in the final pass.** Type-check /
> analyze of the touched files is clean.
>
> **7.1 viewer branding** — API `Catalog.arBranding` (profile PATCH, replace; null = plain);
> Mirage `restaurant.arBranding` (helper/extrasFields.js), also sent with
> `get-single-product` (+ `restaurantIcon`). Mirage-fe `ViewerBranding.tsx` (context, logo
> loader ring in `--c-primary`, watermark, name + price label) + `NewModelViewer` prop
> `branded` (detail sheet + AR page; grid cards get the loader only) + 4 SVG stage textures
> in `public/stages/` used as the viewer's backdrop (no model-viewer ground texture).
> Flutter `ar_style_screen.dart`, reached from a tile on the Appearance screen (owner only;
> it saves on its own, not with the appearance draft).
>
> **7.2 spotlight + pairings** — `Catalog.spotlight`, `CatalogProduct.pairsWith` (≤ 4,
> filtered on write to live dishes of the catalog, never itself). **Deviation: dishes are
> published by their stored NAME, not by Mirage item id** (`services/catalog/menuExtras.ts`) —
> names are unique per restaurant and known at plan time, so a pairing / spotlight dish
> created later in the same run still resolves; a rename changes the key and republishes.
> `pairsWith` is a new diffed product field (empty on an old snapshot → no republish).
> Mirage-fe resolves names from the loaded list (`itemsByName`). Flutter:
> `menu_extras_screen.dart` (Spotlight section) + `dish_pairings_tile.dart` in the editor.
>
> **7.3 customer buttons** — `Catalog.engagement` {reviewUrl (https), whatsappOrder,
> callWaiter, wifi, feedbackForm}. WhatsApp buttons need `contact.socials.whatsapp` (hidden
> without it). Rate-us prompt once per visitor after 60 s; call waiter reads `?t=`.
> Feedback: Mirage `feedbackModel` + `POST /analytics/feedback` (open like /collect, own
> limiter, 1 per visitor per day, refused unless the restaurant switched the form on) +
> admin `GET /analytics/feedback-report?restaurant=` (restaurant REQUIRED) +
> `/me/feedback-report`; API proxy `GET /catalog/analytics/feedback`. New event types
> `review_click`, `whatsapp_order`, `call_waiter`, `feedback_submitted` (Mirage enum + FE
> types) and KPIs `reviewClicks/whatsappOrders/waiterCalls/feedbackCount`. Flutter:
> `analytics_engagement_card.dart` (hidden when nothing happened).
>
> **7.4 branded QR** — `Catalog.qrStyle` (ReCapture-only; not a public field), Zod refuses
> light-on-dark and contrast < 4. `services/brandedQr.ts`: coloured PNG (+ frame-text band),
> owner logo in the well, PDF templates classic / minimal / bold (theme-primary band + cover)
> / tent (two faces, one turned 180°), code drawn as an `/ImageMask` in the fg colour. Every
> styled render is DECODED with jsQR first; failure → plain square + `X-Qr-Style-Fallback: 1`.
> `jsqr` moved from devDependencies to dependencies (lockfile `dev` flag removed). Plain
> squares (default style, reps, admin, standee batches) take the untouched byte-identical
> path. `POST /catalog/qr/preview` for the editor. Owner standee download: same counting,
> branded artwork. Flutter `qr_style_screen.dart` (presets, colours, logo, frame text,
> template, server preview), app-bar button on the QR screen.
>
> **Open / not done:** the frame-text band is rendered through librsvg — the server image
> needs a sans font installed or the text draws as boxes (check the Docker image); rep
> surfaces have no Stage 7 editing (owner only); scan with 3 phones is a manual check.

**Side:** recapture-api + Flutter + Mirage BE/FE.
**Depends on:** Stage 2. Independent parts — ship 7.1–7.4 separately.
**Size:** L (four S/M parts)

This is the part competitors can't copy easily: the AR experience itself carries the brand.

---

## 7.1 Branded AR / 3D viewer

`Catalog.arBranding: { watermarkLogo: boolean; loaderStyle: 'default'|'logo'; stage: 'none'|'plate'|'wood'|'marble'|'dark'; showDishName: boolean }`

- **Mirage-fe** (`NewModelViewer.tsx`, `ArModel.tsx`):
  - `loaderStyle: 'logo'` → restaurant logo pulsing with a progress ring in `--c-primary` instead
    of the generic loader (`MobleQrLoadingScreen.tsx`).
  - `watermarkLogo` → small logo overlay in the 3D viewer corner (not inside the AR camera
    session — Scene Viewer / Quick Look can't be overlaid; document that limitation in the app).
  - `stage` → background environment / ground under the model in the in-page 3D viewer only
    (model-viewer `environment-image` + a ground-plane texture). Ship 4 textures in `public/stages/`.
  - `showDishName` → name + price label in the viewer.
  - Respect `arEnabled=false` exactly as today — none of this appears then.
- **Mirage-be**: `arBranding` object (merge), projected.
- **Flutter**: "3D & AR style" section on the Appearance screen with a preview of each stage.

## 7.2 Spotlight carousel + "goes well with" pairings

- `Catalog.spotlight: { enabled: boolean; productIds: string[] (≤ 6); title?: string }` — a
  horizontal hero carousel at the top of the menu (3D-capable dishes get a "View in AR" CTA).
  Worker maps product ids → Mirage item ids at publish; missing/archived ids are dropped silently.
- `CatalogProduct.pairsWith: productId[]` (≤ 4) → detail sheet section "Goes well with" with
  tappable mini-cards. Same id mapping in the worker.
- Mirage-be: `spotlight` on restaurant, `pairsWith: itemId[]` on item; FE resolves from the
  already-loaded item list (no extra request).

## 7.3 Engagement buttons

`Catalog.engagement`:

| Key | Mirage-fe behaviour |
|---|---|
| `reviewUrl` (Google review link) | "Rate us ⭐" button in header/contact sheet; optional prompt after 60s on page (once per visitor) |
| `whatsappOrder: boolean` | "Order on WhatsApp" on the detail sheet → `wa.me/<socialLinks.whatsapp>?text=` prefilled with dish name + price. Hidden if no WhatsApp number. |
| `callWaiter: boolean` | "Call waiter" floating button → WhatsApp message "Table __ needs assistance" (table number via `?t=` query on table QR, else asks) |
| `wifi: { ssid, password? }` | "Wi-Fi" chip in contact sheet with copy button |
| `feedbackForm: boolean` | simple 1–5 + comment, POSTed to Mirage `/feedback` → surfaced in ReCapture analytics screen (new collection; rate-limit per visitor) |

- Emit analytics events for each tap (`review_click`, `whatsapp_order`, `call_waiter`) so
  `catalog_analytics_screen.dart` can show them.

## 7.4 Branded QR + standee templates

Builds on `catalogQrService.ts` and the owner standee download (memory: counted A4 standees,
one shared lifetime pool — **do not** change the counting rules).

- `Catalog.qrStyle: { fg: '#RRGGBB'; bg: '#RRGGBB'; logoCenter: boolean; frameText?: string (≤ 30, e.g. "Scan for 3D menu") ; template: 'classic'|'minimal'|'tent'|'bold' }`.
- `catalogQrService` renders fg/bg (validate contrast ≥ 4:1 and dark-on-light only — inverted
  QRs fail on many scanners), logo in centre with error-correction level **H**, frame text.
- **Test scannability**: decode every rendered variant in a unit test (use a JS QR decoder)
  before returning it; if decode fails fall back to plain black/white and log.
- Standee PDF templates take theme colours + cover image. The counted download flow is unchanged;
  only the artwork differs.
- Flutter: QR style editor on `catalog_qr_screen.dart` with live preview.

## Done when

- [ ] 3D viewer shows the restaurant logo loader and marble stage; AR launch still works on Android + iOS.
- [ ] Spotlight shows 4 chosen dishes; "Goes well with" links open the paired dish.
- [ ] WhatsApp order opens with the dish prefilled; hidden when no number.
- [ ] Branded QR scans with 3 different phones' stock cameras.
