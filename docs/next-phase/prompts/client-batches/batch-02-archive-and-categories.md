# ReCapture Client — Batch 02 · F3 + F4 · Archive/Delete and Category Manager

> **Status: ⬜ todo.** Depends on **F1** (batch 01), which is complete.

**Batch scope:** the two destructive/structural surfaces that sit on top of the product grid.

- **F3 — Archive / restore / permanent delete** (task T-020; features 19, 20, 21) — archive with
  undo, an Archived filter that lists and restores, permanent delete behind typed confirmation.
- **F4 — Category manager** (task T-021; features 22, 23, 24, 25, 26) — create, rename, delete with
  reassignment, drag/keyboard reorder, moving products between categories.

**Why these two ship together:** both are destructive actions over the same grid, both need the same
confirmation idiom (`delete_confirmation_modal.dart`), both do optimistic update with visible
rollback, and both change what the F1 filter chips show — the category chips read from F4's list and
the Archived chip is F3's. Building them apart means writing the optimistic-rollback plumbing twice.

**Delivery order inside the batch:** F3 first (smaller, and it establishes the rollback idiom that
F4 reuses).

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
