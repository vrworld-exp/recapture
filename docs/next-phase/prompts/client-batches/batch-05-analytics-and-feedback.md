# ReCapture Client — Batch 05 · F9 + F10 · Analytics and Feedback Layer

> **Status: ⬜ todo.** F9 depends on **backend B7**. F10 depends on **F1**, and gives full value only
> once **F2** and **F8** exist — it retrofits every catalog surface, so it is best done last among
> the feature screens.

**Batch scope:** the two read-and-report surfaces — what happened after publish, and how every
catalog screen talks back to the user.

- **F9 — Analytics dashboard** (task T-038; feature 66, surfacing 61–65) — catalog views, unique
  visitors, top products, 3D loads, AR launches, 3D-vs-image split, over a server-side date range.
- **F10 — Feedback layer** (tasks T-040, T-041; features 67, 68, 69) — one shared seam for
  confirmation toasts, undo where reversible, and a **code → (message, action)** table with no
  fallthrough to raw upstream text.

**Why these two ship together:** both are cross-cutting presentation work over surfaces that already
exist, and both are defined by their *states* rather than their happy path — loading, empty, error,
degraded. F9's `ANALYTICS_UNAVAILABLE` degradation is rendered through F10's code table, so the two
share the mapping.

**F10 is MVP and F9 is V2** — if the batch has to be cut, **ship F10**. An unmapped error code
reaching the UI as raw Mirage prose is a support call; a missing dashboard is not.

**Delivery order inside the batch:** F10 first.

---

## Shared context — applies to both prompts in this file

Repo root for every prompt in this file: `phase2/ReCapture/` (work happens in `lib/` and `test/`).
`ReCapture/AGENTS.md` is the tie-breaker over anything written here.

**Every prompt in this file ships Android/iOS *and* Flutter web in the same change.** The shared
platform rules are restated in each prompt's "Platform requirements" block; the full list is in
the "Standing platform rules" section directly below (mirrored from `../README.md`).

Standing facts these prompts rely on (verified in the tree):

- Entities exist: `lib/domain/entities/catalog.dart`, `catalog_category.dart`, `catalog_json.dart`,
  `catalog_product.dart`, `catalog_status.dart`, `product_availability.dart`,
  `product_sync_status.dart`, `product_type.dart`.
- Repositories exist and already cover the backend surface:
  `lib/data/repositories/catalog_repository.dart` (catalog CRUD, branding presign/commit, category
  CRUD + reorder), `catalog_products_repository.dart` (`list`, `get`, `create`, `update`,
  `createImageSlot`, `uploadImageBytes`, `commitImage`, `duplicate`, `archive`, `restore`, `delete`,
  `reorder`, `bulk`), `business_profile_repository.dart`, `catalog_failure.dart`.
- Notifiers exist: `lib/application/catalog/{catalog_notifier,product_create_notifier,
  product_detail_notifier}.dart`.
- Routes are **declared** in `lib/app/routes/app_router.dart` for `/catalog`, `/catalog/settings`,
  `/catalog/preview`, `/catalog/publish`, `/catalog/qr`, `/catalog/categories`,
  `/catalog/products/new`, `/catalog/products/:productId`, `/catalog/products/:productId/model`,
  `/catalog/analytics` — but only `/catalog` and the add-product / change-model routes are
  **registered** (`app_router.dart:282-286`). Registering the rest is part of the relevant prompt.
- Screens that exist: `catalog_screen.dart` (shell + header card + empty state),
  `add_product_screen.dart`, `change_product_model_screen.dart`, `create_catalog_dialog.dart`.
- Reusable widgets: `app_button.dart`, `app_card.dart`, `app_text_field.dart`,
  `app_status_pill.dart`, `app_loading_indicator.dart`, `delete_confirmation_modal.dart`,
  `model_picker_field.dart`, `model_choice_tile.dart`, `project_card.dart`, `post_shot_toast.dart`.
- Theme: `lib/app/theme/{app_colors,app_spacing,app_theme,app_typography}.dart` —
  `SnackBarThemeData` is at `app_theme.dart:279`.

## Standing platform rules — app AND web, every prompt in this file

Every client prompt ships **Android/iOS and Flutter web in the same change**. Each prompt restates
the rules that bite it, but these apply to all of them:

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

## Architectural constraints — every prompt in this file

- **Riverpod only.** Notifiers call repositories; repositories own Dio. No HTTP in the presentation
  layer, ever.
