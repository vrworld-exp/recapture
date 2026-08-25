
✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅

# Task: Screen 9 → Live Upload Step Tracker (smoke-card-style UI over the REAL pipeline)

> Flutter client only (repo root). No backend changes. The reference look is
> the Dev Tools "S3 Upload Smoke Test" card on the Projects Hub
> (`lib/dev/dev_probe/`): a vertical step checklist with ✓/spinner/✗ icons,
> expandable per-step detail, a live progress bar, and a footer summary line
> (`✓ 37/37 files · 176.9 KB · 66.9s`). This task rebuilds **Screen 9
> (Uploading)** in that style, driven by the REAL upload pipeline — so every
> stage and file of a real post-capture upload is trackable on-screen.

Read **AGENTS.md** at the repo root first (PII/logging rules, analytics seam,
testing conventions). Its conventions win over anything here.

---

## 1. Goal & grounding (read before coding)

**Goal:** after the user taps Upload on the Capture Summary (Screen 8), the
Uploading screen shows a live step timeline of the real flow:

```
● Prepare bundle          ✓  (37 files · 176.9 KB)
● Create project          ✓  (remote id minted)
● Create job              ✓  (job registered)
● Upload files 21/37      ⟳  [██████████░░░░░]  4.2 / 7.4 MB
● Finalize                ○  (waiting)
─────────────────────────────────────────────
Pause · Cancel                    (controls unchanged)
```

Grounding facts (verified in the codebase — the design below depends on them):

- **The real flow already exists and is wired.** `UploadFlowNotifier.start()`
  (`lib/application/upload/upload_flow.dart`) is called from the Summary CTA
  and 9F Retry. Its `UploadFlowOrchestrator.run()` executes:
  pack → (warmup in parallel) → `POST /projects` → `POST /jobs` → engine
  (`ChunkedUploadManager` + `ResilientUploadRunner`: per-file presigned
  multipart initiate → part PUTs to S3 → complete) → `POST /jobs/:id/finalize`
  → `QUEUED`.
- **Screen 9 is a PURE OBSERVER** (`uploading_screen.dart`): it consumes
  `uploadProgressProvider` (bytes/files/status) and `uploadControllerProvider`
  (pause/resume/cancel) and performs no upload logic. KEEP that contract —
  the step tracker is one more observed stream, not logic in the widget.
- **Terminal truth rules (do not break):** `UploadFlowProgress` HOLDS the
  engine's `completed` until finalize returns `QUEUED` (only then does Screen
  9 see `completed` and advance to Processing), and SWALLOWS per-attempt
  `failed` snapshots while the runner may still auto-retry. The step tracker
  must obey the same rules: the transfer step shows "retrying" at most — it
  flips to failed only on the runner's TERMINAL outcome.
- **Failure navigation stays:** a terminal failure surfaces as a stream error
  → `classifyUploadFailure` → Screen 9F with the mapped category. The step
  tracker paints the failing step red before navigation, but 9F remains the
  terminal failure surface (Retry/Back + analytics live there).
- **A retry is a NEW orchestrator** (`start()` replaces a terminal flow), so
  the timeline resets naturally with the new flow instance.
- The flow is instrumented for the dev log (`DevUploadLog`, added 2026-07-12)
  at exactly the points the timeline needs — the emission points in §3 mirror
  them. Keep `DevUploadLog` calls; the timeline is typed state, not strings.
