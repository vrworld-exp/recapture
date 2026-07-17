✅✅✅✅✅✅✅✅✅✅✅✅✅/2

# Implementation Prompt — Staff Model History + Viewer Entry Point

Client-only (Flutter). **No backend change is needed or wanted** — every endpoint,
DTO field and repository method this feature needs already exists and is proven
in production data.

---

## The decision (read first)

Meshy generations work end-to-end (verified 2026-07-17: real `SUCCEEDED` records
with GLBs re-hosted to our CloudFront). But **a model is unreachable the moment
you navigate away from the screen that created it.** `ModelViewerScreen` has no
route in `lib/app/routes/app_router.dart` — it is only ever reached by a direct
push from `model_generation_screen.dart` right after a generation completes.

This feature adds the missing door: a persistent, staff-only per-project entry
point into the generation HISTORY, and a real route to the viewer.

**History, not "the latest model", is the point.** The backend deliberately
returns every attempt (`listProjectModels`, newest first) so an artist can
compare generations from different photo selections and approve the best one.
The UI must serve that comparison, not just surface the newest record.

### What this is NOT

- **Not an owner-facing change.** The owner surface is deliberately narrower:
  `GET /projects/:id` returns only the latest **SUCCEEDED** model, and
  `OwnerModelDto` omits `selectedKeys`, S3 keys and staff actor ids on purpose —
  an owner must not see failed attempts or learn who curated their project.
  `fetchModel` / `tryFromOwnerMap` stay exactly as they are. Do not touch them.
- **Not a new API.** `GET /admin/projects/:id/models` and
  `listModels()` already exist and already return everything below.
- **Not a redesign of the viewer.** `ModelViewerScreen` renders and badges
  correctly today; it just needs to be reachable.
- **Not `Model 1 / Model 2 / …` buttons on the card.** See C3 — that shape was
  considered and rejected for concrete reasons; do not implement it.

### Flow end-to-end

Staff opens Projects → project card shows a **`Models (N)`** button beside
`Preview` (only for staff, only when N > 0) → tap → **Model history screen**
(newest first, one row per attempt, live-polling while any record is pending) →
tap a viewable row → **`ModelViewerScreen`** via a real route → back returns to
the history.

---

## Existing pieces to REUSE (do not reinvent)

| Need | Already exists | Where |
|---|---|---|
| Fetch history | `listModels(projectId)` → `List<ProjectModelView>` | `lib/data/repositories/live_projects_repository.dart:183` |
| History + live polling + approve | `modelGenerationProvider` (family, keyed by projectId) | `lib/application/projects/model_generation_notifier.dart` |
| Model entity + status/source enums | `ProjectModelView`, `ModelStatus`, `ModelSource` | `lib/domain/entities/project_model.dart` |
| "Is this row tappable?" | `ProjectModelView.isViewable` | `project_model.dart:84` |
| "Created by Meshy AI" badge | `ModelSource.badgeLabel` — never infer origin | `project_model.dart:30` |
| The viewer itself | `ModelViewerScreen` | `lib/presentation/screens/projects/model_viewer_screen.dart` |
| Staff gating | `UserRole.isStaff` (fails CLOSED) | `lib/domain/entities/user_role.dart:19` |
| Optional staff card action | `ProjectCard.onPreview` nullable-callback pattern | `lib/presentation/widgets/project_card.dart:22` |
| Staff route + back handling | `previewGallery` route: `FlowBackScope` + `navigateBack` | `lib/app/routes/app_router.dart` |
| Buttons | `AppButton.secondary(label:, icon:, isFullWidth:)` | design system |

`modelGenerationProvider` already does the hard part: it polls
`GET /admin/projects/:id/models` with backoff (3s → 20s, capped at 60 polls)
while any record `isPending`, stops when nothing is pending, keeps the last good
list on a transient failure, and auto-disposes with the screen. **Watch it; do
not write a second polling loop.**

---

## Non-negotiable contracts

