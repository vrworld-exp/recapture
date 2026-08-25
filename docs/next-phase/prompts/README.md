# Next-Phase Coding Prompt Pack

Ready-to-paste coding prompts covering **all 69 features** in the next-phase brief, for both
platforms (**Android/iOS APK + Flutter web**) and both systems (**ReCapture** and **Mirage**).

Source of truth for the analysis behind these prompts:
`01-codebase-findings.md` · `02-feature-to-side-mapping.md` · `03-architecture-proposal.md` ·
`04-task-breakdown.md` · `05-mvp-v1.1-v2-bucketing.md` · `06-open-questions.md`.

> ⚠ `01-codebase-findings.md` was written before the phase-2 work landed. **Both repos have moved
> on.** The "Current state" tables below are a re-verification done against the working tree, and
> they — not `01` — are what these prompts assume.

Files in this pack:

| File | Prompts | Target repo | Status |
|---|---|---|---|
| `01-recapture-backend-prompts.md` | B1–B7 | `phase2/ReCapture/recapture-api/` (Node/TS) | ✅ all run |
| `02-recapture-client-prompts.md` | F1–F12 | `phase2/ReCapture/lib/` (Flutter — app **and** web) | ✅ all run |
| `03-mirage-prompts.md` | M1–M5 | `phase2/mirage-be-phase-2-recap/` + `phase2/mirage-fe/` | ❌ **none run — the only work left** |

> **Where the phase stands.** ReCapture is finished on both sides — B1–B7 and F1–F12 are merged
> (batch 06 landed as `f8ac0de`). The remaining next-phase work is **entirely in Mirage**, and it
> does **not** run from `phase2/ReCapture/`: open M1–M4 at `phase2/mirage-be-phase-2-recap/` and M5
> at `phase2/mirage-fe/`. Suggested order **M1 → M5 → M2 → M3 → M4** — M1 is the highest-value fix
> (every asset currently crosses the wire twice) and M5 is what makes the phase-2 fields visible to
> customers; M2–M4 are reliability and V2.

> `02-recapture-client-prompts.md` is also available **split into six self-contained two-prompt
> batches** in [`client-batches/`](client-batches/README.md) — F1+F2, F3+F4, F5+F6, F7+F8, F9+F10,
> F11+F12. Same shared context and platform rules in every file; the prompt text is a verbatim
> extract. Hand one batch to one session instead of the whole twelve-prompt file.

---

## Current state — verified against the working tree

### ReCapture backend — ALREADY BUILT (do not rebuild; extend only)

| Area | Evidence |
|---|---|
| `Catalog`, `CatalogProduct`, `CatalogCategory`, `CatalogPublishRun` models + indexes | `recapture-api/src/models/Catalog*.ts`, `catalogShared.ts`, `types/catalog.types.ts` |
| `MIRAGE_*` config (base url, api key, admin token/user/password, public base url, asset bucket + CDN, timeout, max asset bytes) | `src/config/env.ts:283-363` |
| Mirage HTTP adapter + error classification + fake seam | `src/services/mirage/{mirageClient,mirageErrors,mirageTypes,index}.ts`, `tests/mirage-error-classification.test.ts` |
| Catalog CRUD, logo/cover presign+commit, business profile | `src/routes/catalog.ts:137-303`, `src/services/catalogService.ts` |
| Category CRUD + reorder | `src/routes/catalog.ts:306-429` |
| Product create / list / patch / duplicate / delete / archive / restore / reorder / bulk / image presign+commit | `src/routes/catalog.ts:430-940`, `src/services/catalogProductsService.ts`, `src/utils/productImageKeys.ts` |
| Product fields: tags, availability, featured, position, currency, sync fields, `publishedSnapshot` | `src/models/CatalogProduct.ts` |
| Mirage provisioning + branding sync + name-collision suggestion | `src/services/catalogProvisioningService.ts` |
| Tests | `tests/catalog-*.test.ts`, `tests/mirage-error-classification.test.ts` |

### ReCapture backend — B1–B7 ✅ ALL DONE

| Prompt | Landed as |
|---|---|
| B1 publish job type + planner + processor | `src/services/catalog/{publishPlanner,publishSnapshot,publishRunState}.ts`, `src/worker/processors/mirageCatalogPublishProcessor.ts` |
| B2 category + product sync, reconciliation | `src/services/catalog/{categorySync,productSync,publishExecutors}.ts` |
| B3 asset sync | `src/services/catalog/{assetPreflight,assetSync,assetUploader}.ts` |
| B4 publish/unpublish endpoints, state machine, gates, status, retry | `src/services/catalogPublishService.ts` |
| B5 QR render (PNG/PDF) | `src/services/catalogQrService.ts` |
| B6 activity log | `src/services/catalogActivityService.ts` |
| B7 analytics proxy | `src/services/catalogAnalyticsService.ts`, `src/validation/analyticsSchemas.ts` |

