✅✅✅✅✅
# ReCapture Client — Batch 04 · F7 + F8 · Catalog Preview and Publish + QR

> **Status: ⬜ todo.** F7 depends on **F1**. F8 depends on **backend B4 and B5** — do not start F8
> until `POST /catalog/publish`, `GET /catalog/publish/status`, `POST /catalog/publish/retry`,
> `POST /catalog/unpublish` and `GET /catalog/qr` are live.

**Batch scope:** the moment the catalog stops being a draft. This is the batch the whole phase
exists for.

- **F7 — Catalog preview** (task T-026; feature 5) — renders **the draft** from ReCapture data
  (never a Mirage read), and doubles as a pre-flight check by warning where a product would fail a
  publish gate.
- **F8 — Publish + QR** (tasks T-034 + T-025 client half; features 31–39, 52, 53, 68, 69) —
  pre-flight gate checklist, live polling progress, partial-failure recovery, success state,
  unpublish, and the QR screen with download / copy / share.

**Why these two ship together:** preview *is* the pre-flight surface for publish — the same
per-product gate warnings appear in both, driven by the same rules, and the gate checklist in F8
deep-links back into preview. Building publish without preview means the only view of what will go
live is the failure list after it did not.

**The one thing to get right:** publishing 10 products is 10 sequential unbatched uploads against a
server on a sleeping tier. **Partial failure is the expected case, not the exceptional one.** Both
prompts are written around that.

**Delivery order inside the batch:** F7 first (it can be built while B4/B5 are still in flight).

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

# F7 — Catalog preview

```
# FEATURE: Catalog Preview (pre-publish)
# Product: ReCapture (Flutter — Android/iOS + Web)
# Phase: Next Phase — Catalog Authoring
# Track: Client
# Scope: New Feature (task T-026; feature 5)
# Priority: Medium (V1.1)
# Depends on: F1

---

## Context

`/catalog/preview` is declared but unregistered. Preview renders **the draft**, from ReCapture data —
not from Mirage, which by definition does not have the draft yet (feature 57).

## Task

A preview that approximates the public catalog page: branding header, categories, product cards, and
a working 3D viewer for 3D products.

## Files to inspect first

1. `lib/presentation/screens/projects/model_render_view.dart` — the `model_viewer_plus` integration,
   including `_lifecycleJs` at lines ~246 and ~361
2. `web/index.html:35-53` — the meshopt decoder trigger and the comment explaining why
3. `test/projects/meshopt_decoder_test.dart` — the guard that keeps the two in sync
4. `../../mirage-fe/src/features/menu/` — the shape the public page actually renders
5. `lib/domain/entities/catalog*.dart`

## Implementation instructions

1. Register `/catalog/preview`.
2. Compose the preview from the same data the publish snapshot would use: profile branding,
   categories in their set order, products in their set order, availability and featured treatment.
3. 3D products open in `model_viewer_plus`. **The meshopt decoder location must be set in BOTH**
   `web/index.html` and `_lifecycleJs` in `model_render_view.dart` — an optimized GLB declares
   `EXT_meshopt_compression` in `extensionsRequired` and will fail to load without it. Extend
   `test/projects/meshopt_decoder_test.dart` to cover the preview path.
4. Label the screen as a preview, and state that it is an approximation of the public page.
5. Show a per-product warning where the draft would fail a publish gate (missing model, missing
   thumbnail, duplicate name) so preview doubles as a pre-flight check.

## Platform requirements — app AND web

- The viewer must work on both; the decoder rule above is the exact place where fixing one platform
  silently breaks the other.
- Wide layouts render nearer the real page width; narrow renders the phone shape.
- On web, AR is not available — do not show an AR button that cannot work.

## Edge cases to handle

- No products → preview shows the branded empty page, which is exactly what a customer would see.
- A GLB that fails to load → inline error on that card, not a blank screen.
- Very large GLB on a low-end device → show a size hint rather than freezing.

## Acceptance criteria

- [ ] Preview renders the draft (never a Mirage read).
- [ ] Optimized GLBs load in the preview on both web and device.
- [ ] `meshopt_decoder_test.dart` covers the preview path.
- [ ] Publish-gate warnings appear per product.

## Testing instructions

`test/catalog/catalog_preview_test.dart` + the extended `meshopt_decoder_test.dart`.
```


---

# F8 — Publish screen + QR screen (view, download, copy, share)