1. **Staff-only, failing closed.** Gate on `UserRole.isStaff`, never on exact
   role equality. A failed role fetch must hide the button, not show it.
2. **The `Models` button follows the `onPreview` precedent exactly**: an optional
   nullable callback on `ProjectCard`, so the shared card stays byte-for-byte
   unchanged for regular users. The button renders only when non-null.
3. **A non-viewable row must not open the viewer.** `FAILED` records exist in
   production data today (real example: `MESHY_GENERATION_FAILED` — "Meshy could
   not generate a model from the selected photos"). Gate taps on `isViewable`,
   not on status alone — a `SUCCEEDED` record with a null `glbUrl` must also not
   be tappable.
4. **Never persist or display a Meshy URL.** Only our CloudFront URLs reach the
   client, and that is already true of the DTO — just don't reintroduce it.
5. **The entity is hand-synced with the backend** (no shared package). Any field
   added in C1 must mirror `ProjectModelDto` in
   `recapture-api/src/services/projectModelsService.ts` exactly.

---

## Tasks

### C1 — Extend `ProjectModelView` with `createdAt` + `error`

**This is a real gap, not a nicety.** The backend's `ProjectModelDto` returns
`createdAt` (ISO string) and `error: {code, message}`, but the Dart entity drops
both on the floor. Without them the history rows cannot be labelled or explain a
failure — C2 is impossible.

- Add `final DateTime? createdAt;` and a small `ModelError` (code + message), or
  a nullable `errorMessage` if you prefer flat.
- Parse in `tryFromStaffMap` only. **`tryFromOwnerMap` must not gain `error`** —
  the owner endpoint never returns failures, and adding it would invite leaking
  one later. `createdAt` in the owner shape is fine (it is in `OwnerModelDto`).
- Parse defensively, matching the file's existing style: a malformed timestamp
  yields `null`, never a throw. `DateTime.tryParse`.
- The backend messages are safe to display — `meshyClient` never interpolates a
  response body or a presigned URL into one (that is an explicit backend
  contract). Do not add your own scrubbing.

### C2 — Model history screen + route

New screen, e.g. `lib/presentation/screens/projects/model_history_screen.dart`,
plus route `/admin/projects/:id/models` (`AppRoutes.modelHistory` /
`AppRouteNames.modelHistory`), registered exactly like `previewGallery` —
`FlowBackScope`, `projectId` from `state.pathParameters['id'] ?? ''`, pushed not
`go()`-replaced.

Watch `modelGenerationProvider(projectId)`. Render newest-first (the backend
already sorts; do not re-sort). One row per attempt carrying:

```
Jul 17, 11:42 · SUCCEEDED · ✓ Approved      4 photos    →
Jul 17, 11:27 · SUCCEEDED                   3 photos    →
Jul 17, 10:02 · FAILED — Meshy could not generate…      (not tappable)
Jul 17, 09:58 · PROCESSING…                             (spinner, not tappable)
```

- **Label rows by timestamp, never by index.** "Model 2" tells an artist nothing
  and renumbers itself when a new generation lands at the head of the list.
- Show `selectedKeys.length` ("4 photos") — it is the main thing that differs
  between attempts and the reason one succeeded where another failed.
- Show the approved badge; `approved` is already parsed.
- `QUEUED`/`PROCESSING` rows show progress. The provider is already polling them
  — the row will update itself.
- `FAILED` rows show `error.message`.
- Use `previewUrl` as a row thumbnail when present (it is the Meshy preview we
  re-hosted). Nice-to-have; skip if it complicates the row.
- Empty state: "No models yet" + a pointer to the Preview gallery, since that is
  where a generation is started.

Approve can live here (`notifier.approve(modelId)`, already implemented and
already reflects locally without a re-fetch) or stay in the viewer — your call,
but do not duplicate it in both.

### C3 — `Models (N)` button on the project card

Add an optional `onModels` callback to `ProjectCard`, mirroring `onPreview`'s
doc comment and null-means-hidden semantics, rendered beside `Preview` via
`AppButton.secondary`.

**Do not add one button per model.** `Model 1 / Model 2 / Model 3…` grows
unbounded — a project regenerated eight times gets eight buttons crowding a card
whose height is currently fixed. One `Models (N)` button keeps the card stable
forever and gives the history room to show timestamp, status, photo count and
approval, which per-model buttons cannot.

Hide the button entirely when N is 0 — an empty history screen is a dead end.

**Decide and state where N comes from.** This is the one open question; do not
guess:
- The card list currently has no model counts, and fetching history per card
  would fire one request per project on the Projects screen — unacceptable.
- Cheapest correct option: show the button unconditionally for staff on an
  exportable project (same condition as `Preview`), label it plain `Models`, and
  let the history screen own the empty state.
- Better option, if a backend change is ever acceptable: add `modelCount` to the
  admin project list payload.

Prefer the cheapest option unless the reviewer says otherwise. `Models` without
a count is a fine v1; N per card is not worth N requests.

### C4 — Viewer route

Register `/admin/projects/:id/models/:modelId` (`AppRoutes.modelViewer`), the
missing door. `ModelViewerScreen` currently takes a `ProjectModelView` directly,
so either:
- pass it via `extra` when pushing from the history (simplest, keeps the screen
  unchanged), **and** handle `extra == null` on a cold deep-link by looking the
  model up from the provider — do not crash or show a blank viewer; or
- change the screen to take `projectId` + `modelId` and resolve from the
  provider itself (more robust, slightly more work).

Either is acceptable; state which you chose and why.

---

## Tests & verification

Follow the existing client conventions in `test/projects/`.

- Reuse the shared repo fakes: `test/projects/repo_fake_defaults.dart`.
- **`ModelViewerScreen` takes an injectable `renderBuilder`** because the real
  `ModelViewer` needs a WebView platform — inject a fake in widget tests.
- **Never `pumpAndSettle` on a screen with a pending generation** — the poll
  timer never settles and the test hangs. Pump explicit durations.
- Cover: history renders newest-first; a `FAILED` row is not tappable and shows
  its message; a pending row shows progress; `isViewable == false` never opens
  the viewer; the `Models` button is absent for a non-staff role (fails closed);
  tapping a viewable row routes to the viewer with the right model.

Manual: with `npm run dev` running (the worker now runs in-process via
`RUN_WORKER_IN_PROCESS=true` — there is no separate worker to start), open a
project with existing generations, confirm the history lists them, and confirm a
`SUCCEEDED` row opens the viewer with the "Created by Meshy AI" badge.

**Viewer caveat:** the real `ModelViewer` needs a WebView platform, so the GLB
may not render in the web build even once routing works. Verify on a real device
before concluding the viewer is broken.

---

## Definition of done

- [ ] `ProjectModelView` carries `createdAt` + `error`, parsed staff-side only,
      defensively, mirroring `ProjectModelDto`
- [ ] Model history screen + route, watching `modelGenerationProvider` (no second
      poll loop)
- [ ] Rows labelled by timestamp + status + photo count; approved badge; failure
      message; pending rows show progress
- [ ] Non-viewable rows are not tappable
- [ ] `Models` button on `ProjectCard` via a nullable callback, staff-only,
      failing closed; card unchanged for regular users
- [ ] Viewer route registered; cold deep-link handled
- [ ] Owner surface (`fetchModel` / `tryFromOwnerMap` / `GET /projects/:id`)
      untouched
- [ ] Widget tests per above; `flutter analyze` clean

---

## Open items to confirm while implementing (don't guess — verify)

1. **Where `N` comes from in `Models (N)`** — see C3. Defaulting to a countless
   `Models` button is the sanctioned answer; anything else needs a decision.
2. **Whether approve lives in the history rows or the viewer** — pick one, not
   both.
3. **Whether the viewer takes `extra` or resolves by id** — state the choice.

Related: [[project-meshy-model-generation]] (as-built + credit guards),
[[project-staff-preview-gallery]] (where generation starts),
[[project-p7a-live-projects-roles]] (role gating).
