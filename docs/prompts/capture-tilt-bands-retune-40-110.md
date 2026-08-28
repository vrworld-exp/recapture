# Task: Retune the capture tilt bands to 0–40 / 40–110 / 110–180

> Touches BOTH codebases: the Flutter client (repo root) and `recapture-api/`
> (remote-config defaults + tests). No native Kotlin/Swift changes — the tilt
> scalar is derived in Dart from the smoothed quaternion and its definition is
> NOT changing.

Read **AGENTS.md** at the repo root first (config rules, testing conventions).
Its conventions win over anything here. This task supersedes the band numbers
set by `docs/prompts/capture-tilt-bands-0-180.md`; everything else in that
document (the 0–180° camera-tilt scale, the level→band mapping, the quaternion
derivation) stays exactly as it is.

---

## 1. Goal

Only the **boundaries between the three bands** change. The scale, the band
ids, the level→band mapping, and the min-inclusive/max-exclusive contract are
untouched.

| Ring (level)    | Band id | Today            | **After this change** | User instruction        |
|-----------------|---------|------------------|-----------------------|-------------------------|
| BOTTOM ring (C) | `low`   | [0°, 60°)        | **[0°, 40°)**         | tilt phone **up**       |
| EYE ring (A)    | `mid`   | [60°, 120°)      | **[40°, 110°)**       | hold phone **straight** |
| TOP ring (B)    | `high`  | [120°, 180°)     | **[110°, 180°)**      | tilt phone **down**     |

Tilt is the angle between the back camera's aim and world-up: 0° = camera at
the sky, 90° = horizon, 180° = camera at the ground
(`lib/domain/capture/camera_tilt.dart`). Bands must still **tile [0, 180]
exactly** — no gaps, no overlaps: `low.max == mid.min` and `mid.max == high.min`.

### Consequences to be aware of (do not "fix" these silently)

- The bands are no longer equal thirds. Widths become **40 / 70 / 70**.
- The EYE ring is no longer centred on the horizon: its centre moves from 90°
  to 75°, and 90° (phone perfectly level) now sits 20° below its upper edge.
  Anything that treats the eye band as horizon-symmetric (a needle centre, a
  "perfect" readout, copy that says "hold level") must be re-checked against
  §4, not hardcoded back to 90.
- The BOTTOM ring becomes the **narrowest** band (40° wide vs 60° today), so
  it is the hardest one to hold. Expect the auto-capture in-band dwell for
  level C to be the most affected in device QA (§6).

---

## 2. Grounding facts (verified in the codebase — read before coding)

