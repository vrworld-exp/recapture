# ReCapture Flutter Client Prompts — F1 … F12

Repo root for every prompt in this file: `phase2/ReCapture/` (work happens in `lib/` and `test/`).
`ReCapture/AGENTS.md` is the tie-breaker over anything written here.

**Every prompt in this file ships Android/iOS *and* Flutter web in the same change.** The shared
platform rules are restated in each prompt's "Platform requirements" block; the full list is in
`README.md` → "Platform rule that applies to every F-prompt".

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

# F3 — Archive, restore, permanent delete UI

```
# FEATURE: Product Archive / Restore / Delete
# Product: ReCapture (Flutter — Android/iOS + Web)
# Phase: Next Phase — Catalog Authoring
# Track: Client
# Scope: New Feature (task T-020; features 19, 20, 21)
# Priority: High (V1.1)
# Depends on: F1

---

## Context

The backend already exposes `POST /catalog/products/:id/archive`, `.../restore` and
`DELETE /catalog/products/:id`, and the repository already wraps all three. Archiving a **published**
product removes it from the live catalog at the next publish — that consequence must be visible.

## Task

Archive with undo, an Archived filter that lists and restores, and a permanent delete behind typed
confirmation.

## Files to inspect first

1. `lib/data/repositories/catalog_products_repository.dart:190-200`
2. `lib/presentation/widgets/delete_confirmation_modal.dart` — the existing destructive-action idiom
3. `lib/presentation/screens/catalog/catalog_screen.dart` + the F1 grid
4. `lib/app/theme/app_theme.dart:279` — `SnackBarThemeData`

## Implementation instructions

1. Archive from the card's overflow menu and from the editor. Optimistic removal from the grid, with
   an **undo** snackbar (restore call) for ~6 seconds.
2. An "Archived" filter chip in the F1 filter row; archived cards are visually muted and offer
   Restore as the primary action.
3. Permanent delete: typed confirmation (the product name), an explicit warning that a published
   product will be removed from the live catalog at the next publish, and that the action cannot be
   undone. Reuse `delete_confirmation_modal.dart`.
4. If the product is currently `SYNCED`, say so in the confirmation: "This product is live. It will
   be removed from your public catalog the next time you publish."

## Platform requirements — app AND web

- Web: the overflow menu opens on click and is keyboard-reachable; the typed-confirmation field
  submits on Enter and cancels on Escape.
- Undo snackbar must be reachable on wide layouts too (do not anchor it off-screen).

## What NOT to change

- The bulk-selection surface (F5).
- The backend's soft-delete semantics.

## Edge cases to handle

- Undo pressed after the snackbar's window → restore still works from the Archived filter.
- Archive while offline → the action fails cleanly with retry; no fake success.
- Delete of an already-deleted product (double tap) → treated as success, not an error.
- Archiving the catalog's last product → the grid falls back to the empty state, and publish will
  then be gated `CATALOG_EMPTY` — mention it.

## Acceptance criteria

- [ ] Archive is one tap with a working undo.
- [ ] The Archived filter lists archived products and restores them.
- [ ] Permanent delete requires the typed name and warns about live removal.
- [ ] Failures never leave the grid showing a state the server does not have.

## Testing instructions

`test/catalog/archive_restore_test.dart`: optimistic archive + undo, failure rollback, typed
confirmation gate, double-delete idempotence.
```

---

# F4 — Category manager with drag reorder

