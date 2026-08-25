# ReCapture Client — Batch 01 · F1 + F2 · Product Grid and Product Editor

> **Status: ✅ complete.** F1 and F2 have landed. This file is kept as the reference for what was
> built and as the contract later batches extend — F3, F4 and F5 all layer onto the F1 grid, and
> F10's feedback seam replaces the ad-hoc snackbars these two screens introduced. Re-read it before
> touching the grid or the editor; do **not** re-implement it.

**Batch scope:** the two screens the business user actually lives in — browsing the catalog, and
editing one product in it.

- **F1 — Product grid** (task T-017; features 27, 28, 29, 9, 10) — responsive grid, filter chips,
  debounced server-side search, cursor infinite scroll, four distinct states, drag reorder.
- **F2 — Product editor** (task T-019; features 14, 15, 16, 17, 18) — every field editable, replace
  image, replace/convert model, duplicate, draft-vs-live indication, unsaved-changes guard.

**Why these two ship together:** F2 is reached from an F1 card and returns to it. They share the
product entity, the category picker source and the sync-status pill, and an edit in F2 must be
reflected in the F1 grid without a full refetch — that write-back is only testable with both in
place. They are one reviewable slice.

**Delivery order inside the batch:** F1 first (F2 depends on it).

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
| [02](batch-02-archive-and-categories.md) | F3 · F4 | Archive/restore/delete · Category manager | F1 | ✅ complete |
| [03](batch-03-bulk-and-business-profile.md) | F5 · F6 | Bulk selection · Business profile | F1, F3, F4 | ✅ complete |
| [04](batch-04-preview-and-publish.md) | F7 · F8 | Catalog preview · Publish + QR | F1 · backend B4, B5 | ✅ complete |
| [05](batch-05-analytics-and-feedback.md) | F9 · F10 | Analytics dashboard · Feedback layer | F1, F2, F8 · backend B7 | ✅ complete |
| [06](batch-06-web-parity-and-tests.md) | F11 · F12 | Web parity pass · Test hardening | F1–F10 | ✅ complete |

Full pack context: `../README.md` · original combined file: `../02-recapture-client-prompts.md`
(this batch is a verbatim extract of it — the prompt text is unchanged).

---

# F1 — Product grid: filters, search, pagination

