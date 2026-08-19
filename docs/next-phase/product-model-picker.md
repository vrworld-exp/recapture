# Implementation Prompt — Pick a Specific Model for a Product (Add + Change)

**Scope:** Flutter client (one codebase, ships to **Android APK and Web**) plus
**one small additive backend change** (two fields on `ProductDto`). No new
endpoint, no new worker job, no schema migration.

Read `AGENTS.md` first — it wins over anything below that contradicts it.

---

## The decision (read first)

A capture (a `Project`) can hold **many** `ProjectModel` records: the auto
generation that ran when the capture finished, every manual regenerate, and the
`optimized` derivative that one tap on **Optimize** inserts. `AGENTS.md`
§"3D models: two origins, one shape" is explicit that this is a **history**, not
a single slot.

The Add Product form ignores all of that. Today:

- `lib/presentation/screens/catalog/add_product_screen.dart:422` —
  `_ModelSourceField` lets the user pick a **project** from a dropdown;
- `add_product_screen.dart:80` — `_selectedModelId` then reads
  `ownerModelStateProvider(projectId)` and takes **whatever single model
  `GET /projects/:id` calls the latest** — which, per `AGENTS.md`, silently
  becomes the `optimized` record once one succeeds;
- `add_product_screen.dart:502` — `_SelectedModelStatus` shows a green
  "Ready to use" tick for that one model.

So the user chooses a capture and the app chooses the model. **A user who
regenerated because the first result was wrong has no way to say which result
they meant**, and no way to see that a second one exists at all.

This feature makes the model an **explicit, visible choice**:

> Choose a capture → the screen immediately lists **every model that capture
> has**, each one previewable → the user picks one → that model's id is what
> `POST /catalog/products` receives.

And the same choice must stay available **after** the product exists, so a
product can be re-pointed at a different model when feedback comes in — which
is the whole reason regenerate exists.

### Why the data side is already done

`AGENTS.md` §"A project's models are read through TWO parallel surfaces": the
owner list route, DTO, parser, repository method and polling notifier all exist
and are proven by the owner model-history screen. This feature is **almost
entirely a UI rewire onto providers that already run**. Do not build a second
fetch path.

### What this is NOT

- **Not a new endpoint.** `GET /projects/:id/models` →
  `data/repositories/live_projects_repository.dart:389` `listOwnerModels` →
  `application/projects/owner_model_history_notifier.dart:114`
  `ownerModelHistoryProvider` already returns exactly the list this screen
  needs, with live polling and backoff. Use it.
- **Not a staff surface.** Never call `/admin/projects/:id/models`,
  `tryFromStaffMap` or `listModels` from the catalog. An owner gets a 404 there
  by design, and an *admin* who does not own the project gets that 404 too —
  routing around it would be the "second, weaker door" `AGENTS.md` forbids.
- **Not a change to `ownerModelStateProvider` / `fetchModelState` /
  `tryFromOwnerMap`.** They serve the project screens' "we're building it"
  banner. Leave them byte-for-byte as they are; this screen simply stops using
  them.
- **Not an Approve, Export, Delete or Regenerate surface.** The picker's only
  actions are *select* and *preview*.
- **Not a full product editor.** Task C6 adds ONE focused change-the-model flow,
  not the product grid (still "arrives with the next release" at
  `catalog_screen.dart:150`).
- **Not "show the newest and hide the rest behind a More link."** Rejected: the
  comparison IS the feature. Every model the capture has is on screen.

---

## Flow end-to-end

**Add (both platforms)**

1. Catalog → **Add product** → source = **3D model**.
2. **Capture** dropdown — unchanged list, still only captures with
   `hasViewableModels` (`modelCount`, which the backend counts as
   `status: 'SUCCEEDED'` only — `projectsService.ts:325`).
3. The moment a capture is chosen, **the model list for that capture renders
   underneath it**: one tile per `ProjectModel`, newest first, each showing its
   preview thumbnail, when it was made, its status, and its `OPT` / size /
   "AI generated — preview quality" badges.
