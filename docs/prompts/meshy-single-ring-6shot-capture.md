# Prompt: reshape Meshy capture to a SINGLE ring of 6, eye→top, with a HARD tilt gate

## Why this exists

The Meshy capture that shipped does NOT match the intended design. On a real
device today a Meshy project:

- captures **three rings** (`EYE 6 / TOP 2 / LOW 2` = 10, or `EYE 6 / TOP 2` = 8
  without bottom) — the 6/2/2 matrix in
  `recapture-api/src/models/types/captureVariants.ts` `SHAPE_DEFS.meshy` and its
  client mirror `VariantSegments.meshyDefaults` in
  `lib/domain/entities/capture_config.dart`;
- still shows the **"Can you capture the bottom of the object?"** question on the
  pre-capture checklist (`_BottomCaptureQuestion` in
  `lib/presentation/screens/capture/pre_capture_screen.dart`), with copy that
  reads "2 rings — 6 eye + 2 top" / "3 rings — 6 eye + 2 top + 2 bottom";
- lets the user shoot **from any tilt**. The eye ring's band is `mid = [40,110)`
  (`CaptureConfig.bundledDefault.pitchBands` in `capture_config.dart`), which is
  neither eye→top nor enforced: the shutter's readiness **fails open** whenever
  the motion sensors are unavailable (`CaptureReadiness.canCapture` in
  `lib/domain/entities/capture_readiness.dart` returns true when
  `!sensorSupported`).

The intended Meshy capture is **ONE ring of 6 photos** taken while sweeping the
camera around the object anywhere between eye level and looking down at its top —
**no TOP ring, no LOW/bottom ring, no bottom question, and a hard tilt gate** so a
shot only registers inside the eye→top window. The server still auto-selects the
best 4 of the 6 for the model, so the capture only has to supply spread.

## The target shape (single source of truth)

| | rings | per-ring | total | tilt window (hard) | drive | coverage floor |
|---|---|---|---|---|---|---|
| meshy | `EYE` only | `EYE: 6` | **6** | **eye→top, `[60,180)`** | manual shutter (no auto) | **100%** (all 6 required) |

- 6 yaw slots 60° apart on the single ring.
- `meshy` is **variant-independent**: `with_bottom` and `without_bottom` both
  resolve to the exact same one-ring-of-6 shape. The "bottom" question is not
  asked in Meshy mode at all.
- `full` mode is **untouched** end to end. Every change is gated on
  `mode == meshy`; every pre-existing call site and test must keep asserting the
  same `full` numbers.

### Tilt-scale note (READ BEFORE TOUCHING DEGREES)

