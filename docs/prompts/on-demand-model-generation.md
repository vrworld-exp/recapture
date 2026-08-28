# Implementation prompt — On-demand "Auto-generate 3D model" button (with live step trace)

> Read [AGENTS.md](../../AGENTS.md) first. It is the source of truth for both
> codebases; where this prompt disagrees with a foundational convention,
> AGENTS.md wins.

## 1. What we are building

A per-project **"Generate 3D model"** button on both project lists (My projects
and Live projects). Pressing it runs the *existing* automatic-generation logic —
server picks 3–4 photos itself, hands them to Meshy, the finished GLB/USDZ lands
in the project's model section — but **triggered by a human instead of by the
capture pipeline finishing**.

Plus: while it runs, the user sees **the steps happening behind the call**, with
a plain-language timeline for owners and an expandable raw trace for staff/devs.

### Why this, and why now

The photo selector (`autoPhotoSelectionService.ts`) has only ever run against
**synthetic manifests**. Enabling the automatic post-capture trigger would make
its first real-world exercise an unattended, per-capture spend. This button is
the de-risked version of that same test: human-triggered, one at a time, on a
capture someone chose.

**This button should ship and be exercised BEFORE `AUTO_MODEL_GENERATION_ENABLED`
is ever turned on in production.** Treat that as a goal of the work, not a
side effect.

## 2. What already exists (do not rebuild any of it)

| Piece | Location | Note |
|---|---|---|
| Photo selection (pure, sync) | `recapture-api/src/services/autoPhotoSelectionService.ts` | `selectPhotosForAutoGeneration(manifest, opts)` → `SELECTED{keys, reason}` \| `DECLINED{reason}` |
| Decision + guards | `recapture-api/src/services/autoModelGenerationService.ts` | `maybeAutoGenerateModel()`, 4 guards, `autoGenerationIdempotencyKey()` |
| Enqueue + money contract | `recapture-api/src/services/projectModelsService.ts` | `createMeshyModelRequest()` — record-before-job, unique-index replay, `jobId` pinning |
| Meshy worker | `recapture-api/src/worker/processors/meshyModelProcessor.ts` | writes `record.progress = {phase, percent}` |
| Only current caller | `recapture-api/src/worker/processors/captureProcessingProcessor.ts` | the automatic trigger |
| Staff create route | `recapture-api/src/routes/admin.ts` → `POST /projects/:id/model` | manual key selection, rate-limited `meshy-create:{userId}` |
| Owner model state | `recapture-api/src/routes/projects.ts` → `GET /projects/:id` | returns `{project, model, generation}` |
| Owner polling | `lib/application/projects/owner_model_state_notifier.dart` | 3s→10s backoff, poll cap |
| Owner waiting screen | `lib/presentation/screens/projects/model_building_screen.dart` | already renders waiting / ready / failed |
| Cards | `lib/presentation/widgets/project_card.dart`, `_LiveProjectCard` in `live_projects_view.dart` | both already use the nullable-callback = hidden-button pattern |
| Step row widget | `lib/presentation/widgets/step_checklist_row.dart` | from the upload step tracker — **reuse this** |

**The pipeline is built. This work is a route, a trace, a button, and some
policy.** Resist the urge to write a second generation path.

## 3. Decisions already made

These were settled in design discussion. Do not re-open them without saying so.

1. **The manual gate is SEPARATE from the automatic gate.** Reusing
   `AUTO_MODEL_GENERATION_ENABLED` would make the button dead until that flag is
   flipped — and flipping it also enables unattended per-capture spend, which
   defeats the whole purpose. Two flags.
2. **Repeat presses are idempotent by default.** Second press returns the
   existing record instead of paying again. A separate, explicit **staff-only
   force-regenerate** mints a fresh idempotency key. Owners never get an
   unbounded loop.
3. **Manual generations count against the same 24h ceiling as automatic ones.**
   It is the same money. Staff get a higher ceiling, not an exemption.
4. **The trace is PERSISTED on the model record**, not response-only. The
   failure you most want explained is the one reported an hour later; a
   response-only trace is lost the moment the screen closes. It also lets the
   progress screen recover after an app restart.
5. **Phase 1 is staff/admin on both tabs; owners come after.** Owner-facing
   policy (regenerate rights, history visibility) is a separate decision. Build
   the owner plumbing so it is a gate flip, but ship it gated.