4. The newest **viewable** model is **preselected** (see D2). The user can tap
   any other viewable tile to switch, or tap **Preview** on a tile to open it in
   the 3D viewer and come back with the selection intact.
5. Changing the capture **clears the model selection** and loads that capture's
   list.
6. **Create** sends the explicitly selected `sourceModelId`.

**Change later (both platforms)**

1. A 3D product → **Change 3D model**.
2. The same picker opens, preselected on the product's **current** model, with
   that tile marked **Current**. The capture dropdown is preselected to the
   product's `sourceProjectId` but stays changeable — a user may want a model
   from a completely different capture.
3. **Save** sends `PATCH /catalog/products/:id { sourceModelId }`.
   `catalogProductsService.ts:474` already re-resolves ownership, copies the new
   artifacts onto the product and re-stamps `sourceProjectId`.
4. The product's `syncStatus` goes stale; the change reaches customers on the
   next **Publish**. Say so in the UI — this is a draft edit like every other
   write on this surface.

---

## Existing pieces to REUSE (do not reinvent)

| Piece | Where | Use it for |
|---|---|---|
| `ownerModelHistoryProvider(projectId)` | `application/projects/owner_model_history_notifier.dart:114` | The model list + live polling while a generation runs. Family-keyed, auto-disposed. |
| `listOwnerModels` | `data/repositories/live_projects_repository.dart:389` | Already wired under the provider. Do not call it directly. |
| `ProjectModelView.tryFromOwnerListMap` | `domain/entities/project_model.dart:317` | The owner shape: real `status`, optional `glbUrl`, no staff fields. |
| `ModelRow` | `presentation/widgets/model_row.dart:24` | The visual vocabulary — thumbnail, timestamp, status, `OPT` badge, size. See C2 for how to share it without breaking its two current callers. |
| `ModelViewerScreen` (direct push, no `onApprove`) | `presentation/screens/projects/owner_model_history_screen.dart:85` | Preview-a-model. Copy this call shape exactly, including *not* using the `modelViewer` named route. |
| `projectsProvider` | `application/projects/projects_notifier.dart` | The capture dropdown. Unchanged. |
| `CatalogProductsRepository.update(..., sourceModelId:)` | `data/repositories/catalog_products_repository.dart:299` | The change-model PATCH. Already accepts the field. |
| `mapCatalogErrors` / `CatalogFailure` | `data/repositories/catalog_failure.dart` | Owner-safe failure copy. Never invent a message for a mapped code. |
| `failureCopy(error)` | `presentation/screens/projects/preview_gallery_screen.dart` | The one translator for `LiveProjectsException` on the projects side. |

---

## Non-negotiable contracts

1. **Only a `SUCCEEDED` model with a `glbUrl` is selectable.**
   `ProjectModelView.isViewable` is the ONLY test. `resolveOwnedModel`
   (`catalogProductsService.ts:368`) returns `MODEL_NOT_READY` otherwise, so a
   selectable pending tile is a guaranteed round-trip failure.
2. **Pending and FAILED models are still SHOWN, just not selectable.** A capture
   whose regenerate is mid-flight must say so; hiding the row makes the app look
   like it lost a model. Render them dimmed, with a one-line reason and no radio.
3. **`canOptimize` and `sizeBytes` are the SERVER's verdicts.** Never re-derive
   eligibility or a threshold on the client (`AGENTS.md`). This screen shows no
   Optimize button at all, but if you display size, use the existing
   `formatBytes` with its 1024 divisor — a second formatter is how "5.0 MB"
   starts disagreeing with the backend's binary threshold.
4. **Owner projections stay field-by-field.** If you touch `ProductDto`, add the
   two named fields; never spread a record into an owner DTO.
5. **No new polling loop.** `OwnerModelHistoryNotifier` already polls with
   backoff and a hard cap. The screen is a pure observer.
6. **One envelope, one failure seam.** `{ status, ... }` on the API side;
   `CatalogFailure` / mapped copy on the client. No raw `DioException` text and
   no error code ever reaches a user's eyes.