```
# FEATURE: Publish and QR — the moment the catalog goes live
# Product: ReCapture (Flutter — Android/iOS + Web)
# Phase: Next Phase — Publish & QR
# Track: Client
# Scope: New Feature (tasks T-034 + T-025 client half; features 31–39, 52, 53, 68, 69)
# Priority: Critical
# Depends on: backend B4 and B5

---

## Context

This is the screen the whole phase exists for. `/catalog/publish` and `/catalog/qr` are declared but
unregistered. The backend provides `POST /catalog/publish` → `202 {runId}`,
`GET /catalog/publish/status`, `POST /catalog/publish/retry`, `POST /catalog/unpublish`, and
`GET /catalog/qr?format=png|pdf`.

Publishing 10 products means 10 sequential unbatched uploads against a server on a sleeping tier.
**Partial failure is the expected case, not the exceptional one.** The screen must make a partial
run understandable and recoverable without a support call.

## Task

A publish screen with pre-flight gates, live progress, partial-failure recovery and a success state;
and a QR screen with download, copy and share.

## Files to inspect first

1. `lib/data/repositories/catalog_repository.dart` — add the publish/QR methods here (one seam)
2. `lib/domain/entities/catalog_status.dart`, `product_sync_status.dart`
3. `lib/presentation/screens/catalog/catalog_screen.dart` — the header already shows a
   "Publishing…" chip (`catalog_screen.dart:228`)
4. `lib/presentation/widgets/app_status_pill.dart`, `app_button.dart`
5. `pubspec.yaml` — `share_plus ^13.2.0` is already a dependency

## Implementation instructions

1. Register `/catalog/publish` and `/catalog/qr`.
2. **Pre-flight.** Before enabling Publish, show the gate checklist the backend returns
   (empty catalog, missing assets, duplicate names, missing business name). Each row deep-links to
   the screen that fixes it. Never let the user press Publish into a guaranteed failure.
3. **Run.** `POST /catalog/publish` → poll `GET /catalog/publish/status` (backoff, stop on terminal
   state, stop when the screen is disposed). Show "N of M published", a per-product list with sync
   pills, and the current stage.
4. **Partial failure.** Show "7 of 10 published · 3 failed", each failure with **our** message and a
   suggested action, plus one "Retry failed" button hitting `POST /catalog/publish/retry`.
   **Never display a raw Mirage message.**
5. **Success (feature 69).** "Live on Mirage" with the public link, the QR, Copy link, Share and
   Open. Show `lastPublishedAt`, and the "Draft changes not yet live" badge whenever
   `hasDraftChanges` is true (feature 38).
6. **Unpublish (feature 39).** Behind a confirmation that states clearly: the catalog goes offline,
   **the QR and link keep working and will show the catalog again when you republish.**
7. **QR screen.** Render the PNG from the backend, offer PNG and PDF download, Copy link, Share.
   The link shown is `catalog.publicUrl` **verbatim** — the client never composes or normalises it.

## Platform requirements — app AND web

- **Download vs share:** on mobile, save/share the bytes through `share_plus`; on web, trigger a
  browser download of the blob (anchor + `download` attribute) — a share sheet does not exist there.
  One repository method fetching bytes, two presentation paths, selected by `kIsWeb` (this is a
  genuine capability difference, unlike layout).
- Copy-to-clipboard works on both; on web it needs the secure-context clipboard path with a
  fallback, and the copy confirmation must be visible.
- The QR image must be printable from the browser at usable resolution.
- Polling must pause when the browser tab is hidden and resume on focus.

## What NOT to change

- `publicUrl` — display only, never modify.
- The publish state machine — the client reflects server truth and holds no local publish state.

## Edge cases to handle

- Publish pressed twice → the second gets `409`; show the in-progress run instead of an error.
- App backgrounded / tab closed mid-run → on return, status shows the run's real state; nothing is
  lost, and the client does not re-trigger a publish.
- Every product failed → clear failure state with retry, and the catalog is honestly not live.
- Publish on an unprovisioned catalog whose name collides on Mirage → show the suggested name and a
  one-tap rename.
- QR requested before first publish → the backend's `409`; the screen explains that publishing mints
  the permanent link.
- Offline → publish is disabled with an explanation, not a failed request.

## Acceptance criteria

- [ ] The gate checklist blocks a doomed publish and deep-links to each fix.
- [ ] Live progress polls, backs off, and stops on terminal state and on dispose.
- [ ] A partial run shows counts, per-product reasons and a working "Retry failed".
- [ ] No raw Mirage text can reach the UI (asserted with a fake returning Mirage prose).
- [ ] Success shows link + QR; Copy, Share (mobile) and Download (web) all work.
- [ ] Unpublish confirmation states that the QR keeps working.
- [ ] Verified in Chrome and on an APK build.

## Testing instructions

`test/catalog/publish_screen_test.dart`, `test/catalog/qr_screen_test.dart`: gate checklist, polling
lifecycle (including dispose and tab-hidden), partial failure rendering + retry, 409 handling,
no-Mirage-prose assertion, download path selection per platform.
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
