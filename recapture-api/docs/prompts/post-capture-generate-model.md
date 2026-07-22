# Post-capture "Generate 3D model" — wire the owner entry point

## Goal

After a capture finishes and its photos land in S3, the owner sees a screen that
says the upload succeeded and offers one button: **Generate 3D model**. Tapping
it runs the existing server-side pipeline (server picks the photos → Meshy →
GLB/USDZ re-hosted to our CloudFront) and takes the user to the existing build
screen, which polls until the model is ready and then opens the viewer.

This is a **wiring task, not a new pipeline.** Almost everything exists. The job
is to connect the capture/upload flow to it and to replace one stub screen.

## Current state — verify each of these before changing anything

1. **Backend owner route already exists and is unwired by design.**
   `POST /projects/:id/model` in `recapture-api/src/routes/projects.ts:227`.
   It proves ownership via `getProject(userId, id)` (missing / not-owned /
   soft-deleted → one identical 404), consumes the `meshy-create:{userId}` rate
   window, and calls `generateModelOnDemand({ projectId, actor:{ userId, role:'USER' } })`.
   Owners never get `force`. Its comment literally says "Phase 1 ships with no
   client entry point pointing here" — **you are that entry point.** Do not
   rebuild it; do not point the client at the staff route
   `POST /admin/projects/:id/model/auto` (owners get 403 there).
2. **The owner response is deliberately stripped**: no `steps`, no selector
   `trace`, no key names, no phase vocabulary, no hint that Meshy exists. The
   staff Dart type `AutoGenerationRequest`
   (`lib/data/repositories/live_projects_repository.dart:191`) carries counters
   the owner payload does not have. Read the route's actual success and 422
   bodies and model the owner type on **those**, not on the staff type.
3. **A decline is a RESULT, not an exception** — on both sides. The 422
   `NOT_SELECTABLE` path must come back as a normal value the UI renders as one
   plain sentence. Throwing discards the outcome.
4. **`lib/presentation/screens/capture/processing_screen.dart` is a stub.** It
   has a hardcoded 5-stage stepper with `_currentStageIndex = 2`, a
   `Timer(4 seconds)` that force-navigates to `AppRoutes.modelReady`, a
   non-functional "Notify me when done" switch, and no project id. It is the
   screen `uploading_screen.dart:125` sends the user to on upload success
   (`context.go(AppRoutes.processing)`). This screen is what you replace.
5. **`ModelBuildingScreen`** (`lib/presentation/screens/projects/model_building_screen.dart`)
   already exists and already handles the owner case: it names the wait, gives a
   duration, says leaving is safe, renders a 5-row timeline mapping ONE percent
   across bands, clamps progress monotonic, and surfaces a poll cap as "we've
   stopped checking" rather than an eternal spinner. Reuse it. Do not write a
   second build screen.
6. **`OwnerModelStateNotifier`** (`lib/application/projects/owner_model_state_notifier.dart`)
   already polls `GET /projects/:id` and keeps "finished model" and "in-flight
   run" as two independent facts. Reuse it. It exists precisely because
   `ModelGenerationNotifier` polls a staff route owners get 403 on.

## Scope

### Backend
Expected to be **zero or near-zero change**. If you find yourself editing
`onDemandModelGenerationService.ts`, `autoPhotoSelectionService.ts`, or the
Meshy processor, stop and re-read — you are probably solving a client problem in
the wrong codebase. The one legitimate backend question to answer with evidence:
does `GET /projects/:id` give the owner enough to decide whether the button
should be offered at all (a finalized capture job exists, no model yet, no
generation in flight)? If it does not, add the minimum field to the owner DTO —
and only that.

### Client
1. **Plumb the project id into the post-upload screen.** `UploadingScreen` has
   no `projectId`; `upload_flow.dart` resolves one (see `projectId` around
   `upload_flow.dart:784`, falling back to `ActiveSessionBox()`). Carry the
   real remote project id through to the post-upload route rather than
   re-deriving it in the screen. If the id genuinely cannot be resolved, the
   screen must degrade to "Back to Projects" with **no** button — never a
   button that 404s.
