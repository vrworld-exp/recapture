# ReCapture Client — Batch 06 · F11 + F12 · Web Parity and Test Hardening

> **Status: ⬜ todo.** Both prompts audit everything before them — run this batch **last**, after
> F1–F10 have merged. F11 needs F1 and F8 at minimum; F12 needs all of F1–F11.

**Batch scope:** the hardening pass that decides whether the phase actually ships on two platforms.

- **F11 — Web parity pass** (cross-cutting; supports every catalog feature on the web build) —
  capability gating, file handling, downloads, clipboard, the 3D viewer, CORS, routing, and the
  build itself. Produces `docs/next-phase/web-capability-matrix.md` as a kept artifact.
- **F12 — Client test hardening** (task T-042 client half) — golden-JSON entity tests, repository
  error translation, notifier pagination/rollback tests, offline behaviour, publish polling
  lifecycle, widget tests at four widths. Hermetic: isolated Hive dir, faked repositories, no live
  HTTP.

**Why these two ship together:** F11 finds the gaps and F12 nails them shut. Every capability F11
gates needs a test that fails if the gate is removed — driving the platform flag through a provider
so it is testable is an F11 implementation instruction *because* F12 depends on it. Running F12
first just means writing the tests twice.

**Both are MVP.** The phase ships APK **and** web; neither prompt is optional.

**Delivery order inside the batch:** F11 first.

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

# F11 — Web parity pass: capability gating, build and deploy

```
# FEATURE: Flutter Web Parity for the Catalog Surface
# Product: ReCapture (Flutter web)
# Phase: Next Phase — Cross-cutting
# Track: Client / Platform
# Scope: Hardening (supports every catalog feature on the web build)
# Priority: Critical (the phase ships APK **and** web)
# Depends on: F1, F8 at minimum

---

## Context

The web build already exists (`web/index.html`, `web/manifest.json`) and the codebase already gates
platform capabilities in ~9 places (`kIsWeb` in `permissions_service.dart`,
`upload_background_session.dart`, `upload_foreground_service.dart`, `model_render_view.dart`,
`project_capture_cleanup.dart`, `avatar_image_picker.dart`). The catalog surface must be equally
deliberate: web is a first-class target for authoring, but **capture does not exist there**.

## Task

Audit and fix the whole catalog surface for web: capability gating, file handling, downloads,
clipboard, the 3D viewer, CORS, routing, and the build.

## Files to inspect first

1. Every `kIsWeb` call site listed above — match their idiom
2. `web/index.html:35-53` and `lib/presentation/screens/projects/model_render_view.dart` (both
   meshopt trigger sites) and `test/projects/meshopt_decoder_test.dart`
3. `lib/data/datasources/product_image_picker.dart` (already web-safe)
4. `lib/platform/` — the native seams
5. `recapture-api/src/app.ts:30` + `tests/cors.test.ts` — the API origin allow-list
6. `lib/app/routes/app_router.dart` — deep links and URL strategy

## Implementation instructions

1. **Capability audit table.** Produce (and keep in the repo, e.g.
   `docs/next-phase/web-capability-matrix.md`) a row per catalog capability: works on web / gated /
   hidden. At minimum:
   - Fresh-scan product source (camera) → **hidden on web**, not disabled-with-an-error. The
     existing-model and image-only sources remain.
   - AR launch → not available on web; do not render the affordance.
   - Background/foreground upload services → already gated; confirm the catalog image upload path
     does not reach them.
   - Share sheet → mobile only; web uses a download/copy path.
2. **Layout rule.** Grep the catalog code for `kIsWeb` used to decide layout and remove it — layout
   comes from `BoxConstraints` (`model_picker_field.dart:34`). `kIsWeb` is for capabilities only.
3. **File handling.** No `dart:io` `File` on any catalog path. Bytes end-to-end.
4. **Downloads** (QR PNG/PDF): browser download on web, `share_plus` on mobile, behind one seam.
5. **Clipboard**: secure-context aware with a visible fallback.
6. **CORS**: confirm the API allow-list covers the web origin(s) and that S3 bucket CORS permits the
   presigned `PUT` from the browser, including the headers the client sends. Extend `cors.test.ts`
   for the catalog routes, and make the client surface a specific "browser blocked the upload"
   message rather than a generic failure.
7. **Routing/URL**: deep links to `/catalog/...` must work on a page refresh (hosting rewrite to
   `index.html`), and the browser back button must behave through the catalog flows
   (`lib/app/routes/flow_back.dart`).
8. **Auth storage on web**: `flutter_secure_storage` on web is browser storage, not a keychain.
   Confirm the existing behaviour, document it, and do not weaken it for the catalog.
9. **Build**: document the exact commands and any base-href/hosting notes in `README.md` or the
   Makefile — `flutter build web --release` and the APK build must both be one command each, and
   both must be run before this task is called done.

## What NOT to change

- The capture pipeline itself.
- The existing `kIsWeb` gates outside the catalog surface.
- Do not add a web-only code path that duplicates a mobile one — one seam, two implementations.

## Edge cases to handle

- Safari/iOS web: clipboard and download behave differently; verify or explicitly document as
  unsupported.
- A user opening a `/catalog/products/:id` deep link while logged out → the existing auth redirect
  must return them there afterwards.
- Large image selected in a browser → the size cap message must appear before a 30-second upload.
- Optimized GLB in the web preview → this is exactly the meshopt trigger case.

## Acceptance criteria

- [ ] `flutter build web --release` and the APK build both succeed from a clean tree.
- [ ] The capability matrix document exists and matches the code.
- [ ] No `dart:io` import on any catalog code path.
- [ ] No `kIsWeb`-driven layout decision remains in catalog code.
- [ ] Camera-dependent affordances are hidden, not broken, on web.
- [ ] QR download works in Chrome; QR share works on device.
- [ ] Deep-link refresh works on the deployed web build.
- [ ] `meshopt_decoder_test.dart` passes and covers the catalog viewer paths.

## Testing instructions

`test/catalog/web_parity_test.dart` for the gating logic (drive the platform flag through a provider
so it is testable), plus a manual checklist in the PR description covering Chrome desktop, Chrome
mobile, and a physical Android device.
```