## 4. The step model — read this before writing any code

"The steps" are two different kinds of thing, and conflating them is the main way
this feature goes wrong.

### 4a. Steps 1–5 happen INSIDE the HTTP request, in well under a second

```
RESOLVE_JOB     → newest exportable capture job for the project
LOAD_MANIFEST   → fetch + parse capture_manifest.json from S3
LIST_OBJECTS    → relative keys actually present under the job prefix
SELECT_PHOTOS   → the selector: quadrant spread, blur floor, backfill
GUARDS          → kill switch, per-job dedupe, 24h cap
ENQUEUE         → ProjectModel record + MESHY_MODEL_GENERATION job
```

There is nothing to *watch* here — it is over before the button's spinner paints.
**Do not build streaming, SSE, or websockets for this.** The POST returns a
completed trace, and the UI renders it as an already-ticked checklist.

This is the part devs actually care about: *which 4 photos, from which quadrants,
at what blur scores, and why those over the others.*

### 4b. Steps 6–9 take minutes, in the worker

Presign source URLs → Meshy submit → Meshy preview/texture polling → download
GLB/USDZ into our S3 → mark `SUCCEEDED`.

This is **already** reported via `record.progress = {phase, percent}` and already
polled by `OwnerModelStateNotifier`. Extend the rendering; do not add a second
transport.

**Net rule: trace in the response, polling for the slow half.**

## 5. Backend work

### 5.1 Enrich the selector with a structured trace

In `autoPhotoSelectionService.ts`, **add** to both result variants (do not change
or remove the existing `keys` / `reason` fields — `maybeAutoGenerateModel` and
367 backend tests depend on them):

```ts
export interface AutoSelectionTrace {
  ringUsed: 'EYE' | 'ALL';        // which pool the EYE-preference rule chose
  photosInManifest: number;
  poolSize: number;
  droppedUnresolvableKey: number; // imagePath that toRelativeImageKey refused
  droppedMissingObject: number;   // not in availableKeys
  droppedNoBlurScore: number;     // ← expected to be LARGE on pre-2026-07-21 captures
  belowBlurFloor: number;
  warnedExcluded: number;
  minBlurScoreUsed: number;
  segmentCountUsed: number | null; // null = fell back to absolute yaw
  quadrantHistogram: [number, number, number, number];
  unplacedCount: number;
  chosen: Array<{ key: string; blurScore: number; quadrant: number | null }>;
}
```

Attach it as an optional `trace?: AutoSelectionTrace` on **both** `SELECTED` and
`DECLINED`. A decline with no trace is useless — populate it as far as the
function got before refusing.

Keep the function **pure and synchronous**. That property is the reason it can be
iterated against real manifests with no infrastructure, and it must survive.

### 5.2 New service: `onDemandModelGenerationService.ts`

```ts
export type GenerationStepName =
  | 'RESOLVE_JOB' | 'LOAD_MANIFEST' | 'LIST_OBJECTS'
  | 'SELECT_PHOTOS' | 'GUARDS' | 'ENQUEUE';

export interface GenerationStep {
  step: GenerationStepName;
  status: 'OK' | 'SKIPPED' | 'FAILED';
  /** Staff-safe one-liner. MAY contain keys/counts. Never a presigned URL. */
  detail?: string;
  at: string;          // ISO
  durationMs: number;
}

export type OnDemandResult =
  | { outcome: 'ENQUEUED';  modelId: string; steps: GenerationStep[]; trace: AutoSelectionTrace }
  | { outcome: 'REPLAYED';  modelId: string; steps: GenerationStep[] }
  | { outcome: 'DECLINED';  reason: AutoSelectionDeclineReason; steps: GenerationStep[]; trace: AutoSelectionTrace }
  | { outcome: 'BLOCKED';   reason: 'DISABLED' | 'USER_CAP_REACHED' | 'NOT_EXPORTABLE' | 'PROJECT_NOT_FOUND'; steps: GenerationStep[] };
```

`generateModelOnDemand({ projectId, actor, force? })`:

1. **Gate** — `env.MANUAL_MODEL_GENERATION_ENABLED` (new, see 5.4) **and** the
   remote kill switch `manualModelGenerationEnabled`. Same fail-closed-on-store-error
   semantics as `isRemotelyEnabled()` in `autoModelGenerationService.ts` — copy
   that reasoning, do not invent new semantics.