2. **Replace `ProcessingScreen`.** Delete the fake timer, the fake stage index,
   and the auto-navigation to `modelReady`. New content:
   - a confirmed success state for the upload ("Photos uploaded"),
   - the primary CTA **Generate 3D model**,
   - a secondary "Back to Projects" (leaving must stay safe and must not cancel
     anything),
   - the "Notify me when done" switch either made real or removed — a dead
     toggle is worse than no toggle. Removing it is acceptable; say which you
     chose and why.
3. **Owner repository member.** Add the `POST /projects/:id/model` call to
   `ProjectsRepository` (the OWNER surface). Note the staff equivalent lives on
   `LiveProjectsRepository` because that is the `/admin` surface — this one does
   not belong there. Add fakes via a mixin in
   `test/projects/repo_fake_defaults.dart`, not by editing every fake.
4. **Tap → navigate.** Follow the pattern already established at
   `projects_screen.dart:228` (`_onGenerate`): push the build screen FIRST and
   let the request settle there, because the most valuable outcome is a refusal
   and a snackbar cannot render a refusal properly. Owners see a plain sentence,
   not the staff trace. Guard against a double tap starting a second **paid**
   generation.
5. **Idempotency.** The server's key is `manual:{jobId}`, so a repeat request
   for the same capture job replays instead of paying twice. Make sure the
   client cannot defeat that (no `force`, no cache-busting param).

## Non-goals

- No owner **Regenerate** path. That is an open product decision (TODO at
  `projects_screen.dart:207`) and Prepare-Images is a staff surface.
- No change to auto-generation. `AUTO_MODEL_GENERATION_ENABLED` stays as it is;
  this button is on `MANUAL_MODEL_GENERATION_ENABLED`, deliberately separate.
- No new staff surfaces, no changes to the explicit-keys
  `POST /admin/projects/:id/model`.

## Hazards (each of these has already cost real time)

- **Every generation costs credits.** The four guards — Idempotency-Key,
  `meshyTaskId` persisted the instant it exists, per-user rate window, and
  terminal error routing via `NonRetryableJobError` — are load-bearing. Do not
  weaken one without a replacement.
- **The 24h ceiling is shared** between the auto and manual triggers via
  `countServerSelectedGenerationsInLast24h`. Do not add a third counting path.
- **`ModelBuildingScreen` reads `isStaffProvider`** for its dev trace. Any test
  that pumps it MUST override that provider or Hive throws — and the symptom
  only appears when files run together, passing in isolation.
- **Inside `testWidgets` the clock is fake**: a `Future.delayed` in a repo fake
  that nothing pumps hangs the run forever. Gate with a `Completer`.
- **Dispose the `ProviderContainer` inside the test body**, not only in
  `addTearDown`, or the owner poll timer trips "a Timer is still pending".
- Null progress renders as an indeterminate bar, never `0%` — 0% reads as stuck.
- Never surface a raw error string, a key name, or a Meshy URL to an owner.

## Definition of done

- `POST /projects/:id/model` is reachable from the app by a plain owner, end to
  end, with no staff role involved.
- Upload success → success screen → tap → build screen → viewer works as one
  continuous flow, and backing out at any point leaves nothing broken.
- A decline renders as one plain sentence with no internals leaked; a rate limit
  and a 404 each render their own mapped copy.
- Double-tap and re-entry cannot start a second paid generation.
- The fake stepper, the 4s timer, and the auto-nav to `modelReady` are gone.
- Flutter suite green (currently ~2140 tests), backend suite green (~396) — and
  state the new counts. New tests cover: happy path, decline-as-result,
  missing-project-id degradation, and double-tap.
- Report anything you could NOT verify without a live run. Note that this
  feature has **never been run live** — the selector has only ever seen
  synthetic manifests — so a green suite is not evidence the flow works.

## First step

Before writing code, read the owner route's success and 422 response bodies and
the `OwnerModelDto` shape, and state in your own words what an owner can and
cannot learn from them. The entire client design follows from that.