---

# F12 — Client test hardening

```
# FEATURE: Catalog Client Test Hardening
# Product: ReCapture (Flutter — Android/iOS + Web)
# Phase: Next Phase — Cross-cutting
# Track: Client / QA
# Scope: Hardening (task T-042 client half)
# Priority: High (MVP)
# Depends on: F1–F11

---

## Context

Mirage has no tests and no type checking, and ReCapture's CI cannot cover it. On the client side the
equivalent risk is that the catalog surface is stateful, paginated, optimistic and partially offline
— exactly the shape where bugs hide until a pilot hits them.

## Task

Bring the catalog client surface up to the repo's existing testing bar: hermetic, no real network,
isolated Hive store.

## Files to inspect first

1. `test/` — the existing hermetic patterns (`test/projects/`, `test/offline/`, `test/storage/`)
2. `lib/data/local/box_names.dart` — the Hive box names
3. `lib/application/connectivity/` — the mockable connectivity seam
4. `lib/data/repositories/catalog_failure.dart`

## Implementation instructions

1. **Golden-JSON entity tests**: every catalog entity parses a captured real response field by
   field, including the fields added late (tags, availability, featured, position, sync fields).
   A test must fail if a field silently stops parsing.
2. **Repository tests**: error translation from every backend code into `CatalogFailure`, with no
   raw upstream text surviving.
3. **Notifier tests**: pagination boundaries, stale-response discard, optimistic update + rollback
   for reorder/archive/bulk.
4. **Offline behaviour**: catalog reads from cache where the app already caches; writes fail cleanly
   with retry. Use the existing connectivity abstraction — no real network.
5. **Publish polling lifecycle**: starts, backs off, stops on terminal state, stops on dispose,
   pauses when hidden (web).
6. **Widget tests at 4 widths** for grid, category manager and dashboard.
7. Keep `test/catalog/` organised like the existing suites, and keep every test hermetic — isolated
   temp Hive dir, faked repositories, no live HTTP.

## Acceptance criteria

- [ ] `flutter test` is green, with no network access from any test.
- [ ] Every catalog entity has a golden-JSON test.
- [ ] Optimistic-update rollback is covered for each surface that uses it.
- [ ] Polling lifecycle is covered including dispose.
- [ ] `flutter analyze` is clean.

## Testing instructions

Run `flutter test`, `flutter analyze`, `flutter build web --release` and the APK build before
calling this done.
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