7. **`sourceModelId` and `sourceProjectId` are the owner's own ids** — safe to
   return to that owner, and to nobody else. The route is already scoped by
   `findOwnedCatalog`; do not widen it.

---

## Design decisions already made (do not re-litigate)

- **D1 — The list is inline on the form, not a pushed page.** The user is
  comparing models *in the middle of filling in a form*; a full-screen push
  costs the form's scroll position on every comparison. On a wide viewport the
  list sits in a bounded, internally scrolling panel (see the Web/APK section).
  The **Change 3D model** flow (C6) IS a pushed screen, because there is no form
  around it.
- **D2 — The newest viewable model is preselected on Add.** That is exactly what
  the app picks today, so a user who does not care about the choice loses no
  taps and gains no new required interaction. The difference is that the choice
  is now *visible and changeable*. On **Change**, the preselection is the
  product's **current** model instead.
- **D3 — Radio semantics, one selection.** A product has exactly one
  `sourceModelId`. No multi-select, no "compare two side by side".
- **D4 — Preview is a separate affordance from select.** Tapping a tile
  *selects*; tapping its explicit **Preview** control *opens the viewer*. One
  gesture doing both means every comparison changes the answer.
- **D5 — The `optimized` record is offered like any other, and labelled `OPT`.**
  It is usually the right pick (smaller file, same geometry), but per `AGENTS.md`
  it is a derivative with no origin — it must not claim "Created by Maya AI".
  Do not auto-force it and do not hide it.

---

## Tasks

### B1 — Expose the product's model pointers on `ProductDto`

`recapture-api/src/services/catalogProductsService.ts`

`ProductDto` (line 51) carries `glbUrl` / `usdzUrl` / `thumbnailUrl` but **not**
`sourceModelId` or `sourceProjectId`, so a client editing a 3D product cannot
say which model it currently uses or which capture to open the picker on. Add
both, as string-or-null, mapped field-by-field in `toProductDto` (line 86):

```ts
sourceProjectId: p.sourceProjectId ? p.sourceProjectId.toHexString() : null,
sourceModelId:   p.sourceModelId   ? p.sourceModelId.toHexString()   : null,
```

Both are already on the model (`models/CatalogProduct.ts:67`, `:131`) and
already written by create (`:317`) and update (`:482`). This is additive: every
existing consumer keeps working, and an image-only product returns `null` for
both.

Mirror them on the client entity `domain/entities/catalog_product.dart` as
`final String? sourceProjectId;` / `final String? sourceModelId;`, parsed
defensively (absent → null) so an older backend does not break the app.

**Do not** add anything else to this DTO. No model list, no artifact keys, no
generation trace — the picker reads models from the projects surface, which is
where they live.

### C2 — Make the model row reusable for selection

`lib/presentation/widgets/model_row.dart`

`ModelRow`'s affordances are "open this" (chevron) and "optimize this". In a
picker a chevron would lie: the tap selects. Its two current callers
(`model_history_screen.dart`, `owner_model_history_screen.dart`) must keep
behaving **exactly** as they do now.

Do the smaller of these two, in this order of preference:

1. **Extract the presentation helpers** currently private to that file — the
   thumbnail widget, `_stamp`, `_statusLabel`, the `OPT` / approved badges —
   into shared members (same file, made public, or a new
   `presentation/widgets/model_presentation.dart`), and build a new
   `ModelChoiceTile` on top of them. `ModelRow`'s own layout stays untouched.
2. Only if (1) turns out to duplicate the entire layout anyway: add a
   `selection` parameter to `ModelRow` that swaps the trailing chevron for a
   radio and suppresses `onOptimize`, defaulting to the current behaviour.

`ModelChoiceTile` renders:

- the model's preview thumbnail (`previewUrl`), with the same placeholder
  `ModelRow` uses when there is none;
- `{timestamp} · {status}`;
- badges: `OPT` when `isOptimized`, size when `sizeBytes != null`,
  `kAutoGeneratedBadgeLabel` when `isAutoGenerated`, `source.badgeLabel` when
  non-null (so an `optimized` row correctly shows no origin);