- Band ranges are **config, not code**: `PitchBand` (id, `minDegrees`
  inclusive, `maxDegrees` exclusive, `segments`) in
  [capture_config.dart](../../lib/domain/entities/capture_config.dart).
  There is exactly one bundled-default list, at
  [capture_config.dart:380-392](../../lib/domain/entities/capture_config.dart#L380-L392).
- Effective bands resolve through `resolvePitchBand`
  ([pitch_band_resolution.dart](../../lib/domain/capture/pitch_band_resolution.dart))
  with precedence **override → config (remote/cache/bundled) → bundled default**.
  `kPitchBandMinDegrees`/`kPitchBandMaxDegrees` stay `0`/`180` — the *validity
  window* is unchanged, only the defaults inside it move.
- `sanitizeCaptureConfig`
  ([capture_config_validator.dart](../../lib/domain/entities/capture_config_validator.dart))
  already clamps to `[0, 180]` and drops inverted/zero-width bands. **No change
  needed** — but it does NOT enforce tiling, so a bad remote payload can still
  produce a gap. Leave that behaviour as-is unless §7 is taken.
- Band membership is one function: `CapturePitchGuide.isInBand`
  ([capture_pitch_guide.dart](../../lib/domain/entities/capture_pitch_guide.dart)).
  Every consumer (tilt meter, shutter gate, auto-capture) reads it, so the
  needle, the gate and the trigger cannot disagree. Nothing here changes.
- **Three places hardcode `60`/`120` as a last-resort floor** and will go stale
  if missed:
  - [capture_config.dart:383-385](../../lib/domain/entities/capture_config.dart#L383-L385) — bundled defaults
  - [guidance_engine.dart:177](../../lib/application/capture/guidance_engine.dart#L177) — `TiltTarget(60, 120, 'mid')`
  - [tilt_meter_overlay.dart:106](../../lib/presentation/widgets/tilt_meter_overlay.dart#L106) — `TiltTarget(60, 120, 'mid')`
- **The client's "remote" config repository is still a stub** that returns
  hardcoded bands (version 3):
  [config_repository.dart:60-72](../../lib/data/repositories/config_repository.dart#L60-L72).
  It always succeeds, so on a live app it OVERWRITES the bundled defaults within
  ~400ms. If this stub is not updated, the new bands will be visible for a few
  frames and then silently replaced by the old ones. **This is the single most
  likely way to ship this change and see nothing happen.**
- **A stale Hive cache is applied before the remote fetch** and unconditionally
  wins over the bundled default
  ([config_notifier.dart:29-36](../../lib/application/config/config_notifier.dart#L29-L36)).
  An existing install therefore starts every session on the OLD bands until the
  fetch lands. See §7 for the optional guard.
- Backend defaults live in
  [remoteConfigSchema.ts:114-118](../../recapture-api/src/validation/remoteConfigSchema.ts#L114-L118)
  and are served by `remoteConfigService` — but a `ClientConfig` document in
  Mongo, if one exists in an environment, **overrides those defaults**
  (`doc.pitchBands`). Retuning the code default does not retune a deployed
  environment that has a stored config; see §6.

---

## 3. Client changes

1. **Bundled defaults** —
   [capture_config.dart:380-392](../../lib/domain/entities/capture_config.dart#L380-L392):
   `low 0→40`, `mid 40→110`, `high 110→180`. Leave the legacy per-band
   `segments` values alone (real counts come from
   `guided_capture_variant_segments` via `effectiveSegmentsFor`). Bump
   `version: 2` → `4`.
2. **Stub remote payload** —
   [config_repository.dart:60-72](../../lib/data/repositories/config_repository.dart#L60-L72):
   same three ranges, keep its distinct `version` (bump `3` → `5` so
   "remote applied" stays observable and stays above the bundled version).
3. **Last-resort `TiltTarget` floors** — `guidance_engine.dart:177` and
   `tilt_meter_overlay.dart:106` → `minDegrees: 40, maxDegrees: 110`.
4. **Doc comments carrying the old numbers** — update every one; they are the
   repo's contract notes and a wrong one is worse than none:
   - `pitch_band_resolution.dart:15-19` (`low [0,60)` … `high [120,180)`)
   - `camera_tilt.dart:21-24` (the `high = [120, 180)` clamp rationale —
     `kCameraTiltMaxDegrees = 179.999` and its reasoning are UNCHANGED, only
     the quoted band bound moves to `[110, 180)`)
   - `capture_config.dart:376-379`, `tilt_target.dart:61-62`,
     `tilt_meter_overlay.dart:67`
   - Add a one-line note in `docs/prompts/capture-tilt-bands-0-180.md` pointing
     at this document so the old table is not read as current.
5. **Do NOT change**: `kPitchBandMinDegrees`/`kPitchBandMaxDegrees`,
   `kCameraTiltMaxDegrees`, `pitchBandIdForLevel`, `isValidPitchBand`,
   `sanitizeCaptureConfig`'s clamp, the quaternion derivation, ring segment
   counts, or any upload/manifest logic.

---

## 4. Sweep for numeric assumptions (the real work)

Grep both codebases for `60`, `120`, `\b90\b` near tilt/pitch/band context and
judge each hit. Specifically confirm:

- **Auto-capture edge hysteresis** —
  [auto_capture_trigger.dart:70-90](../../lib/domain/capture/auto_capture_trigger.dart#L70-L90).
  `bandHysteresisDeg` widens the band by a fixed amount on both edges. Verify
  the configured value is still small relative to the **narrowest** band (now
  40°, `low`) — a hysteresis that is a large fraction of the band lets a level-C
  frame be accepted well outside its range. Report the current value and
  whether it needs reducing; do not change it without saying so explicitly.
- **Tilt meter needle/scale** —
  [tilt_meter_overlay.dart](../../lib/presentation/widgets/tilt_meter_overlay.dart)
  and [tilt_target.dart](../../lib/domain/entities/tilt_target.dart). The
  padded display window is derived from the band (`TiltTarget.fromBand`), so
  asymmetric bands must render correctly — check the eye-ring window is not
  implicitly assumed symmetric about 90.
- **Guidance copy / direction hints** —
  [guidance_resolver.dart](../../lib/domain/capture/guidance_resolver.dart),
  instruction banner, direction arrow. `aboveBand`/`belowBand` are computed
  from band bounds; confirm no hint text quotes a hardcoded degree figure.
- **Level-C cutoff QA doc** — `docs/qa/low-ring-pitch-cutoff-qa.md` references
  the old low-ring range; update it.

---

## 5. Backend changes (`recapture-api/`)

1. `src/validation/remoteConfigSchema.ts:114-118` — `DEFAULT_REMOTE_CONFIG.pitchBands`
   to the new three ranges. The per-field `z.number().min(0).max(180)` bounds
   are unchanged.
2. `tests/remote-config-tilt-bands.test.ts:41-43` — `EXPECTED_PITCH_BANDS` to
   match. The adjacency assertions (`low.max === mid.min`, `mid.max === high.min`,
   `low.min === 0`, `high.max === 180`) must keep passing **unmodified** — they
   are the tiling contract and are the reason this file exists.
3. `tests/fixtures/packer-capture-manifest.json` — this fixture is a REAL
   packer-produced manifest committed to stop fixture drift. Its embedded
   `pitchBand` values (60/120, 120/180, 0/60) are a historical record of a
   capture taken under the old bands. **Leave it alone** unless a test asserts
   the fixture matches current config — if one does, that assertion is the bug;
   report it rather than editing the fixture.

---

## 6. Rollout / verification

- Client: `flutter test` must be fully green (~2140 tests). Expect failures in
  `test/config/pitch_band_resolution_test.dart`,
  `test/config/capture_pitch_guide_test.dart`,
  `test/config/capture_config_validator_test.dart`,
  `test/capture/auto_capture_pitch_band_test.dart`,
  `test/capture/low_ring_pitch_band_acceptance_test.dart`,
  `test/capture/top_ring_pitch_band*.dart`,
  `test/capture/tilt_target_test.dart`,
  `test/capture/tilt_meter_overlay_test.dart`,
  `test/capture/capture_screen_level_band_test.dart`.
  Fix each by updating the **expected band numbers**, never by loosening an
  assertion. Add boundary cases for the new edges: `39.999`/`40.0` and
  `109.999`/`110.0` must land in exactly one band each.
- Backend: `npm test` in `recapture-api/` (~396 tests) green.
- **Deployed environments**: if a `ClientConfig` document exists with stored
  `pitchBands`, it wins over the new code default. Check each environment and
  either update or clear that field — otherwise the app keeps the old bands in
  production while every test is green. State clearly in the final report
  whether this was checked.
- **Device QA (required — this is a feel change, not a logic change)**: walk all
  three rings on a real device. Confirm the level-C (bottom) ring is still
  comfortably holdable at 40° of width, that the needle reads sensibly at 90°
  now that it is off-centre in the eye band, and that auto-capture does not
  fire across a boundary.

---

## 7. Optional, recommended — stale-cache guard

A returning user's Hive cache carries the old bands and is applied before the
remote fetch. If you want the new bands to be authoritative from the first
frame, add a minimum-accepted-version constant and have `ConfigNotifier`'s
cache step drop any cached config below it (falling through to the bundled
default rather than the stale cache). Keep it to that one guard — do not add
a migration layer. If you implement it, cover it with a test that a
below-minimum cached config is ignored and an at-or-above one is used.

---

## 8. Deliverables

- The two band-default edits, the two `TiltTarget` floors, and all doc-comment
  updates.
- Updated Flutter + backend tests, all green, with the new boundary cases.
- A short report: the value of `bandHysteresisDeg` and your verdict on it, the
  `ClientConfig` environment check, anything in §4 that turned out to assume a
  symmetric or equal-width band, and the device-QA status (explicitly "not yet
  done" if it has not been).