Each has its own suite: `tests/catalog-publish-{planner,processor,api,status,idempotency}.test.ts`,
`catalog-{category,product,asset}-sync.test.ts`, `catalog-{qr,unpublish,activity-log,analytics-proxy}.test.ts`.

### ReCapture Flutter — ALREADY BUILT

Entities (`lib/domain/entities/catalog*.dart`, `product_*.dart`), repositories
(`catalog_repository.dart`, `catalog_products_repository.dart`, `business_profile_repository.dart`,
`catalog_failure.dart`), notifiers (`lib/application/catalog/*`), routes declared in
`lib/app/routes/app_router.dart` (`/catalog`, `/catalog/settings`, `/catalog/preview`,
`/catalog/publish`, `/catalog/qr`, `/catalog/categories`, `/catalog/products/new`,
`/catalog/products/:productId`, `/catalog/products/:productId/model`, `/catalog/analytics`),
screens `catalog_screen.dart` (shell + header), `add_product_screen.dart`,
`change_product_model_screen.dart`, `create_catalog_dialog.dart`.

**Every `/catalog/*` route constant now has a registered screen** — F1–F12 closed that gap.

### ReCapture Flutter — F1–F12 ✅ ALL DONE

| Batch | Prompts | Landed as |
|---|---|---|
| 01 | F1 grid/filter/search · F2 product editor | `product_grid_section.dart`, `product_editor_screen.dart` |
| 02 | F3 archive UI · F4 category manager | `typed_confirm_dialog.dart`, `category_manager_screen.dart` |
| 03 | F5 bulk mode · F6 business profile | `bulk_selection_bar.dart`, `business_profile_screen.dart` |
| 04 | F7 catalog preview · F8 publish + QR | `catalog_preview_screen.dart`, `publish_screen.dart`, `catalog_qr_screen.dart` |
| 05 | F9 analytics dashboard · F10 feedback layer | `catalog_analytics_screen.dart`, `catalog_feedback.dart` |
| 06 | F11 web parity · F12 test hardening | `../web-capability-matrix.md`, `test/catalog/web_parity_test.dart`, Makefile `verify` |

`test/catalog/` is green (342 tests) and `flutter analyze` is clean on the catalog surface.

### Mirage — ALREADY BUILT (phase-2 work already merged into `mirage-be`)

| Gap listed in `06-open-questions.md` | Status today |
|---|---|
| Q-C2 no USDZ path | **DONE** — third multer field `objectIos` (`src/libs/multer.js:15-19`), written to `model.iosSrc` (`adminController.js:1119,1175`) |
| Q-C3 `update-item` ignored `description`/`category` | **DONE** — both destructured and applied (`adminController.js:1272-1281`) |
| Q-C4 `imgOnly` cannot be unset | **DONE** — now derived on create *and* update (`adminController.js:1195-1199, 1498-1502`) |
| Q-C5 no sort/position field | **DONE** — `item.sortPosition`, `category.sortPosition` + indexes; public reads sort by it (`itemModel.js:199-215`, `categoryModel.js:71-78`, `itemController.js:523-651`) |
| Q-C6 `delete-category` was a stub | **DONE** — real implementation with a non-empty guard and `?force=true` (`adminController.js:1708+`) |
| Q-C7 no featured/tags/availability | **DONE** — all three on `itemModel`, with `parseProductOptionalFields` multipart coercion |
| Q-C8 no website/socials/address | **DONE** — `website`, `socialLinks`, `address` on `restaurantModel` |
| Q1 / feature 39 unpublish | **DONE** — `restaurant.isPublished` + a public read gate (`itemController.js:490-491`) |

### Mirage — REMAINING → prompts M1–M5

| Gap | Prompt |
|---|---|
| Q-C1 no URL passthrough — asset upload is **bytes only**, so every GLB/USDZ/image crosses the wire twice | **M1** (highest value) |
| Q-C9a no idempotency — a retried create returns `400 "already exist"` with no id to recover | **M2** |
| Q-C9b no batch writes — publishing N products is N multipart round trips | **M3** |
| Q-C10 analytics reads are admin-scoped only | **M4** |
| `mirage-fe` does not render tags / availability / featured / `sortPosition` / website / socials / address / unpublished state (`model.iosSrc` **is** already wired — `src/api/menu.ts:93`, `ArModel.tsx:53`) | **M5** |

---

## Recommended build order

The B and F tracks are complete. What is left of this diagram is the Mirage column — which was
originally sequenced *first* (M1 unblocks B3) but ended up last, so B3 ships the bytes-twice path
until M1 lands.