```
# FEATURE: Category Manager
# Product: ReCapture (Flutter — Android/iOS + Web)
# Phase: Next Phase — Catalog Authoring
# Track: Client
# Scope: New Feature (task T-021; features 22, 23, 24, 25, 26)
# Priority: High (V1.1)
# Depends on: F1

---

## Context

`/catalog/categories` is declared but unregistered. The backend and repository are complete:
`listCategories`, `createCategory`, `renameCategory`, `deleteCategory` (returns the number of
products reassigned), `reorderCategories`. Categories are **not optional** — Mirage's `create-item`
requires a real category id, so every publishable product needs one, and the Uncategorized bucket is
materialised server-side at publish.

## Task

A category management screen: create, rename, delete (with reassignment), drag-reorder, and moving
products between categories.

## Files to inspect first

1. `lib/data/repositories/catalog_repository.dart:76-95`
2. `lib/domain/entities/catalog_category.dart`
3. The F1 grid — category filter chips read from the same source
4. `lib/presentation/widgets/app_card.dart`, `delete_confirmation_modal.dart`

## Implementation instructions

1. Register `/catalog/categories`.
2. Reorderable list with per-row product counts. Reorder persists via `reorderCategories` with an
   optimistic update and visible rollback.
3. Create/rename inline with validation matching the backend bounds (80 chars).
4. Delete: if the category holds products, require a destination (reassign) or explicit
   "move to Uncategorized". Show the count that will move before confirming.
5. **Uncategorized bucket** is always present, always last, and cannot be renamed, reordered or
   deleted — it is a null `categoryId` locally, not a row.
6. Move products between categories: multi-select within a category, "Move to…" sheet.
7. Note in the UI, once and quietly, that the public catalog shows categories in the order set here.

## Platform requirements — app AND web

- Drag works with touch **and** mouse. On web also provide keyboard reordering (focus a row, then
  `Alt+↑/↓`) — drag-only is inaccessible on desktop.
- Wide layouts: master/detail (categories left, that category's products right). Narrow: a single
  list that pushes to the product sublist.

## What NOT to change

- The server's Uncategorized handling.
- Product editing beyond category assignment (F2).

## Edge cases to handle

- Renaming a category that is already live on Mirage → allowed; the change goes live at publish.
- Deleting a category with 100+ products → confirm with the count, and keep the UI responsive.
- Reorder while another device reordered → last write wins; refresh after failure rather than
  silently diverging.
- Two categories with the same name → the backend decides; surface its error inline.

## Acceptance criteria

- [ ] Create / rename / delete / reorder all persist and survive a refresh.
- [ ] Uncategorized is always present and never mutable.
- [ ] Deleting a non-empty category always tells the user where the products go, before it happens.
- [ ] Reorder works by touch, mouse and keyboard.

## Testing instructions

`test/catalog/category_manager_test.dart`: optimistic reorder + rollback, delete-with-reassign
counts, uncategorized immutability, keyboard reorder.
```

---

# F5 — Bulk selection mode

```
# FEATURE: Bulk Selection and Bulk Actions
# Product: ReCapture (Flutter — Android/iOS + Web)
# Phase: Next Phase — Catalog Authoring
# Track: Client
# Scope: New Feature (task T-022; feature 30)
# Priority: Low (V2)
# Depends on: F1, F3, F4

---

## Context

`POST /catalog/products/bulk` exists and the repository wraps it (`bulk(...) → int`). Bulk actions
only pay off past ~30 products, which is why this is V2 — but the server returns per-item results,
so the UI must not flatten a partial failure into "done".

## Task

Selection mode over the F1 grid with bulk delete, bulk category change, and bulk
archive/restore, reporting per-item outcomes.

## Files to inspect first

1. `lib/data/repositories/catalog_products_repository.dart:207-220`
2. The F1 grid notifier — selection state belongs there, not in the widget
3. `lib/presentation/widgets/delete_confirmation_modal.dart`

## Implementation instructions

1. Enter selection on long-press (touch) or via a "Select" button (always available on web).
2. A selection app bar: count, select-all-in-current-filter, clear, and the action row.
3. Actions: archive, restore, delete, change category. Destructive ones confirm with the count.
4. **Report per-item results**: "18 of 20 updated · 2 failed" with a list of the failures and a
   retry for just those. Never claim success for a partial run.
5. Selection survives scrolling and pagination; it does not survive a filter change (clear it, and
   say so).

## Platform requirements — app AND web

- Web: `Shift+click` range select, `Ctrl/Cmd+click` toggle, `Ctrl/Cmd+A` select-all within the grid,
  Escape exits selection mode.
- Mobile: long-press enters, tap toggles, back exits.

## Edge cases to handle

- Select-all across an un-loaded page → either scope it to loaded items and say so, or ask the
  server; do not silently apply to more than the user saw.
- A selected product deleted on another device → its row fails; report it, do not abort the rest.
- Bulk category change to a category deleted mid-flight → surfaces as a per-item failure.

## Acceptance criteria

- [ ] Partial failures are itemised with a retry for the failed subset.
- [ ] Selection is stable across scroll and pagination and cleared on filter change.
- [ ] Full keyboard/mouse selection on web; long-press on mobile.

## Testing instructions

`test/catalog/bulk_actions_test.dart`: partial-failure reporting, selection stability, range select.
```