- Flavor gate for anything raw: `kAppEnvironment.isProduction`
  (`lib/utils/app_env.dart`) — same gate as the Dev Tools section and the OTP
  dev chip. The step LIST ships to production (it's good UX); raw detail
  lines (exceptions, ids, key prefixes) render only in non-prod flavors.

---

## 2. The upload flow, step by step (what the timeline tracks)

| # | Step id        | Code point (upload_flow.dart)                   | Friendly label      | Detail (prod-safe)            | Dev-only detail                      |
|---|----------------|--------------------------------------------------|---------------------|-------------------------------|--------------------------------------|
| 1 | `prepare`      | `markRunning()` → `_pack(...)` returns           | "Preparing photos"  | "N files · X MB"              | bundle path, per-ring counts         |
| 2 | `createProject`| `backend.createProject(...)`                     | "Creating project"  | —                             | remoteProjectId                      |
| 3 | `createJob`    | `backend.createJob(...)`                         | "Registering upload"| —                             | jobId, keyPrefix, expectedFilesCount |
| 4 | `transfer`     | `engine.run(spec)` (progress via existing stream)| "Uploading files"   | "n/N files · a / b MB" (live) | attempt #, category on retry         |
| 5 | `finalize`     | `_finalize(...)`                                 | "Verifying upload"  | —                             | returned state                       |

Warmup is NOT a step (best-effort, never fails the flow) — at most a dev-only
detail line on `prepare`. Context resolution failures surface as a `prepare`
failure.

---

## 3. Domain + state (new, pure Dart)

`lib/domain/upload/upload_flow_steps.dart`:

- `enum UploadFlowStepId { prepare, createProject, createJob, transfer, finalize }`
- `enum UploadStepStatus { pending, running, done, failed, cancelled }`
- `class UploadFlowStepState` — immutable: `id`, `status`, `startedAt?`,
  `endedAt?`, `info?` (prod-safe string), `devDetail?` (raw, list of strings).
- `class UploadFlowTimeline` — immutable list of the five steps in order +
  `copyWith`-style transition helpers: `start(id)`, `complete(id, {info})`,
  `fail(id, {devDetail})`, `cancelRemaining()`. Invariants: steps run in
  order; starting a step completes nothing implicitly; a `fail`/`cancel` is
  terminal for the whole timeline.

Unit-test the transitions exhaustively (pure, no Flutter).

## 4. Emission (upload_flow.dart)

- `UploadFlowProgress` gains a
  `ValueListenable<UploadFlowTimeline>`/`StreamController`-backed `timeline`
  surface (pick ONE mechanism; a broadcast stream with replay-current matches
  the existing `watch()` idiom).
- The orchestrator transitions the timeline at the SAME points it already
  calls `DevUploadLog` (flow start, pack done, createProject, createJob,
  engine outcome, finalize state, catch blocks). The transfer step's live
  counters do NOT go through the timeline — the screen composes them from
  the existing `uploadProgressProvider` stream (single source of truth for
  bytes/files; no duplicated math).
- Terminal mapping: engine `failed` → `fail(transfer)`; finalize non-QUEUED
  or throw → `fail(finalize)`; `_FlowCancelled`/cancel → `cancelRemaining()`;
  pre-engine throws → fail whichever step was `running`.

## 5. Provider seam

`uploadStepTimelineProvider` (in `upload_progress_provider.dart`, next to the
existing seams): watches `uploadFlowProvider`; when a flow exists, exposes its
timeline stream; when idle, an all-`pending` timeline. Screen 9 stays a
consumer — no new logic in the widget beyond rendering.

## 6. UI (uploading_screen.dart rebuild)

- Keep: entry/terminal analytics, `CaptureCancelFlow` mixin, navigation on
  completed → Processing / failure → 9F / cancel semantics, `UploadControls`.
- Replace the bare progress column with a card matching the smoke-card look
  (`dev_tools_section.dart` is the visual reference; reuse its row/spacing
  patterns but do NOT import from `lib/dev/` into production UI — copy the
  small row widget into `lib/presentation/widgets/` as a shared
  `StepChecklistRow` and refactor the dev card to use it only if trivial).
- Per step row: leading icon (pending ○ muted / running spinner / done ✓
  success-green / failed ✗ `AppColors.error` / cancelled — muted), friendly
  label, trailing chevron when detail exists; expanding shows `info` plus
  (non-prod only) `devDetail` in monospace.
- `transfer` row: live "n/N files" in the label + the existing determinate
  progress bar and MB counter directly beneath it (bound to
  `uploadProgressProvider` exactly as today — no simulated progress).
- Paused state (user pause or offline auto-park): transfer row shows a
  paused badge; controls unchanged.
- Success footer line before navigation: `✓ N/N files · SIZE · DURATIONs`
  (duration from the timeline's first `startedAt`).
- Widget keys for tests: `upload_step_<id>`, `upload_step_detail_<id>`.

## 7. Privacy / production rules (unchanged in spirit)

- Prod builds: friendly labels + counts/sizes only. No exception text, no
  ids, no key prefixes, no paths (all of those are `devDetail`, rendered only
  when `!kAppEnvironment.isProduction`).
- 9F keeps its "no raw error text rendered" contract and its mapped-category
  copy. The existing 9F test pins this — it must stay green.
- No new analytics events; the existing lifecycle events must not double-fire.

## 8. Tests

1. `upload_flow_steps_test.dart` — pure transition/invariant tests.
2. Extend `upload_flow_test.dart` (scripted fakes already exist): assert the
   timeline sequence for happy path, engine terminal failure, finalize
   non-QUEUED, cancel mid-transfer, pre-engine throw.
3. `uploading_screen` widget tests: seeded timeline+progress → correct row
   states/keys; transfer counters live-update; failed step renders red before
   the 9F navigation; prod-flavor devDetail absence is compile-time (not
   testable — note it, don't fake it).
4. Full `flutter analyze` + existing upload suites stay green.

## 9. Acceptance

- Real device upload shows each step flipping ✓ in order, live n/N + MB on
  transfer, and the footer summary on success — then advances to Processing.
- A forced failure (airplane mode mid-transfer) shows the transfer step
  parked/paused; a terminal failure paints the step red and lands on 9F with
  the same mapped category as before.
- Retry from 9F restarts with a fresh timeline.
- `flutter analyze` clean; all upload tests green.
