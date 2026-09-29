# More Customization — Implementation Pack

Goal: every Mirage menu should look and feel like **its own restaurant**, not like the same dark
Basalt page with a different logo. The owner (or the rep on their behalf) controls all of it from
ReCapture; Mirage only renders what it is sent.

**Conventions source of truth:** [`../../AGENTS.md`](../../AGENTS.md). Every stage defers to it.
**This folder:** *what to build, in what order, in which file, and how you know it worked.*

---

## What a client can customize today (verified against the working tree, 2026-09-29)

| Surface | Field | Where |
|---|---|---|
| Restaurant | name, logo (`icon`), description, phone, address/location, website, socials | `Catalog` → `syncCatalogBranding()` (`catalogProvisioningService.ts:631`) → Mirage `update-restaurant` |
| Restaurant | `arEnabled`, `clientType` (`3D_ONLY`/`BOTH`), `bottomViewShow` | Mirage `restaurantModel.js` (arEnabled is driven by subscription, not the owner) |
| Product | name, description, price, currency, category, `tags`, `availability`, `featured`, `foodType`, `position` | `CatalogProduct.ts` → publish worker |
| Category | name, image, `sortPosition` | `CatalogCategory.ts` / Mirage `categoryModel.js` |

### Gaps that shape this plan

| # | Finding | Consequence |
|---|---|---|
| G1 | Mirage-fe colours are **hardcoded** Tailwind hex (`tailwind.config.js:33-60`: `bg.base`, `surface.1`, `accent.red`, `accent.gold`…) plus literals in components (`MenuScreen.tsx:663` `bg-[#000000aa]`, `:848` `bg-[#1a1a24]`). | Nothing can be themed until these become CSS variables. **Stage 1 is a refactor with zero visual change.** |
| G2 | `Catalog.coverImageKey` already exists and uploads work, but "the cover has no Mirage counterpart at all and never reaches the public page" (`catalogService.ts`, Branding images comment). | The cover is half-built — Stage 3 only has to carry it across. |
| G3 | Mirage's asset intake is `pickAssetSource(file, url, kind)` (`adminController.js:643`) — it accepts a URL as well as a file. | The cover (and any later image) can travel as its CloudFront URL; no re-upload through Mirage. |
| G4 | Mirage's multipart transport sends every field as a string; objects go through `parseObjectField` and `''` means *clear* (`mirageClient.ts:828-835`). | Every new object field (`theme`, `hours`, `announcement`) is sent as a JSON string and parsed with `parseObjectField`. |
| G5 | The public payload is built field by field (`itemController.js:561-579`) and the page caches `restaurantData` in localStorage (`useFetchApiForNewUi.ts:71-92`). | New fields must be added to that projection explicitly, and the cached theme must be applied **before first paint** or every visit flashes the default look. |
| G6 | Plan limits live in `recapture-api/src/config/subscriptionPlans.ts`. | Plan gating (Stage 8) adds entitlements there; it does not invent a second catalog. |

---

## Decisions taken in this pack (change them here, not in a stage)