Camera-tilt is the 0–180° scale documented in `lib/domain/capture/camera_tilt.dart`
and `capture_config.dart`: **0 = aimed at the sky, 90 = horizon/eye level,
180 = aimed at the ground**. Photographing the **top** of an object means aiming
**down** at it → tilt near 180; eye level → tilt 90. The window is deliberately
opened a little ABOVE eye level so a natural sweep is not rejected at the top of
the arc: **eye→top = `[60,180)`** (min inclusive, max exclusive) — from ~30°
above eye level through fully looking down. "No bottom" = never below 60 (the
camera never tips up toward the object's underside). `[60,180)` is the number to
implement; it is the ONE knob to change if product retunes it — keep min
inclusive / max exclusive.

## Backend changes (`recapture-api/`)

The backend already threads `mode` everywhere and Meshy floor is already 100
(`COVERAGE_FLOOR.meshy = 100`). Only the shape table changes.

1. **`src/models/types/captureVariants.ts` → `SHAPE_DEFS.meshy`:** make BOTH
   variants the single EYE ring of 6:
   ```ts
   meshy: {
     with_bottom:    { rings: ['EYE'], perRing: { EYE: 6 } },
     without_bottom: { rings: ['EYE'], perRing: { EYE: 6 } },
   },
   ```
   Leave `LEGACY_PER_RING.meshy` empty (`meshy` never shipped a stable count that
   needs back-compat; if a `[]` entry is required by the type, keep it empty).
   Rewrite the stale `6/2/2`, `8–10 photos`, "meshy … (6/2/2)" doc comments at
   the top of the file and around `SHAPE_DEFS` to "one ring of 6".

2. **Confirm the count helpers still hold** without further edits (they derive
   from `SHAPE_DEFS`, so they should):
   - `expectedImageCount(variant, 'meshy')` → **6** for both variants.
   - `photosByRing(variant, 'meshy')` → `{ EYE: { min: 6, max: 6 } }`; `TOP`/`LOW`
     absent → they become **UNEXPECTED_LEVELS** in manifest validation.
   - `expectedFilesCount` for a Meshy job (images + manifest) → **7**, and the
     create-job count cross-check must accept exactly 7.

3. **Grep the whole `recapture-api/src` for any place that hardcodes a Meshy ring
   list or count** (search `TOP`, `LOW`, `2, 2`, `6, 2`, `10` near `meshy`) and
   confirm none survive. `jobsService.ts` (`planFor`, `loadUploadableJob`) and the
   processor already pass `mode` into `ringsForVariant`; verify they now yield the
   single ring for Meshy.

4. **Tests** (`recapture-api/`, Vitest):
   - `capture-modes.test.ts` — meshy is one ring of 6, trivially uniform,
     `photosByRing = { EYE: { 6, 6 } }`, `expectedImageCount = 6` both variants.
   - `jobs-meshy-mode.test.ts` — only legal `expectedFilesCount = 7`; `TOP`/`LOW`
     keys in a Meshy manifest are UNEXPECTED_LEVELS; range `[7,7]`.
   - `auto-photo-selection.test.ts` — reframe any 6/2/2 language; the selector is
     pure and already picks best-4 from a 6-photo ring, so assertions on behavior
     stand — only headers/comments change.
   - `npm run type-check` clean and the FULL suite green.

## Client changes (Flutter, repo root)

### A. Shape counts

5. **`lib/domain/entities/capture_config.dart` → `VariantSegments._meshyDefaults`
   / `meshyDefaults`:** collapse to the single ring for both variants:
   ```dart
   static const Map<String, Map<String, int>> _meshyDefaults = {
     'with_bottom':    {'mid': 6},
     'without_bottom': {'mid': 6},
   };
   ```
   (`mid` is the client band id for the EYE ring — see `pitchBandIdForLevel`.)
   Update the doc comments on `_meshyDefaults`, `meshyDefaults`,
   `meshyBundledDefault` away from "6 eye / 2 top / 2 bottom (10 …)".

6. **Active levels in Meshy = `[A]` only.** The flow currently walks the
   variant's active levels (`CaptureFlowVariant.levels`, A→B[→C]). In Meshy mode
   it must run **only Level A** regardless of variant. Introduce a single
   mode-aware resolver — e.g. `activeCaptureLevels(variant, mode)` — and route
   EVERY level-sequence consumer through it so none can disagree:
   - `levelStatesFromConfig` / `initialProgressionFromConfig` /
     `progressionFromLedger` / `reconcileWithConfig`
     (`lib/application/capture/progression/level_progression_builder.dart`),
   - `levelSegmentMachinesFromConfig`
     (`lib/application/capture/progression/level_segment_machines.dart`),
   - the upload gate (`upload_gate_provider.dart`), the summary
     (`capture_summary_provider.dart`), and the upload snapshot in
     `lib/application/upload/upload_flow.dart` (`progressionFromLedger`, ~line 794).

7. **Thread `mode` through the builders that currently drop it.** These call the
   mode-aware resolvers WITHOUT a mode and silently fall back to `full`
   (16/16/16), so today a Meshy capture's progression/machines/upload snapshot are
   computed against full counts even though the live HUD is correct:
   - `initialProgressionFromConfig`, `progressionFromLedger`,
     `reconcileWithConfig` in `level_progression_builder.dart`;
   - `levelSegmentMachinesFromConfig` in `level_segment_machines.dart`
     (the plural builder never forwards `mode` to `levelSegmentMachineFor`);
   - the `level_progression_provider.dart` `start` / `resume` call sites;
   - the `upload_flow.dart` `progressionFromLedger` call.

   Each must read `captureModeProvider` (or accept a `mode` parameter fed from it)
   and pass it down. This is a real correctness fix independent of the reshape.

### B. Tilt band + HARD gate

8. **Give Meshy its own EYE-ring band `[60,180)`.** The eye ring's band is
   resolved via `resolvedPitchBandProvider(bandId)` (see `_resolvedBand` in
   `capture_screen.dart`) which precedence-resolves override → remote/cache →
   bundled `mid = [40,110)`. In Meshy mode the `mid` band must resolve to
   `min 60 / max 180`. Prefer a mode-aware effective config
   (`effectiveCaptureConfigProvider` → in Meshy, a `CaptureConfig` whose `mid`
   band is `PitchBand(id:'mid', minDegrees:60, maxDegrees:180, segments:6)`) that
   the band resolver, tilt meter, and gauge all read, so guidance and the gate
   share one band. Do NOT special-case degrees at individual call sites.

9. **Make the shutter gate HARD in Meshy.** Today the shutter's `CaptureReadiness`
   is built with `mode: CaptureMode.guided` and `inBand` from
   `CapturePitchGuide.isInBand(band, tilt.tiltDegrees)`
   (`capture_screen.dart` ~line 1543), but `canCapture` **fails open** when
   `!sensorSupported`. In Meshy mode a shot outside `[60,180)` must be **rejected**
   (blocked shutter → "adjust tilt"), not silently taken:
   - Keep `mode: guided` (the readiness `manual` mode means "no gate at all" — do
     NOT use it here).
   - Decide the fail-open policy explicitly: if the target device streams IMU tilt
     (verify — see Hazard H2), keep the gate hard. If you must preserve fail-open
     so a sensor-less device is never locked out, scope the fail-open to `full`
     mode and require in-band in Meshy; surface a clear "tilt guidance needed"
     state instead of allowing the shot. State which you chose in the PR.
   - The auto-capture path is already off in Meshy (`_autoCaptureAllowed` →
     `usesAutoCapture` false), so only the manual shutter needs the hard gate.

### C. Pre-capture checklist copy + no bottom question

10. **Hide the bottom question entirely in Meshy** and replace the ring copy.
    In `pre_capture_screen.dart`:
    - When `captureModeProvider == meshy`, do NOT render `_BottomCaptureQuestion`
      (and do not select/persist a flow variant from it — Meshy is
      variant-independent).
    - Show a single Meshy line instead, e.g.:
      > **One ring — 6 photos.** Circle the object once, keeping the camera
      > between eye level and looking down at its top. No underside needed.
    - The `ringCopy`/`labelForBand` block that prints "6 eye + 2 top …" must not
      run in Meshy (it would read the now-single-ring map and print "6 eye" only,
      which is acceptable as a fallback but the dedicated copy above is clearer).
    - Full mode keeps the existing Yes/No bottom question and 2-ring/3-ring copy
      byte-for-byte.

11. **Post-Level-A routing already ends the flow at Summary** in Meshy (only Level
    A is active). Verify `app_router.dart`'s post-Level-A guard sends Meshy to the
    Summary/complete route and never to a Level B/C route.

### D. Tests (Flutter)

12. Add/'update `test/capture/` coverage:
    - Meshy config shape: `effectiveSegmentsFor(config, withBottom, 'mid', mode: meshy) == 6`;
      `effectiveSegmentsFor(..., 'high'/'low', mode: meshy)` is never reached
      (only `mid` exists) and `expectedPhotoTotalFor(config, anyVariant, mode: meshy) == 6`.
    - `activeCaptureLevels(withBottom, meshy) == [A]` and `(withoutBottom, meshy) == [A]`.
    - Progression built in Meshy has ONE level of 6 (not three); the upload
      snapshot (`progressionFromLedger` with mode) reports 6, not 16.
    - Tilt gate: a `CaptureReadiness` for Meshy with `tiltDegrees < 90`
      (e.g. 45) is NOT `canCapture`; `>= 90 && < 180` with stable sensors IS.
    - Manifest/job: a Meshy capture stamps `captureMode: 'meshy'` and
      `expectedFilesCount == 7`.
    - Full-mode regression: existing `full_capture_photo_counts_test.dart` and the
      whole suite stay green; `flutter analyze` clean.

## Acceptance criteria

- Creating a **Meshy** project (choose "Meshy Capture" in the capture-mode sheet)
  → pre-capture shows **no bottom question**, copy says **one ring / 6 photos**.
- In capture: the ring map shows **6 segments**, the counter reads `/6`, there is
  **no AUTO pill**, and the shutter **blocks** (greyed, "adjust tilt") until the
  camera tilt is within eye→top; a shot below eye level never registers.
- Level A completing (all 6) goes straight to Summary — no TOP/LOW rings appear.
- Upload sends `captureMode: 'meshy'` and exactly **7** files (6 images + manifest);
  the server accepts it and the model auto-generates from the best 4 of 6.
- `full` mode is unchanged: 48-photo flow, bottom question, auto-capture, all
  existing tests still assert the same numbers.

## Hazards / things to check

- **H1 — the two mode enums.** There are unrelated `CaptureMode` types:
  `full`/`meshy` (`lib/domain/capture/capture_mode.dart`, the SHAPE) and
  `guided`/`manual` in BOTH `create_project_options.dart` (server auto-drive
  choice) and `capture_readiness.dart` (shutter gate). Do not conflate them; the
  reshape is entirely about the `full`/`meshy` shape enum.
- **H2 — why tilt feels "free" today.** Confirm whether the test device actually
  streams IMU tilt (`currentTiltProvider` → `sensorSupported`). If it does not,
  the shutter fails open regardless of band and the "hard gate" will still feel
  free on that device — that is a device/sensor-wiring issue, not this reshape.
  Decide fail-open policy (step 9) with this in mind.
- **H3 — reachability of Meshy.** The Full/Meshy choice is only offered in the
  `capture_mode_sheet`; make sure both entry points into project creation present
  it (the empty-state CTA was fixed to route through the sheet — keep it that way)
  and that the sheet defaults are acceptable (currently defaults to Full).
- **H4 — server compatibility.** A Meshy project created against a deployment that
  still expects 6/2/2 will 422 at create-job with a 7-file count. Ship the backend
  shape change and the client together, or gate the client on a config flag.
- **H5 — single source of truth.** Ring lists and counts live ONLY in
  `SHAPE_DEFS` (server) and `VariantSegments`/`effectiveSegmentsFor` +
  `activeCaptureLevels` (client). Do not reintroduce a hardcoded ring list or
  count anywhere; the reshape is a data change plus mode-threading, not new
  branching in flow consumers.

## Out of scope

- Full-mode behavior, counts, and copy.
- The server's best-4-of-6 auto-selection (already handles a 6-photo ring).
- The capture-mode sheet's visual design (only its reachability, H3).