- a **Current** chip when the tile is the product's existing model (C6 only);
- a leading radio reflecting selection;
- a trailing **Preview** control, enabled only when `isViewable`;
- when `!isViewable`: dimmed, radio absent, and one line of reason copy —
  pending → "Still building — you can pick this once it finishes.";
  failed → "This one didn't finish."

`ModelChoiceTile` takes no repository and no provider. Props in, callbacks out.

### C3 — Replace the model half of the Add Product form

`lib/presentation/screens/catalog/add_product_screen.dart`

1. **Delete the derived getter** at line 80. `_selectedModelId` becomes real
   state: `String? _selectedModelId;`.
2. **Clear it whenever the capture changes** — in the `onChanged` at line 207,
   set `_selectedModelId = null` alongside `_selectedProjectId`. A stale model id
   from the previous capture reaching `_submit` is the one bug this feature can
   introduce; make it structurally impossible.
3. **Replace `_SelectedModelStatus`** (line 502 — delete it) with a new
   `_ModelChoiceList` beneath the dropdown inside `_ModelSourceField`, driven by
   `ref.watch(ownerModelHistoryProvider(selectedProjectId))`:
   - `loading` → `AppLoadingIndicator` in a fixed-height box, so the form does
     not jump when the list lands;
   - `error` → the existing owner-safe copy plus a **Retry** that calls
     `ref.invalidate(ownerModelHistoryProvider(projectId))`;
   - `data` with no viewable model → "This capture has no finished 3D model yet."
     plus any pending row, so the user sees *why*;
   - `data` → the tiles, newest first (the backend already orders them), under
     the header **"Choose which model to use"** with a count.
4. **Preselect** per D2: on the first `data` frame for a capture where
   `_selectedModelId == null`, select the first `isViewable` model. Do this in a
   `ref.listen` / post-frame callback that calls back up to the form's state —
   never by mutating state during `build`.
5. **`_submit`** (line 112) is unchanged in shape, but `sourceModelId` now comes
   from `_selectedModelId` directly. Keep the guard and its message, retuned:
   "Choose which 3D model this product should use."
6. `ownerModelStateProvider` and its import leave this file. Nothing else in the
   app changes.

### C4 — Preview from the picker

Add a `_openModelPreview` on the form that pushes `ModelViewerScreen` directly —
**copy the call shape at `owner_model_history_screen.dart:85`**:

- direct `MaterialPageRoute` push, **not** the `modelViewer` named route (that
  route resolves the record from the STAFF provider; an owner only ever 403s);
- `onApprove` omitted, `onRegenerate` null;
- `onOptimize` **null too** — Optimize belongs on the project's model history,
  not inside a product form, and a new pending record appearing mid-form is a
  distraction the user did not ask for;
- `renderBuilder: ModelViewerScreen.defaultRenderBuilder`, injectable for tests.

Guard on `model.isViewable` before pushing, as that screen does. Returning from
the viewer must leave the selection, the scroll position and every typed field
untouched.

### C5 — Route + entity plumbing for change-model

- Register `AppRoutes.productDetail` (declared but unregistered at
  `app_router.dart:100`) or add a sibling
  `/catalog/products/:productId/model` — pick ONE and say why in a comment.
  Recommended: the sibling, because it is a single-purpose screen and does not
  pre-empt whatever the real product editor becomes.
- Wrap it in `FlowBackScope` and route back through `navigateBack`, like every
  other pushed screen in this router.
- The screen must work on a **cold deep link** (a web reload on that URL): it
  takes only `productId` from the path, fetches the product via
  `CatalogProductsRepository.get(id)` (line 261), and shows the mapped
  not-found state for a stale id. Nothing may arrive via `extra`.

### C6 — The "Change 3D model" screen

`lib/presentation/screens/catalog/change_product_model_screen.dart`

- Loads the product, reads `sourceProjectId` / `sourceModelId` (B1).
- Renders the **same** capture dropdown + `ModelChoiceTile` list as C3 —
  extract that pair into one shared widget rather than copying it; it is the
  feature.