- **Parse nothing in the UI.** Entities already parse field-by-field (`lib/domain/entities/`).
- **No new state, HTTP, navigation or storage package** without justification in the PR.
- **Existing theme tokens only** — `app_colors`, `app_spacing`, `app_typography`.
- **No raw upstream text reaches the UI.** The backend maps Mirage prose onto stable `UPPER_SNAKE`
  codes; the client maps each code to one sentence plus one next action (F10 owns that table).
- **Parked features stay parked** (brief §G): multi-catalog, team members, ordering/payments, custom
  domains, advanced analytics, AI descriptions, multi-language, per-product QR, image galleries,
  external 3D uploads.

## How to use this file

1. Paste **one prompt** (one fenced block) whole into a fresh session opened at `phase2/ReCapture/`.
   One prompt per session — each is scoped to one reviewable change.
2. Read this file's shared context above first; the prompt assumes it.
3. `ReCapture/AGENTS.md` is the tie-breaker over anything written here. If they conflict, AGENTS.md
   wins and the conflict should be **reported**, not silently resolved.
4. Run the batch verification block at the end of this file before opening a PR.

## Where this batch sits

| Batch | Prompts | Subject | Depends on | Status |
|---|---|---|---|---|
| [01](batch-01-product-grid-and-editor.md) | F1 · F2 | Product grid · Product editor | — | ✅ complete |
| [02](batch-02-archive-and-categories.md) | F3 · F4 | Archive/restore/delete · Category manager | F1 | ⬜ todo |
| [03](batch-03-bulk-and-business-profile.md) | F5 · F6 | Bulk selection · Business profile | F1, F3, F4 | ⬜ todo |
| [04](batch-04-preview-and-publish.md) | F7 · F8 | Catalog preview · Publish + QR | F1 · backend B4, B5 | ⬜ todo |
| [05](batch-05-analytics-and-feedback.md) | F9 · F10 | Analytics dashboard · Feedback layer | F1, F2, F8 · backend B7 | ⬜ todo |
| [06](batch-06-web-parity-and-tests.md) | F11 · F12 | Web parity pass · Test hardening | F1–F10 | ⬜ todo |

Full pack context: `../README.md` · original combined file: `../02-recapture-client-prompts.md`
(this batch is a verbatim extract of it — the prompt text is unchanged).

---

# F9 — Analytics dashboard

```
# FEATURE: Catalog Analytics Dashboard
# Product: ReCapture (Flutter — Android/iOS + Web)
# Phase: Next Phase — Analytics
# Track: Client
# Scope: New Feature (task T-038; feature 66, surfacing 61–65)
# Priority: Low (V2)
# Depends on: backend B7

---

## Context

`/catalog/analytics` is declared but unregistered. Collection is already happening on the public
Mirage page and has been for months, so the dashboard opens onto real history from day one.

## Task

A dashboard showing catalog views, unique visitors, top viewed products, 3D model loads, AR launches
and the 3D vs image-only split, over a selectable date range.

## Files to inspect first

1. The B7 endpoints and their DTOs
2. `lib/data/repositories/catalog_repository.dart` — add the analytics reads to the same seam
3. `pubspec.yaml` — no charting library is present today

## Implementation instructions

1. Register `/catalog/analytics`.
2. Range control: 7 / 30 / 90 days and a custom range; the range is part of the request, not a
   client-side filter.
3. Tiles: catalog views, unique visitors, product views, 3D model loads, AR launches, with the
   period-over-period delta the backend provides.
4. A simple timeseries chart and a top-products list showing each row's type badge
   (3D / Image-only / Unknown).
5. **Prefer no new dependency.** A sparkline/bar chart drawn with `CustomPainter` is enough for this
   scope; if a charting package is genuinely warranted, justify it and pick one that supports web.
6. States: loading skeletons, empty ("no scans yet — share your QR"), error with retry, and the
   `ANALYTICS_UNAVAILABLE` degradation from B7 rendered as a soft empty state, not a crash.

## Platform requirements — app AND web

- Chart must render and stay legible from 360 px to 1600 px wide; no fixed pixel sizes.
- Web: hover tooltips on the chart; mobile: tap-to-inspect. Both, not one.
- Numbers use the device locale formatting on both platforms.

## What NOT to change

- The event vocabulary. ReCapture does not emit customer-facing events — Mirage's public page does.
- Do not build funnels, heatmaps or cohorts (parked in brief §G).

## Edge cases to handle

- Catalog never published → the empty state explains that analytics start after publishing.
- A top product deleted locally → row shows `Unknown` with its Mirage id, still counted.
- Range with no data → zeroed tiles, not an error.
- Very large numbers → abbreviate (1.2k) without losing the exact value in the tooltip.

## Acceptance criteria

- [ ] All six metrics render with a working range control.
- [ ] Type split is visible on top products.
- [ ] Empty / loading / error / unavailable states are distinct.
- [ ] Chart is legible at 360 px and 1600 px.

## Testing instructions

`test/catalog/analytics_dashboard_test.dart`: range switching triggers a new request, empty and
unavailable states, type badges, chart layout at both extremes.
```


