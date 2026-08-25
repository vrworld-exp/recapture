
✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅

# Task: Conditional Bottom Ring — Capture Flow Variants (Flutter client)

> **Run this prompt first.** A separate follow-up task
> (`docs/prompts/capture-flow-variant-api.md`) updates `recapture-api/` so the
> server accepts 2-level uploads. Do NOT touch `recapture-api/` in this task.

Read **AGENTS.md** at the repo root first. Its conventions win over anything
here that contradicts them. Work only in the Flutter client (repo root `lib/`,
`test/`).

---

## 1. Product requirement (what is changing)

Today the guided capture flow is a fixed three-level sequence:
Level A (Eye Ring, band `mid`) → Level B (Top Ring, band `high`) → Level C
(Bottom Ring, band `low`), with segment counts coming from
`CaptureConfig.pitchBands` (bundled: mid=10, high=8, low=12).

**New flow.** On the Pre-Capture Checklist (Screen 4,
`lib/presentation/screens/capture/pre_capture_screen.dart`) the user answers
one new question before starting capture:

> **"Can you capture the bottom of the object?"** (i.e. can the object be
> tilted/lifted so its underside is photographable)

- **Yes → 3-level flow ("with bottom"):** A → B → C, **12 segments per level**
  (12-12-12, 36 total).
- **No → 2-level flow ("without bottom"):** A → B only, **18 segments per
  level** (18-18, 36 total). Level C never appears: no C intro, no C capture,
  no C row on the summary, no C requirement in any gate.

The answer is a per-capture-session choice, persisted with the session, and
**locked once the session has at least one accepted photo** (changing it then
requires Start Over).

---

## 2. Architecture you must build on (do not reinvent)

The codebase is already almost variant-ready. The flow shape comes from one
taxonomy + one band map + config-driven counts:

- `CaptureLevel { a, b, c }` enum + `pitchBandIdForLevel` (a→`mid`, b→`high`,
  c→`low`) in `lib/application/capture/analytics/capture_level_events.dart`.
- Ordered level list built in
  `lib/application/capture/progression/level_progression_builder.dart`
  (`levelStatesFromConfig`, `initialProgressionFromConfig`,
  `reconcileWithConfig`) — all iterate `CaptureLevel.values`.
- Per-level machines built in
  `lib/application/capture/progression/level_segment_machines.dart`
  (`levelSegmentMachinesFromConfig`, `levelSegmentMachineFor`) — same
  iteration, counts from `PitchBand.segments`.
- The pure progression core (`level_progression.dart`) already supports any
  level list length (`isLastLevel`, `overallComplete`, `firstIncompleteIndex`)
  — **it needs no changes**; only the lists fed into it change.
- Config: `lib/domain/entities/capture_config.dart` (bundled defaults,
  never-throw `fromMap`, `sanitizeCaptureConfig` +
  `capture_config_validator.dart`, served through
  `lib/application/config/config_notifier.dart`).

**Core design: introduce the variant as a first-class domain value and make
every flow-shaping `CaptureLevel.values` iteration take the variant's level
list instead.** The enum itself keeps all three values.

---

## 3. Implementation spec

### 3.1 Domain: `CaptureFlowVariant`

New file `lib/domain/capture/capture_flow_variant.dart` (pure Dart, no
Flutter/Riverpod imports):

```dart
enum CaptureFlowVariant { withBottom, withoutBottom }
```

- `String get id` → `'with_bottom'` / `'without_bottom'` (the wire/persistence
  id — used in Hive, analytics, remote config, and later the manifest).
- `static CaptureFlowVariant fromId(String? id)` — tolerant parse, unknown or
  null → `withBottom` (never throws; matches the repo's defensive-parse
  convention).
- `List<CaptureLevel> get levels` → const `[a, b, c]` / `[a, b]`. This getter
  is **the single source of the active level list** for the whole app.
- Doc comment stating the invariant: the 2-level variant is always a prefix of
  the 3-level one (A→B), so progression order never changes.

### 3.2 Config: per-variant segment counts (remote-overridable)

Extend `CaptureConfig` following the exact pattern of `CompletionThresholds` /
`UploadMinShots` (immutable class, validating `fromMap` that never throws,
`toMap` round-trip, `==`/`hashCode`):

- New class `VariantSegments` with wire key
  **`guided_capture_variant_segments`**:

  ```json
  {
    "with_bottom":    { "mid": 12, "high": 12, "low": 12 },
    "without_bottom": { "mid": 18, "high": 18 }
  }
  ```

  Keyed variant-id → (band-id → positive int). Non-positive / ill-typed
  entries are dropped; a non-map input yields the bundled default.