- Preselects the product's current capture and current model, and marks that
  tile **Current**. If the current model no longer appears in the list (deleted
  project, purged record), say so plainly and let the user pick another; do not
  crash and do not silently preselect something else.
- **Save** is disabled until the selection differs from the current model.
- Save → `update(productId, sourceModelId: selectedId)` → on success pop with a
  snackbar naming the product, and show the draft sentence: "Customers will see
  this after you publish."
- On failure, show `CatalogFailure.message` — `MODEL_NOT_FOUND` and
  `MODEL_NOT_READY` both already carry owner-safe copy from the backend. Do not
  add a local translation table.
- Entry point: from the product surface. The grid does not exist yet
  (`catalog_screen.dart:150`), so wire the entry from wherever a single product
  is reachable when this lands, and — if that is still nowhere — leave the route
  registered and add ONE line to the catalog body's placeholder explaining how
  to reach it, exactly as `catalog_screen.dart:158` already does for Add Product.
  **Do not** build a grid to hang this off; that is T-017's job.

---

## Web and APK — one codebase, two shells

Both targets build from this same Dart. The differences that actually bite:

- **Layout.** On a narrow viewport (phone / APK) the model list is a vertical
  list of full-width tiles inside the form's `ListView`. On a wide viewport
  (browser) it must not become a 1200px-wide row of stretched tiles: constrain
  the form column (`ConstrainedBox`, ~640dp) and lay the tiles out as a wrapping
  grid or a bounded, internally scrolling panel with a fixed max height. Decide
  with `LayoutBuilder` / `MediaQuery.sizeOf`, **not** `kIsWeb` — a small browser
  window is a phone layout, and a tablet APK is not a phone.
- **Nested scrolling.** A bounded scrolling list inside the form's `ListView` is
  the one place this can go wrong on web. Give the inner list `shrinkWrap: true`
  + `NeverScrollableScrollPhysics` when it is short enough to inline, and only
  switch to a bounded scroller past a tile count you pick deliberately.
- **3D preview.** `ModelRenderView` (`model_render_view.dart:246`, `:361`)
  already branches on `kIsWeb` — WebView on mobile, the platform view on web.
  Do not add a second branch. ⚠ Per `AGENTS.md`, the meshopt decoder trigger
  must be present in **both** `web/index.html` and `_lifecycleJs`
  (`model_render_view.dart:116`); an `optimized` model fails to load on
  whichever page is missing it, and `test/projects/meshopt_decoder_test.dart`
  guards the pair. Since `OPT` models are first-class choices here, this is
  load-bearing for the feature — run that test.
- **Thumbnails.** `previewUrl` is a CloudFront URL and loads identically on both;
  give `Image.network` an `errorBuilder` so a 403/404 renders the placeholder
  rather than a broken-image box.
- **Hover and focus.** Web users get hover and a keyboard: the tiles must be
  real `InkWell`s with focus traversal in list order, and Preview must be
  reachable by keyboard. Do not rely on long-press for anything.
- **Back.** Route everything through `navigateBack` / `FlowBackScope` so the
  browser Back button and Android hardware Back behave identically, including on
  a `go()`-replaced entry.
- **Verify on both** before calling this done: `flutter run -d chrome`, and
  `flutter build apk --release` + install. A screenshot of the picker on each.

---

## Tests & verification

`flutter test` — hermetic, no real network, per `AGENTS.md` §Testing. Add under
`test/catalog/`:

1. **Selection is explicit.** Given a project with three SUCCEEDED models, the
   form preselects the newest, and tapping the third makes `_submit` send *that*
   id. Assert on the repository call's `sourceModelId`, not on the widget.
2. **Changing the capture clears the selection.** Pick capture A, select its
   second model, switch to capture B → the previous id is gone, and Create with
   no selection shows the guard message instead of posting.
3. **Pending/failed are visible but inert.** A list with one SUCCEEDED, one
   PROCESSING and one FAILED renders three tiles, one radio, and tapping the
   pending tile changes nothing.