2. **Resolve job** — `findExportableJob(projectId)` (newest). Not exportable →
   `BLOCKED{NOT_EXPORTABLE}`.
3. **Load manifest + list objects** — reuse whatever `captureProcessingProcessor.ts`
   already uses. **HAZARD: `availableKeys` must be RELATIVE to `job.upload.rawPrefix`.**
   This was a live-readiness bug (fix B2) once already; passing absolute keys makes
   the selector drop every photo and decline 100%.
4. **Select** — `selectPhotosForAutoGeneration(manifest, { minBlurScore, availableKeys })`.
5. **Cap check** — count `ProjectModel` docs for this user in the last 24h where
   `createdBySystem === true` **OR** `createdByManualButton === true`. Staff
   (`MODEL_ARTIST`/`ADMIN`) use `env.MANUAL_MODEL_MAX_PER_STAFF_PER_DAY`.
6. **Enqueue** — `createMeshyModelRequest({ projectId, jobId: job._id, keys,
   actor, idempotencyKey, createdBySystem: false })`.
   - **`jobId` MUST be passed.** Omitting it re-resolves the project's newest
     exportable job, so keys selected from job A get presigned under job B's
     prefix if a recapture finalizes mid-flight. This was live-readiness bug B4.
   - Idempotency key: `manual:{jobId}` normally; `manual:{jobId}:{randomUUID()}`
     when `force` (staff only). Add a `manualGeneration: true` marker field so
     the cap query and analytics can distinguish these from automatic ones.
7. Persist the steps + trace on the record (5.3) and return.

**Never throw for a business reason.** Mirror `maybeAutoGenerateModel`: every
refusal is a typed outcome. An infrastructure failure (S3 down) is a `FAILED`
step plus a thrown error the route maps to 502.

### 5.3 Persist the trace

Add to `ProjectModel` (`recapture-api/src/models/ProjectModel.ts`):

```ts
generationTrace?: {
  steps: GenerationStep[];
  selection?: AutoSelectionTrace;
  requestedBy: 'AUTO' | 'MANUAL';
};
```

All optional — every existing record predates it, and clients must treat it as
absent-by-default.

**Also write it from the automatic path** (`maybeAutoGenerateModel`), with
`requestedBy: 'AUTO'`. Same debugging value, and it stops the two paths drifting.

Exposure rules:
- `ProjectModelDto` (staff) — include `generationTrace` verbatim.
- `OwnerModelDto` / `OwnerGenerationDto` — **never** include it. Owners get at
  most a coarse `currentStepLabel: string` of mapped copy. Read the doc comment
  on `OwnerModelDto`: an owner must not learn our key layout, our phase names, or
  that Meshy exists.

### 5.4 Env + remote config

`recapture-api/src/config/env.ts` (and `.env.example`):

```
MANUAL_MODEL_GENERATION_ENABLED     boolean, default false
MANUAL_MODEL_MAX_PER_USER_PER_DAY   int, default 5
MANUAL_MODEL_MAX_PER_STAFF_PER_DAY  int, default 25
```

Remote kill switch key `manualModelGenerationEnabled`, read via `getServerFlag`.
**Deliberately NOT in `remoteConfigSchema`** — same reasoning as
`autoModelGenerationEnabled`: it is a server-side operational switch, not client
config, and must not leak to the public `/remote-config` endpoint. Unset means
enabled (the env flag is already the explicit opt-in).

### 5.5 Routes

**Staff** — new, in `routes/admin.ts` (inherits the router-level
`requireRole('MODEL_ARTIST')`):

```
POST /admin/projects/:id/model/auto
body: { force?: boolean }
→ 201 { status:'success', model, steps, trace }        // ENQUEUED
→ 200 { status:'success', model, steps }               // REPLAYED
→ 422 { status:'error', code:'NOT_SELECTABLE', reason, steps, trace }
→ 409 { status:'error', code:'USER_CAP_REACHED'|'DISABLED', steps }
```

Do **not** modify the existing `POST /admin/projects/:id/model`. Its
explicit-keys contract is used by Prepare-Images and is covered by tests; a mode
flag on it would couple two independent flows.

Reuse the existing rate-limit bucket `meshy-create:{userId}` so the manual button
and Prepare-Images share one ceiling.