---

# F10 — Toasts, confirmations, error and success states

```
# FEATURE: Feedback Layer — toasts, confirmations, actionable errors
# Product: ReCapture (Flutter — Android/iOS + Web)
# Phase: Next Phase — Polish
# Track: Client
# Scope: New Feature (tasks T-040, T-041; features 67, 68, 69)
# Priority: High (MVP)
# Depends on: F1 (and ideally F2, F8 for full coverage)

---

## Context

Without confirmation, users repeat destructive actions. And the raw upstream failure text is
useless to a café owner — the backend already maps Mirage prose onto stable `UPPER_SNAKE` codes, so
the client's job is to turn each code into one specific sentence and one next action.

## Task

A single feedback seam used by every catalog surface: confirmation toasts, undo where reversible,
and a code → (message, action) mapping with no fallthrough to raw text.

## Files to inspect first

1. `lib/app/theme/app_theme.dart:279` — the existing `SnackBarThemeData`
2. `lib/data/repositories/catalog_failure.dart` — the existing failure type
3. `lib/presentation/widgets/post_shot_toast.dart` — an existing toast idiom
4. Every `UPPER_SNAKE` code emitted by `recapture-api/src/routes/catalog.ts` and the publish services

## Implementation instructions

1. **One helper**, e.g. `lib/presentation/widgets/catalog/catalog_feedback.dart`, used by every
   catalog screen. Do not scatter `ScaffoldMessenger` calls with ad-hoc strings.
2. Confirmations on: product added, edited, archived, restored, deleted, duplicated, category
   created/renamed/deleted/reordered, profile saved, publish started, publish finished, unpublished.
3. Undo where the action is reversible (archive, category reorder). Undo must call the real inverse,
   not just restore local state.
4. **Code → message table.** Every code the backend can emit maps to one sentence plus one action
   ("Rename product", "Add a photo", "Open publish", "Retry"). A code with no mapping must render a
   generic-but-honest message **and** be caught by a test that enumerates the backend's codes — an
   unmapped code is a build failure, not a silent passthrough.
5. Error copy rules: name the object ("Chair 02 could not be published"), say why in plain language,
   say what to do next. Never show an HTTP status, a stack, or upstream prose.

## Platform requirements — app AND web

- Snackbars must not cover the primary action on wide layouts; anchor sensibly on both.
- Web: toasts are reachable by screen readers (live region) and dismissible by keyboard.
- Long messages wrap rather than truncate on narrow screens.

## Edge cases to handle

- Two rapid actions → queue toasts, do not stack them into an unreadable pile.
- Undo pressed after navigating away → still performs the inverse, or is not offered at all.
- Offline errors get a distinct message from server errors.

## Acceptance criteria

- [ ] Every mutating catalog action confirms visually.
- [ ] Every backend catalog code has a mapped message and action (asserted by an enumerating test).
- [ ] No raw upstream text can reach the UI (asserted).
- [ ] Undo performs the real inverse call.

## Testing instructions

`test/catalog/feedback_test.dart`: code-coverage test over the backend code list, undo inverse call,
toast queueing, no-raw-text assertion.
```


---

## Batch verification — run before calling this batch done

Both builds must succeed from a clean tree, and both must actually be exercised — a green
`flutter test` alone does not prove the web build ships.

```bash
# from phase2/ReCapture/
flutter analyze                 # must be clean
flutter test                    # must be green, no network from any test
flutter build web --release     # web target
flutter build apk --release     # device target
flutter run -d chrome           # manual pass over the screens this batch touched
```

Manual checklist for the PR description:

- [ ] Chrome desktop wide (≥1200 px) and narrowed to ~400 px — the narrow window renders the phone
      layout, not a squeezed desktop one.
- [ ] Chrome mobile / physical Android device.
- [ ] Keyboard-only pass over every new interactive surface on web (tab order, Enter, Escape).
- [ ] No `dart:io` import on any catalog code path touched by this batch.
- [ ] No `kIsWeb`-driven **layout** decision introduced by this batch.