```
# FEATURE: Catalog Product Grid — grid/list, filters, search, infinite scroll
# Product: ReCapture (Flutter — Android/iOS + Web)
# Phase: Next Phase — Catalog Authoring
# Track: Client
# Scope: New Feature (task T-017; features 27, 28, 29, 9, 10)
# Priority: Critical — this is the screen the business user lives in

---

## Context

`catalog_screen.dart` today is a shell: header card, status chips and the first-run empty state. The
product surface itself does not exist. The backend is complete — `GET /catalog/products` supports
cursor pagination, filtering by category/status/type and name search, all index-backed.

## Task

Build the product browsing surface inside the existing catalog shell: a responsive grid of product
cards, filter chips, debounced search, infinite scroll, and the empty/loading/error states.

## Files to inspect first

1. `lib/presentation/screens/catalog/catalog_screen.dart` — extend this, do not replace it
2. `lib/data/repositories/catalog_products_repository.dart:91-100` — the `list` signature and
   `CatalogProductPage`
3. `lib/application/catalog/catalog_notifier.dart` — the existing notifier shape
4. `lib/presentation/widgets/project_card.dart` — the card idiom to match
5. `lib/presentation/widgets/model_picker_field.dart:34` — **the constraints-not-`kIsWeb` rule**
6. `lib/presentation/screens/projects/` — the existing list screen for pagination/error idiom

## Implementation instructions

1. **A `catalogProductsNotifier`** in `lib/application/catalog/` owning: query (category, status,
   type, search text), pages, loading/error, and append-on-scroll. Pure state; it calls the
   repository and never touches Dio.
2. **Product card widget** in `lib/presentation/widgets/catalog/product_card.dart`: thumbnail
   (3D → generated preview, image-only → its image), name, price, a type badge (3D / Image),
   an availability badge when out of stock, a featured marker, and the **sync status pill** driven
   by `product_sync_status.dart` (reuse `app_status_pill.dart`).
3. **Filters** as chips: category (from `listCategories`), type, availability, archived. Multi-chip
   state lives in the notifier, and changing a filter resets pagination.
4. **Search**: debounce ~300 ms, server-side (`list(search:)`), never a client-side filter over one
   page — that would silently lie past the first page.
5. **Infinite scroll** on the cursor. Guard against double-fetch at the boundary. Show a footer
   spinner, and a "load failed — retry" footer that does not destroy the loaded pages.
6. **States:** first-run empty (no products), filtered-empty (different copy plus "clear filters"),
   loading skeletons, and an error state with retry. All four are distinct — a filtered-empty screen
   that says "add your first product" is a bug.
7. **Reorder affordance** (features 9, 10): long-press-drag on phone, drag handle on wide layouts,
   persisting via `reorder(orderedIds)` optimistically with rollback on failure.

## Platform requirements — app AND web

- **Layout from `BoxConstraints`, never `kIsWeb`:** ~2 columns under 600 px, 3 under 900, 4 under
  1200, 5 above. A narrow browser window must render the phone layout.
- Web: hover states on cards, keyboard focus traversal through cards and chips, and scroll-wheel
  scrolling. Mouse drag must work for reorder where touch drag works.
- Web: the search field must not trap browser shortcuts; `Ctrl/Cmd+F` stays the browser's.
- Test both: `flutter run -d chrome` and an APK build.

## What NOT to change

- The repositories, entities or backend contract.
- `catalog_screen.dart`'s existing header/empty-state behaviour — extend around it.
- Do not implement editing, archiving, bulk mode or categories management here (F2/F3/F4/F5).

## Edge cases to handle

- Catalog with 0 products vs filters matching 0 products.
- A product whose thumbnail URL 404s → placeholder, never a broken-image box.
- Search text that matches nothing → filtered-empty state with the query echoed.
- Pagination while a filter changes mid-flight → the stale page must be discarded, not appended.
- A product in `syncStatus: FAILED` → pill is visible in the grid without opening the product.
- Very long product names → ellipsis, no layout overflow (assert with a golden or a layout test).

## Constraints

- Riverpod only; notifiers call repositories only. No HTTP in the presentation layer.
- Parse nothing here — entities already parse field-by-field.
- No new state, HTTP or navigation package.
- Existing theme tokens only (`app_colors`, `app_spacing`, `app_typography`).

## Acceptance criteria

- [ ] Grid renders 2/3/4/5 columns purely from constraints, verified in a widget test at four widths.
- [ ] Search is server-side and debounced; a page-2 result set is still filtered correctly.
- [ ] Infinite scroll never double-fetches and never loses loaded pages on a failed append.
- [ ] All four states (empty, filtered-empty, loading, error) render distinctly.
- [ ] Reorder persists, and rolls back visibly on failure.
- [ ] Works in `flutter run -d chrome` and on a device build.

## Testing instructions

`test/catalog/product_grid_test.dart` — widget tests at 4 widths, debounce behaviour with a fake
clock, pagination boundary, stale-response discard, all four states. Repositories faked; no network.
```


---

# F2 — Product editor: edit, replace model, replace image, convert, duplicate