**Owner** — new, in `routes/projects.ts` (inherits `requireAuth`, must verify
project ownership exactly as the other owner routes do):

```
POST /projects/:id/model
body: {}
→ 202 { status:'success', generation }   // OwnerGenerationDto, owner-safe only
→ 422/409 with mapped owner-safe copy, NO trace, NO steps detail
```

Ship this behind the same env flag but leave the client entry point off in
phase 1 (decision 5, §3).

Standard envelope throughout. Routes map typed results to HTTP; no business logic
in the route (AGENTS.md layering: routes → services → models).

### 5.6 Analytics

Follow the existing `track()` pattern in `admin.ts` — hashed ids only
(`hashIdentifier`), never a raw key or URL:

```
model_generation_requested  { source: 'manual_button', actor_role, project_id_hash, forced }
model_generation_declined   { reason, pool_size, dropped_no_blur, quadrants_filled }
```

The second one is the payload that tells you how to tune the thresholds after a
week of real presses. Do not skip it.

## 6. Client work

### 6.1 Data layer

- `lib/data/remote/api_client.dart` — `postAutoGenerateModel(projectId, {force})`
  hitting the admin route (phase 1) and returning the parsed steps + trace.
- New entities in `lib/domain/entities/` — `GenerationStep`, `GenerationTrace`.
  Every field nullable/defaulted: old records have no trace.
- `lib/data/repositories/projects_repository.dart` — repository method.
  **HAZARD: adding a repository member breaks every fake.** Update
  `test/projects/repo_fake_defaults.dart` (and the `FakeModelImageUploadDefaults`
  mixin pattern) in the same commit or the suite goes red everywhere.

### 6.2 State

New `ModelGenerationRequestNotifier` (or extend `ModelGenerationNotifier`):
`idle → requesting → enqueued(steps, trace) → then hand off to
ownerModelStateProvider for the polling half`.

The screen shows *request steps* from the POST result and *worker progress* from
the existing poll. One screen, two sources — keep them visibly separate in the
state class so nobody later tries to unify them.

### 6.3 The button

`ProjectCard` — add `final ValueChanged<Project>? onGenerate;` following the
**exact** `onPreview`/`onModels` convention: null means the button is not
rendered, so the card is byte-for-byte unchanged for users who shouldn't see it.
Add it to the `trailing` list in `_buildActionArea`.

`_LiveProjectCard` in `live_projects_view.dart` — same, with `VoidCallback?`.