- **Bundled defaults are exactly the numbers above** (`static const
  bundledDefault`). The app must produce the new flow with no remote config at
  all.
- Resolution helper (top-level function or method — pick what reads best,
  colocated with the class):

  ```dart
  int effectiveSegmentsFor(CaptureConfig config, CaptureFlowVariant variant, String bandId)
  ```

  Precedence: variant map entry → that band's legacy `PitchBand.segments` →
  12. **Both** `levelStatesFromConfig` and `levelSegmentMachineFor` must go
  through this one resolver so the progression summary and the machines can
  never disagree on N (the same invariant their headers already document).
- `PitchBand.segments` stays (legacy fallback + old cached configs must still
  parse) but nothing in the new flow reads it directly anymore.
- Update `sanitizeCaptureConfig` / `capture_config_validator.dart` to clamp
  the new block (each count `>= 1`; cap at something sane like 60), and make
  sure `config_notifier.dart` round-trips it through cache without loss.

### 3.3 Thread the variant through the flow builders

Add a `CaptureFlowVariant variant` parameter (required — no silent default in
the builders themselves) to:

- `levelStatesFromConfig`, `initialProgressionFromConfig`,
  `reconcileWithConfig` (level_progression_builder.dart)
- `levelSegmentMachinesFromConfig` (level_segment_machines.dart)

Each iterates `variant.levels` instead of `CaptureLevel.values` and sizes each
level via `effectiveSegmentsFor`.

Then **audit every flow-shaping `CaptureLevel.values` call site** — run
`rg -n "CaptureLevel.values" lib test` and fix each of at least these:

- `lib/application/capture/completion_gate_provider.dart` — SummaryGate must
  require only the variant's levels (2-level sessions unlock Summary after B).
- `lib/application/capture/capture_summary_provider.dart` (two sites) — the
  summary lists only active levels.
- `lib/presentation/screens/capture/capture_summary_screen.dart` (~line 175,
  the `reviewGridItemsProvider` invalidation loop).
- `lib/application/capture/analytics/coverage_analytics_provider.dart`
  (~line 94, the per-level seeding loop).
- The `capture_session_complete` funnel-end latch — "all 3 levels" becomes
  "all levels of the active variant"; in the 2-level flow it fires
  exactly-once when B completes.
- The upload hard gate (per-level `uploadMinShots` floors) — only active
  levels are checked; a missing Level C must NOT block upload in the 2-level
  variant.

Some `CaptureLevel.values` uses may be purely display/lookup taxonomies that
are safe with 3 entries — judge each hit; anything that gates, counts, sums,
or lists levels to the user follows the variant.

### 3.4 Where the variant state lives

- New Riverpod state: the active session's variant, owned next to the existing
  capture-session state (follow the repo's Notifier + Hive pattern, e.g.
  alongside `lib/application/capture/session/`). Default `withBottom`.
- **Persistence:** extend the capture-session persistence
  (`capture_session_state.dart` / `capture_session_codec.dart`) and the level
  progression Hive store (`level_progression_store.dart`) to carry the variant
  id string. Decoding a persisted blob **without** the field (every existing
  session) yields `withBottom` — old sessions resume identically. Follow the
  codec's existing tolerant-decode style; add round-trip tests.
- **Resume:** a resumed session uses its persisted variant, not whatever the
  checklist toggle currently shows. `reconcileWithConfig` receives the
  persisted variant.
- **Lock rule:** once any level of the session has ≥1 accepted photo, the
  variant is locked. (The existing Start Over path already resets the session;
  after Start Over the toggle is editable again.)

### 3.5 Screen 4 UI (Pre-Capture Checklist)

In `pre_capture_screen.dart`, below the existing checklist items:

- A clearly-worded Yes/No control (segmented control or two selectable cards —
  match the screen's existing visual language and the platform-adaptive
  conventions used elsewhere, e.g. the tip surface) titled
  **"Can you capture the bottom of the object?"** with one-line helper copy for
  each state: Yes → "You'll capture 3 rings — eye, top and bottom level (12
  photos each)." / No → "You'll capture 2 rings — eye and top level (18 photos
  each)."
- Default: **Yes** (with bottom).
- When an in-progress session exists with ≥1 accepted photo: control shows the
  session's persisted variant, disabled, with a short explanation ("Locked for
  this capture — start over to change").
- Accessibility: proper semantics labels/toggle state, ≥48dp targets.
- Analytics: fire `bottom_capture_option_selected` with
  `{ flow_variant: 'with_bottom' | 'without_bottom' }` **on transition only**
  (not on every rebuild/tap of the same value) — mirror the transition-only
  pattern of the permission analytics events.

