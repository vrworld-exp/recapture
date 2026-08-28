# ReCapture Client — Batch 03 · F5 + F6 · Bulk Actions and Business Profile

> **Status: ✅ complete.** F5 and F6 have landed. This file is kept as the reference for what
> was asked for, not as work to do.

**Batch scope:** the last two authoring surfaces before publish — acting on many products at once,
and the branding that wraps them on the public page.

- **F5 — Bulk selection mode** (task T-022; feature 30) — selection over the F1 grid, bulk archive /
  restore / delete / change category, **per-item** result reporting with retry for the failed subset.
- **F6 — Business profile** (task T-023; features 58, 59, 60, 2) — business name, logo, cover, phone,
  email, address, website, socials, with honest labelling of what actually reaches the public page.

**Why these two ship together:** they are the two remaining pre-publish authoring screens, and they
are independent of each other — so they parallelise cleanly. F5 is V2 priority and F6 is
MVP-adjacent (the public page has no branding without it), so if the batch has to be cut, **ship F6
and defer F5**.

**Delivery order inside the batch:** F6 first (higher priority, no dependencies).

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