Render conditions in `projects_screen.dart`:
- `isStaff` (phase 1), **and**
- `_isExportable(project)` — the existing predicate at
  [projects_screen.dart:252](../../lib/presentation/screens/projects/projects_screen.dart#L252).
  A non-exportable project has no finalized capture and the call would always
  `BLOCKED{NOT_EXPORTABLE}`; a button that always errors is worse than no button.

Four buttons on one card row is crowded. Check the layout at narrow widths — if
it breaks, collapse `Preview`/`Models`/`Generate` into the existing overflow
sheet rather than shrinking the labels.

### 6.4 The step UI

Extend `ModelBuildingScreen` rather than creating a new screen — it already owns
the waiting/ready/failed states, the "you can leave this screen" copy, and the
auto-generated badge.

**Owner-facing timeline** (5 rows, reuse `step_checklist_row.dart`):

```
✓ Choosing your best photos
✓ Sending them to the 3D engine
◐ Building the model — 62%
○ Adding textures
○ Finishing up
```

**Staff/dev detail** — a collapsed `ExpansionTile` below it, **double-gated** on
`isStaffProvider` && `kDebugMode`, matching the `devDetail` precedent from the
upload step tracker. Shows the raw `steps[]` with durations, the full
`AutoSelectionTrace`, the chosen keys with blur scores and quadrants, the Meshy
phase name, and the poll count.

Three things that make this look broken if you skip them:

1. **Progress is not monotonic.** The `progress` writes are best-effort and
   fenced; a percent can stall or arrive out of order. **Clamp so the bar never
   moves backwards**, and show a "still working…" affordance when the number
   stops changing — a stalled Meshy job otherwise reads as a frozen app.
2. **The poll cap is finite** (3s→10s backoff, `_maxPolls` in
   `owner_model_state_notifier.dart`). Decide and implement what the screen says
   when it runs out. It must not spin forever.
3. **The decline path is the most valuable screen here, not the happy path.**
   Given the selector has never seen a real manifest, `NOT_SELECTABLE` is a
   *likely* first-week outcome. Owner sees mapped copy; staff sees exactly which
   rule refused and with what numbers.

### 6.5 Refreshing the model section

On success, the "model section" entry point does **not** light up on its own:
`modelCount` is aggregated into the projects **list** DTO server-side, so
`hasViewableModels` (and therefore the Models button) is stale until the list is
re-fetched. Invalidate `projectsProvider` / the live-projects notifier when a
generation reaches `SUCCEEDED`.

## 7. Hazards — read before testing

- **Captures older than 2026-07-21 will decline 100%.** The bundle packer only
  started threading `blurScore`/`yaw` into the manifest as of live-readiness fix
  B1. The selector requires `quality.blurScore` and drops any photo without it.
  **Test only with freshly captured projects**, or you will conclude the selector
  is broken when it is the data. `droppedNoBlurScore` in the trace is exactly the
  diagnostic for this.
- **`availableKeys` must be relative to `rawPrefix`** (fix B2). Absolute keys →
  everything dropped → `NO_USABLE_PHOTOS`.
- **`jobId` must be pinned** on `createMeshyModelRequest` (fix B4).
- **Two manifest producers write different `imagePath` shapes** —
  `capture_bundle_packer.dart` (bundle-relative) vs
  `capture_manifest_assembler.dart` (device path). `toRelativeImageKey` already
  handles both; don't "simplify" it to a slice.
- **Ring size comes from `manifest.config.segmentCounts`, never inferred** from
  the photos present. Inferring maps a narrow arc onto opposite sides of the
  circle — precisely what `INSUFFICIENT_SPREAD` exists to refuse.
- **Any widget test pumping a screen that reads `isStaffProvider` must override
  it** or Hive throws. Same for `LiveProjectsView` and `isAdminProvider`.

## 8. Tests

**Backend** (Vitest + Supertest + mongodb-memory-server; `npm test` in
`recapture-api/`, currently 367 green):

- Selector trace: populated on SELECTED **and** on each DECLINED reason.
- `generateModelOnDemand`: each `BLOCKED` reason; declined path spends nothing
  (assert no `Job` created); enqueued path pins the correct `jobId`.
- Idempotency: two presses → one `ProjectModel`, second is `REPLAYED`; `force`
  → a second record.
- Cap: manual + automatic generations count against one ceiling; staff ceiling
  is the staff one.
- Kill switch: env off and remote-flag off each block, independently of
  `AUTO_MODEL_GENERATION_ENABLED`.
- Routes: 403 for a non-staff caller on the admin route; owner route rejects a
  project the caller doesn't own; **trace never appears in an owner response**
  (assert on the serialized body, not the DTO type).
- **Use the committed real packer-generated manifest fixture**, not a
  hand-written one. It exists specifically to stop fixture drift.

**Client** (`flutter test`, currently 2131 green):

- Button renders only when staff && exportable; absent otherwise on both cards.
- Tap → repository called once (double-tap guarded via the existing
  `_actionInFlight` claim).
- Steps render from a canned response; dev detail hidden when not staff.
- Progress never moves backwards when the poll returns a smaller percent.
- Decline → owner copy shown, no code/key/URL leaked into the widget tree.

## 9. Non-goals

- Do **not** enable `AUTO_MODEL_GENERATION_ENABLED`.
- Do **not** change the capture pipeline, finalize, or the in-house
  reconstruction path.
- Do **not** modify the existing explicit-keys `POST /admin/projects/:id/model`.
- Do **not** widen Prepare-Images to owners (still an open product decision, see
  the TODO at `projects_screen.dart` `_regenerateHandlerFor`).
- Do **not** build streaming/SSE for the synchronous steps.

## 10. Suggested order

1. Selector trace + tests (pure, no infrastructure — fastest feedback).
2. `onDemandModelGenerationService` + persistence + tests.
3. Routes + tests.
4. **Verify against one real, freshly-captured project** before touching the
   client. The trace's real shape determines what the UI can render; building the
   UI first means guessing at it.
5. Client data layer + fakes.
6. Button on both cards.
7. Step UI + dev detail.
8. Full suite both sides, then update `MEMORY.md` / the auto-model-generation
   memory entry with what the first real traces showed.