```
# FEATURE: Product Editor Screen
# Product: ReCapture (Flutter — Android/iOS + Web)
# Phase: Next Phase — Catalog Authoring
# Track: Client
# Scope: New Feature (task T-019; features 14, 15, 16, 17, 18)
# Priority: High (V1.1)
# Depends on: F1

---

## Context

`/catalog/products/:productId` is declared but not registered, and
`lib/application/catalog/product_detail_notifier.dart` is a 22-line stub. The backend is complete:
`PATCH /catalog/products/:id`, `PUT /catalog/products/:id/image`, the image presign/commit trio, and
`POST /catalog/products/:id/duplicate`. `change_product_model_screen.dart` already handles
re-pointing a 3D product at a different model.

## Task

The product editor: every field editable, replace image, replace/convert model, duplicate, and
a clear indication of what is live vs draft.

## Files to inspect first

1. `lib/presentation/screens/catalog/add_product_screen.dart` — form idiom, validation, submit flow
2. `lib/presentation/screens/catalog/change_product_model_screen.dart` — the model-replacement flow
3. `lib/data/repositories/catalog_products_repository.dart:136-190`
4. `lib/data/datasources/product_image_picker.dart` — already has a web-safe bytes path
5. `lib/application/catalog/product_detail_notifier.dart` — fill this in
6. `lib/presentation/widgets/app_text_field.dart`, `model_picker_field.dart`

## Implementation instructions

1. Register `/catalog/products/:productId` in `app_router.dart` (remove it from the
   not-yet-registered comment block at `app_router.dart:282-286`).
2. Fields: name, description, price + currency, category (picker), tags (chip input, max 20, ≤40
   chars each, lower-cased and de-duplicated to match the backend), availability toggle, featured
   toggle. Validate client-side to the same bounds as `catalogSchemas.ts` so the user does not
   discover limits from a server error.
3. **Replace image** — reuse `product_image_picker.dart` → `createImageSlot` → `uploadImageBytes`
   (presigned PUT) → `commitImage`. Show real progress; the presigned URL is a bearer credential and
   must never be logged or persisted.
4. **Replace model / convert image-only → 3D** — route into `change_product_model_screen.dart`.
   Conversion must warn plainly that the product's public appearance changes at the next publish.
5. **Duplicate** — one action, server-side; the copy is auto-renamed to dodge Mirage's
   per-restaurant name uniqueness. Navigate to the copy after creating it.
6. **Dirty/live indication:** show which fields differ from what is live, and a persistent
   "changes go live on publish" line. Never imply an edit is already public.
7. Unsaved-changes guard on back/close, and on web also on browser back and tab close
   (`onBeforeUnload`-equivalent via the router's exit guard).

## Platform requirements — app AND web

- Two-column form on wide layouts, single column narrow — decided from constraints.
- Web: file picking uses the existing bytes path (`dart:io` `File` does not exist on web); keyboard
  submit (Enter) and Escape-to-cancel; focus order follows visual order.
- Web: the presigned S3 `PUT` requires the bucket's CORS rule to allow the web origin — verify
  before shipping, and surface a specific error if it is blocked rather than a generic failure.
- Mobile: gallery permission flow unchanged; reuse the existing permission handling.

## What NOT to change

- The capture pipeline, `change_product_model_screen.dart`'s selection logic, or the image key
  scheme.
- Do not add a second image picker or a gallery of multiple images (parked in brief §G).

## Edge cases to handle

- Editing a product currently mid-publish → block the edit with a clear message, or queue it as
  draft; pick one and be consistent with the backend's behaviour.
- Price cleared → the backend treats a falsy price as "no price"; the UI must say so, not show 0.
- Tag limit exceeded → inline, before submit.
- Image upload succeeds but commit fails → retry commit without re-uploading.
- Category deleted while the editor is open → refresh the picker and mark the product uncategorized.
- Duplicate of a product whose name already ends in "(copy)" → still unique.

## Acceptance criteria

- [ ] Every field round-trips through `PATCH` and re-renders from the server response.
- [ ] Image replacement runs presign → PUT → commit with progress, on both platforms.
- [ ] Conversion warns before it commits.
- [ ] Unsaved-changes guard fires on in-app back **and** browser back.
- [ ] No presigned URL is ever logged.

## Testing instructions

`test/catalog/product_editor_test.dart`: field validation bounds, dirty tracking, guard on exit,
upload-then-commit-retry, duplicate navigation. Repositories faked.
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
