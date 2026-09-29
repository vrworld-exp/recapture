# Stage 7 — AR branding, pairings, engagement buttons, branded QR

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