4. **`OPT` is selectable and labelled.** An `optimized` record shows the `OPT`
   chip, shows **no** "Created by Maya AI", and can be chosen.
5. **No staff route is ever hit.** Fake the Dio/repository layer and assert that
   `/admin/...` is never requested from this screen — this is the contract that
   silently breaks first.
6. **Change-model round trip.** Product with model M1 → screen preselects M1 and
   marks it Current → Save is disabled → select M2 → Save issues
   `update(id, sourceModelId: M2)`.
7. **`MODEL_NOT_READY` surfaces mapped copy**, not a code and not a raw
   exception string.
8. **Existing tests stay green** — `test/projects/meshopt_decoder_test.dart` and
   whatever covers `owner_model_history_screen` / `ModelRow`. If C2 option (1)
   moved a helper, update the callers, not the assertions.

Backend (`cd recapture-api && npm test`):

9. `toProductDto` returns both new ids for a 3D product and `null` for an
   image-only one; the existing product suites still pass unchanged.

Also clean: `flutter analyze`, plus `npm run type-check` and `npm run lint` if
B1 was touched.

---

## Definition of done

- [ ] Choosing a capture in Add Product immediately lists **every** model that
      capture has, newest first, each with thumbnail, age, status and badges.
- [ ] The newest viewable model is preselected; any other viewable model can be
      chosen in one tap; the choice is what gets posted.
- [ ] Pending and failed models are visible, dimmed, explained, unselectable.
- [ ] Preview opens the 3D viewer for any viewable model and returns with the
      form and the selection intact.
- [ ] Switching capture clears the model selection.
- [ ] A 3D product can be re-pointed at a different model afterwards, from
      either the same capture or a different one, and the current model is
      marked as such.
- [ ] `ProductDto` carries `sourceProjectId` + `sourceModelId`; the Flutter
      entity parses both, tolerating their absence.
- [ ] No `/admin` route, no `tryFromStaffMap`, no second polling loop, no second
      fetch path anywhere in this feature.
- [ ] `ownerModelStateProvider`, `fetchModelState` and `tryFromOwnerMap` are
      untouched, and the project screens that use them behave as before.
- [ ] Verified by hand on **Chrome (web)** and on a **release APK**, including
      an `optimized` model loading in the viewer on both.
- [ ] `flutter analyze`, `flutter test`, `npm run type-check`, `npm run lint`,
      `npm test` all clean.

---

## Open items to confirm while implementing (don't guess — verify)

1. **Does `GET /projects/:id/models` order newest-first?**
   `projectModelsService.ts` documents "newest first" — confirm it in the query
   before relying on "the first viewable is the newest". If it is not
   guaranteed, sort by `createdAt` on the client and say so in a comment.
2. **`createdAt` on the owner list DTO** — `ProjectModelView.createdAt` is
   nullable and a malformed stamp parses to null. Decide what an undated tile
   says (recommended: "Unknown date", still selectable) rather than letting the
   sort or the label throw.
3. **Does `modelCount` include `optimized` records?** It counts every
   `status: 'SUCCEEDED'` (`projectsService.ts:325`), so a capture with one
   generation plus its OPT copy reads as 2. That is correct for gating the
   dropdown; just make sure no copy anywhere says "1 model" from that number.
4. **Poll churn.** `ownerModelHistoryProvider` polls every 3–10s while anything
   is pending. Inside a form the user may sit on for minutes, confirm the
   provider is disposed when the source is switched from 3D to image-only —
   otherwise an image-only create keeps polling a project it no longer cares
   about.
5. **`_ModelSourceField`'s capture list** filters on `hasViewableModels`, so a
   capture whose only model is still building is absent entirely — correct
   today, but once the list shows pending rows, confirm the two behaviours read
   consistently to a user (a capture that cannot be chosen at all, vs a chosen
   capture showing a pending row).
6. **Duplicate-name and sync side effects on Change.** `updateProduct` bumps the
   draft revision and re-stamps assets; confirm the product's `syncStatus`
   transition after a model swap is what the catalog header reports, so the
   "unpublished changes" badge stays honest.