```
✅ B1 → B2 → B3 → B4 → B5 → B6 → B7          (done)
✅ F1 → … → F12                              (done)

❌ M1        URL passthrough — run first; retro-unblocks B3's double byte transfer
❌ M5        public page renders the phase-2 fields
❌ M2 → M3   reliability + speed, after the first pilot publish
❌ M4        client-scoped analytics — optional, B7's proxy already covers the need
```

MVP cut per `05-mvp-v1.1-v2-bucketing.md` was **B1–B5, F1, F8, F10, F11, F12, M1**; fast-follow
(V1.1) **F2, F3, F4, F6, F7, M2**; later (V2) **B6, B7, F5, F9, M3, M4, M5**. In the event the whole
B and F side shipped, V2 included — so **M1 is the only unbuilt MVP item.**

---

## Feature coverage matrix (1–69)

| Features | Where they are handled |
|---|---|
| 1–5 catalog container | **built** (BE + `catalog_screen`) · preview → **F7** · publish state surfacing → **F8** |
| 6–10 add product, fields, featured, reorder | **built** (BE + `add_product_screen`) · grid + reorder UI → **F1**, **F4** |
| 11–13 product sources | **built** (`add_product_screen`, `change_product_model_screen`) · web gating of the fresh-scan source → **F11** |
| 14–18 edit / replace / convert / duplicate | BE **built** · UI → **F2** |
| 19–21 archive / restore / delete | BE **built** · UI → **F3** |
| 22–26 categories | BE **built** · UI → **F4** · publish-time sync → **B2** |
| 27–30 list, filter, search, bulk | BE **built** · UI → **F1**, **F5** |
| 31–35 QR + public link | **B5** (render) + **F8** (view/download/copy/share, web + app) |
| 36–39 publish / unpublish / timestamp / draft badge | **B1**, **B4** + **F8** |
| 40–42 provisioning + mapping + branding | **built** (`catalogProvisioningService.ts`) — re-verified by the **B4** gates |
| 43–48 product & category sync | **B2**, **B3** |
| 49–51 asset sync (GLB / USDZ / image / thumbnail) | **B3** + **M1** |
| 52–55 sync status, manual retry, auto-retry, activity log | **B1**, **B4**, **B6** + **F8** |
| 56–57 consistency rules | **B1**, **B4** (snapshot-based planning) |
| 58–60 business profile | BE **built** · UI → **F6** |
| 61–66 analytics | **B7** + **F9** (+ **M4** for direct client scope) |
| 67–69 toasts, error states, success state | **F10** (+ **F8** for the "Live on Mirage" state) |

Parked (brief §G): multi-catalog, team members, ordering/payments, custom domains, advanced
analytics, AI descriptions, multi-language, per-product QR, image galleries, external 3D uploads.
**No prompt in this pack implements any of them** — every prompt repeats that in "What NOT to do".

---

## Platform rule that applies to every F-prompt

Every client prompt must ship **Android/iOS and Flutter web in the same change**. The pack states
this per prompt, but the standing rules are:

1. **Never branch on `kIsWeb` for layout.** Layout is decided from `BoxConstraints` — a narrow
   browser window is a phone layout (`lib/presentation/widgets/model_picker_field.dart:34`).
   `kIsWeb` is only for *capability* differences (camera, file system, share sheet).
2. **Camera capture does not exist on web.** The fresh-scan product source must be hidden (not
   disabled-with-an-error) when `kIsWeb` is true, with the existing-model and image-only sources
   still offered.
3. **Bytes, not `File`.** `dart:io` `File` is unavailable on web. Image picking already has a web
   path (`lib/data/datasources/product_image_picker.dart`) — reuse it; do not add a second picker.
4. **Downloads differ.** On mobile a file is shared through `share_plus`; on web it is an anchor
   download of a `Blob`. One repository method, two presentation paths.
5. **`model-viewer` meshopt decoder must be set in BOTH** `web/index.html:53` and `_lifecycleJs` in
   `lib/presentation/screens/projects/model_render_view.dart` — fixing one ships the other platform
   broken. `test/projects/meshopt_decoder_test.dart` guards it.
6. **CORS.** Any new S3 presigned `PUT` used from web needs the bucket CORS rule and the API origin
   allow-list checked (`recapture-api/src/app.ts:30`, `tests/cors.test.ts`).

---

## How to use a prompt

1. Paste one prompt whole into a fresh session opened at the repo root the prompt names.
2. `ReCapture/AGENTS.md` is the tie-breaker over anything in a prompt. If they conflict, AGENTS.md
   wins and the conflict should be reported rather than silently resolved.
3. One prompt per session — each is scoped to one reviewable change.
4. Run the verification block at the end of each prompt before opening a PR.