---

# F6 — Business profile screen

```
# FEATURE: Business Profile
# Product: ReCapture (Flutter — Android/iOS + Web)
# Phase: Next Phase — Business Profile
# Track: Client
# Scope: New Feature (task T-023; features 58, 59, 60, 2)
# Priority: High (MVP-adjacent — the public page has no branding without it)
# Depends on: nothing beyond the existing repositories

---

## Context

`GET`/`PATCH /catalog/profile` and the logo/cover presign+commit endpoints exist, and
`business_profile_repository.dart` + `catalog_repository.dart:63-75` wrap them. `/catalog/settings`
is declared but unregistered. This profile is what brands the public Mirage catalog page.

## Task

An editable business profile: business name, logo, cover image, phone, email, address, website and
social links — with honest labelling of which fields reach the public page.

## Files to inspect first

1. `lib/data/repositories/business_profile_repository.dart`
2. `lib/data/repositories/catalog_repository.dart:63-75` (`createBrandingSlot`, `commitBranding`)
3. `lib/presentation/screens/profile/profile_screen.dart` — the existing profile idiom to match
4. `lib/data/datasources/product_image_picker.dart` — the web-safe image path

## Implementation instructions

1. Register `/catalog/settings`.
2. Fields with client-side validation matching the backend bounds (name 120, phone 32, email 254,
   address 300, website 200, socials 200 / whatsapp 40).
3. Logo and cover upload via the branding presign → PUT → commit flow, with crop-free preview and
   progress. Logo is what Mirage stores as the restaurant `icon`.
4. **Label reach honestly.** Mirage's restaurant record now carries `website`, `socialLinks` and
   `address`, so those do reach the public page — but only if the Mirage frontend renders them
   (prompt M5). Until M5 ships, mark them "saved, not yet shown publicly" rather than implying they
   are live. Verify the current Mirage state before choosing the wording.
5. Any profile edit marks the catalog dirty (the backend bumps `draftRevision`); surface "changes go
   live on publish".

## Platform requirements — app AND web

- Web: image picking through the bytes path; drag-and-drop a file onto the logo/cover slot is a
  welcome extra but must not be the only way to pick.
- Two-column form on wide, single column narrow, from constraints.
- Phone/email/website fields use the right input types and autofill hints on both platforms.

## What NOT to change

- `User` — business profile lives on `Catalog`, not on the account.
- The avatar flow in `profile_screen.dart` — that is a different key space and stays separate.

## Edge cases to handle

- Website entered without a scheme → normalise for display, store what the backend accepts.
- Logo upload succeeds, commit fails → retry commit without re-uploading.
- Very large image → the backend enforces a byte cap at commit; surface it as a specific message.
- Profile incomplete at publish time → publish gates will reject; link straight here from that error.

## Acceptance criteria

- [ ] All fields round-trip and re-render from the server response.
- [ ] Logo and cover upload work on device and in Chrome.
- [ ] The screen states plainly which fields are public and which are not.
- [ ] Editing marks the catalog as having unpublished changes.

## Testing instructions

`test/catalog/business_profile_test.dart`: validation bounds, upload retry-on-commit, dirty marking.
```

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