| # | Decision | Why |
|---|---|---|
| D1 | **ReCapture is the source of truth; Mirage stores a copy.** Every customization field is authored on `Catalog` (or product/category) and pushed on every publish by `syncCatalogBranding()`. | Same model as branding today — a divergence in Mirage is healed by the next publish. |
| D2 | **Themes are presets + limited overrides**, never free CSS. A theme is `{ presetId, mode, primary?, accent? }`. Preset palettes live in **Mirage-fe** (`src/theme/presets.ts`); ReCapture holds a mirror of the IDs + swatches for its picker. | Free-form colours produce unreadable menus. Presets let us improve a look for every client at once. |
| D3 | **Custom colours must pass contrast** (WCAG AA 4.5:1 against the preset's text colour) — validated in ReCapture (Zod) **and** re-checked in Mirage-fe, which falls back to the preset colour if it fails. | Mirage is also written by its own admin UI; never trust the stored value blindly. |
| D4 | **Fonts are curated pairings** (≈6), loaded from Google Fonts by Mirage-fe only when not the default. | Load cost and legibility. |
| D5 | **Absent = today's page.** Every new field is optional end to end; a restaurant with no customization must render pixel-identical to now. | House rule already followed by `ProductBadges.tsx` and `types.ts`. |
| D6 | Customization edits go through `applyCatalogPatch` → `$inc draftRevision`, so they light the "draft changes not yet live" badge and go live on **Publish**, like every other authoring change. No instant-apply path. | One write path; preview-before-publish is the product. |
| D7 | Time-based logic (open now, scheduled announcements, time-windowed categories) is evaluated **in the browser in `Asia/Kolkata`** (restaurant `timezone` field, default `Asia/Kolkata`). | No server cron needed; the page is already client-rendered. |

---

## The stages

**Progress:** ✅ = code built (typecheck/analyze clean); tests are written but run once after the
last stage, and manual phone checks may still be open — see the stage's *Done when*.
🚧 = in progress.


| # | Stage | Side | Depends on | Size |
|---|---|---|---|---|
| ✅ 1 | [Theme foundations — CSS variables, presets, Mirage `theme` field](stage-01-theme-foundations.md) | **Mirage** BE + FE | — | M |
| ✅ 2 | [Appearance screen in ReCapture — presets, colours, live preview, sync](stage-02-recapture-appearance.md) | BE + FE | 1 | L |
| ✅ 3 | [Cover image, layout style, fonts](stage-03-cover-layout-fonts.md) | BE + FE + Mirage | 2 | M |
| ✅ 4 | [Opening hours, announcement strip, time-windowed categories](stage-04-hours-announcements.md) | BE + FE + Mirage | 2 | M |
| ✅ 5 | [Custom badges and dietary / allergen info](stage-05-badges-dietary.md) | BE + FE + Mirage | 2 | M |
| 6 | [Multi-language menu](stage-06-multi-language.md) | BE + FE + Mirage | 2 | L |
| 7 | [AR branding, pairings ("goes well with"), engagement buttons, branded QR](stage-07-ar-engagement-qr.md) | BE + FE + Mirage | 2 | L |
| 8 | [Plan gating, custom domain, rollout](stage-08-plan-gating-rollout.md) | BE + FE + infra | 1–7 | M |

### Part 2 — features that make Mirage more useful to clients (Stages 9–16)

Not about looks: these bring the owner money, save them time, or prove the subscription is worth paying for.

| # | Stage | Side | Depends on | Size |
|---|---|---|---|---|
| 9 | [⭐ Weekly value report + dish insights](stage-09-value-report-insights.md) | BE (worker) + FE + 1 Mirage event | — | L |
| 10 | [Offers, combos, happy-hour pricing](stage-10-offers-happy-hour.md) | BE + FE + Mirage | 4 | M |
| 11 | ["My plate" list — show to waiter](stage-11-my-plate.md) | Mirage-fe (+ small BE) | — | S–M |
| 12 | [Google reviews, customer opt-in list, delivery & booking links](stage-12-reviews-customers-links.md) | BE + FE + Mirage | 7.3 | M |
| 13 | [Menu from a photo + AI descriptions + photo enhance](stage-13-ai-menu-import-content.md) | BE (AI module, worker) + FE | — | L |
| 14 | [Quick edit, bulk prices, staff access, printable PDF menu](stage-14-quick-edit-staff-pdf.md) | BE + FE | — | M |
| 15 | [⭐ Instagram-ready 3D spin videos](stage-15-3d-spin-videos.md) | BE (render worker) + FE | 3D models | L |
| 16 | [Multi-branch restaurants — design only](stage-16-multi-branch-design.md) | data model + all | 14 | XL |

Stages 3–7 are independent of each other once Stage 2 ships — pick them in business order.
**Recommended order (both parts together):**
1 → 2 → **9** → 3 → **13** → **15** → 4 → **10** → **11** → 5 → **14** → 8 (gating) → 7 → **12** → 6 → 16.
Reasoning: Stage 9 (value report) keeps clients paying and needs no other stage; Stage 13 speeds up
every new onboarding; Stage 15 is the feature owners show off. Stage 16 only after real demand is confirmed.

### Per-stage rules (apply to every prompt)

1. Read `AGENTS.md` and this README first.
2. Backward compatible both ways: new ReCapture ↔ old Mirage, and old ReCapture ↔ new Mirage.
3. Every Mirage field added to the model **must** also be added to the public projection
   (`itemController.js:561`) and to `mirageTypes.ts` + `toRestaurant()` in `mirageClient.ts`.
4. Every ReCapture field: Mongoose schema → Zod validation → DTO mapper → Dart model → UI.
5. Write the tests listed in the stage, but **run the full suite once after the whole batch**, not per change.
6. Each stage ends with its *Done when* checklist ticked and a manual check on a real phone.

---

## Open questions (answer before the stage that needs it)

| # | Question | Needed by |
|---|---|---|
| Q1 | Final preset list and names — the 8 in Stage 1 are a proposal. | Stage 1 |
| Q2 | Does the rep get the Appearance screen on delegated catalogs, or owner only? (Proposal: both.) | Stage 2 |
| Q3 | Which regional languages first? (Proposal: Hindi, then Marathi/Tamil on demand.) Machine-translate as a draft, or owner types everything? | Stage 6 |
| Q4 | Which features are paid-tier only? (Proposal table in Stage 8.) | Stage 8 |
| Q5 | Custom domain: subdomain of ours (`cafe.mirage.menu`) only, or the client's own domain too? | Stage 8 |
| Q6 | Weekly report: in-app only at first, or wait for the WhatsApp channel? | Stage 9 |
| Q7 | AI provider + monthly budget for menu import / descriptions / translations. | Stage 13 |
| Q8 | Where does the video render worker run (needs Chromium + ffmpeg, ~1 GB RAM per render)? | Stage 15 |
| Q9 | Multi-branch: how many clients asked, and billing per outlet or per brand? | Stage 16 |