### 3.6 Routing / flow ends (2-level variant)

In `lib/app/routes/app_router.dart` and the Level B completion path:

- With `withoutBottom`: Level B complete screen's primary CTA goes to the
  Capture Summary (6C) instead of Level C intro. Its copy must not promise a
  next ring (reuse the same "final level" treatment Level C's complete state
  has today — check `level_complete_screen.dart` / `level_b_complete_screen`
  wiring).
- Level C routes (intro/capture/review) must be unreachable in `withoutBottom`
  — guard the route like the existing no-forward-skip guards; navigating there
  redirects to the frontier.
- With `withBottom` nothing changes.

### 3.7 Manifest / bundle (client side only — additive)

`lib/domain/upload/capture_manifest.dart`,
`lib/application/upload/capture_manifest_assembler.dart`,
`lib/application/upload/capture_bundle_packer.dart`:

- The manifest's level list / expected counts must be derived from the active
  variant's levels (no hardcoded 3-level assumption).
- Add a `flow_variant` field (the variant id string) to the manifest JSON.
  Additive only — the API-side validation of it is the follow-up task.

### 3.8 Fix while you're here (now user-visible)

There is a known bug: the per-ring yawStart reset path uses
`CaptureConfig.eyeRingSegments` for **all** levels
(`ringYawBaselineProvider` area). With per-variant counts this becomes a real
defect (a ring reset in the 18-segment variant must use 18, and B/C must use
their own N). Locate it, make it use the level's `effectiveSegmentsFor` count,
and add a regression test.

### 3.9 Remove the superseded object-size feature

`lib/domain/capture/object_size_segments.dart` (the unwired 36/30/24
object-size → segments mapping) is superseded by variant-based counts. Delete
the file, its tests, and any dangling references. Do not keep a dormant second
source of segment counts.

---

## 4. Out of scope — do NOT do these

- No changes under `recapture-api/` (separate follow-up prompt).
- No new `CaptureLevel` enum values; do not remove `c`.
- No changes to pitch band degree ranges or the `pitchBandIdForLevel` mapping.
- No destructive migration of persisted sessions — tolerant decode only.
- No changes to the upload engine internals (chunked manager, retry policy,
  queue) beyond the manifest shape in §3.7.

---

## 5. Acceptance criteria

1. Fresh session, checklist answered **Yes** → flow is A→B→C, every ring map /
   progress meter / gate uses 12 segments per level; summary shows 3 rows;
   `capture_session_complete` fires after C.
2. Fresh session, checklist answered **No** → flow is A→B, 18 segments per
   level; B complete routes to Summary; C is unreachable; SummaryGate and the
   upload hard gate pass without any C data; `capture_session_complete` fires
   after B, exactly once.
3. No remote config present → bundled defaults produce exactly 12-12-12 /
   18-18. A remote `guided_capture_variant_segments` override changes counts
   with no code change; malformed remote input falls back per-entry.
4. A pre-existing persisted session (no variant field) resumes as `withBottom`
   with its progress intact.
5. Variant is locked after the first accepted photo; Start Over unlocks it.
6. The yawStart-reset bug (§3.8) has a failing-before/passing-after test.
7. `object_size_segments.dart` and its tests are gone; `rg object_size` in
   `lib/`+`test/` returns nothing.
8. `flutter analyze` clean; `flutter test` fully green.

## 6. Required tests (minimum)

- `VariantSegments.fromMap` — happy path, drops bad entries, non-map input,
  round-trip; `effectiveSegmentsFor` precedence (variant → legacy band → 12).
- Builder tests for both variants: level id/code lists, counts 12/12/12 and
  18/18; `reconcileWithConfig` when the persisted variant differs from a fresh
  default (progress carries by levelId, C disappears cleanly for
  `withoutBottom`).
- Machines: `levelSegmentMachinesFromConfig` counts per variant.
- Completion gate / SummaryGate: 2-level session unlocks after B; 3-level
  still requires C.
- Session-complete latch: fires at B for `withoutBottom`, at C for
  `withBottom`, exactly once each.
- Codec/store round-trip with and without the variant field.
- Widget test on Screen 4: toggle renders, default Yes, transition-only
  analytics, locked state with an accepted photo.
- Router guard: Level C route redirects in `withoutBottom`.
- Regression test for §3.8.

Follow the repo's existing test hazards (Hive IO in `testWidgets` needs
`tester.runAsync`; screen tests inject fake settings stores — see existing
capture tests for the pattern).
               








