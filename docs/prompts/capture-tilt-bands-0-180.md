
✅✅✅✅✅✅✅✅✅✅✅/2 

# Task: 0–180° Camera-Tilt Bands per Capture Level (BOTTOM=up, EYE=straight, TOP=down)

> Touches BOTH codebases: the Flutter client (repo root) and `recapture-api/`
> (remote-config defaults + schema must move in lockstep with the client
> defaults, §5). No native Kotlin/Swift changes are required — the smoothed
> quaternion this feature needs already streams to Dart.

Read **AGENTS.md** at the repo root first (config rules, testing conventions).
Its conventions win over anything here.

---

## 1. Goal

Redefine how the guided capture decides "is the phone tilted right for this
ring" using a single **camera-tilt angle on a 0–180° scale**:

| Ring (level)       | Band id | Tilt range      | User instruction        |
|--------------------|---------|-----------------|-------------------------|
| BOTTOM ring (C)    | `low`   | **[0°, 60°)**   | tilt phone **up**       |
| EYE ring (A)       | `mid`   | **[60°, 120°)** | hold phone **straight** |
| TOP ring (B)       | `high`  | **[120°, 180°]**| tilt phone **down**     |

Where the tilt angle is defined as **the angle between the back-camera's aim
direction and world-up**: 0° = camera pointing straight at the sky (phone held
low, shooting the object's underside), 90° = camera level with the horizon,
180° = camera pointing straight at the ground (top-down shot).

Everything that consumes "pitch" today — the tilt meter, the shutter pitch
gate, auto-capture's in-band check — must consume this ONE new scalar, so the
needle, the gate, and the trigger can never disagree.

## 2. Grounding facts (verified in the codebase — read before coding)

- **The current Euler pitch CANNOT express this scale.**
  `SmoothedOrientation.pitchDegrees` (`lib/platform/imu_rotation_channel.dart`)
  follows Android's `SensorManager.getOrientation` convention — pitch lives in
  [-90°, +90°] and *folds* past vertical, so "tilted 30° up past vertical" and
  "30° short of vertical" are indistinguishable from pitch alone. The fix:
  `SmoothedOrientation` ALSO carries the smoothed unit quaternion
  (`qx, qy, qz, qw` — smoothing happens natively in the quaternion domain, so
  it's gimbal-safe). **Derive the tilt from the quaternion, not from Euler
  pitch** (§3).
- Band ranges are config, not code: `PitchBand` (id, `minDegrees` inclusive,
  `maxDegrees` exclusive, segments) in `lib/domain/entities/capture_config.dart`.
  Current bundled defaults are `low [0,30) / mid [30,60) / high [60,90)` — an
  old placeholder scale that this task replaces wholesale.
- The level→band mapping already matches the table above and does NOT change:
  `pitchBandIdForLevel` in
  `lib/application/capture/analytics/capture_level_events.dart`
  (A→`mid`, B→`high`, C→`low`). Degrees live only in config.
- **`sanitizeCaptureConfig` (`lib/domain/entities/capture_config_validator.dart`)
  clamps band degrees into [0, 90]** — left untouched it would silently
  mutilate the new bands (120–180 → 90–90 → dropped). Must become [0, 180].
- Per-level overrides flow through `pitch_band_override_provider.dart` →
  `resolvePitchBand` (`lib/domain/capture/pitch_band_resolution.dart`) →
  `resolvedPitchBandProvider` (`pitch_band_resolver.dart`). Check
  `pitch_band_resolution.dart` for its own degree-validity rules (existing
  tests pin `low` to the OLD positive [0,30) range) — validation and tests
  must move to the new scale.
- The live feed is `currentPitchProvider`
  (`lib/application/capture/current_pitch_provider.dart`): wraps the shared
  orientation stream, EMAs `pitchDegrees`, emits `PitchSample`. Its consumers
  (grep `currentPitchProvider` / `PitchSample` / `pitchDegrees` under
  `lib/application/capture/` and `lib/presentation/`) include the tilt meter
  overlay, the capture screen's shutter/auto-capture pitch loop, and
  `guidance_engine.dart`. `CapturePitchGuide.isInBand/activeBand`
  (`lib/domain/entities/capture_pitch_guide.dart`) is the band-membership
  primitive they share.
- The tilt meter (`lib/presentation/widgets/tilt_meter_overlay.dart`) derives
  its gauge range from the resolved band via `tiltGaugeRangeForBand`, but has a
  hardcoded last-resort fallback `TiltTarget(minDegrees: 30, maxDegrees: 60,
  bandId: 'mid')` — stale after this change.
- Backend serves band defaults too: `GET /remote-config`
  (`recapture-api/src/validation/remoteConfigSchema.ts`,
  `remoteConfigService.ts`) — note its wire entries use `min`/`max` while the
  client's `CaptureConfig.fromMap` reads `minDegrees`/`maxDegrees`. **Verify
  where (or whether) the client maps between the two shapes**
  (`lib/data/repositories/config_repository.dart`) before assuming remote
  bands reach the client at all; fix/align as part of §5, otherwise stale
  server defaults will override the new bundled ones.
- The roll constraint (advisory ±15° roll warning on B/C) is a SEPARATE axis
  and is out of scope — do not touch it.
- Known pre-existing bug (out of scope, do not fix here): the per-ring yaw
  baseline uses `eyeRingSegments` for all levels.

## 3. The tilt primitive (new, pure Dart)

Create `lib/domain/capture/camera_tilt.dart` — pure Dart, no Flutter imports:

- `double cameraTiltDegrees({required double qx, qy, qz, qw})` — rotate the
  back-camera body axis (device frame: X right, Y up in portrait, Z out of the
  screen → **camera looks along −Z**) into the world frame with the
  quaternion, then return `acos(clamp(dot(camWorld, worldUp), -1, 1))` in
  degrees. Result is intrinsically [0, 180], no wraparound, no gimbal cases.
  Derive the closed form (for v = (0,0,−1) only the rotated z-component is
  needed) rather than pulling in a vector-math dep.
- **Clamp the result to [0.0, 179.999]** in this ONE place, so the
  `maxDegrees`-exclusive `PitchBand` contract is untouched and a physically
  perfect 180° still lands in the `high` band.
- NaN/Infinity components or a non-unit/degenerate quaternion (‖q‖² far from
  1 — note `SmoothedOrientation.fromEvent` defaults a MISSING `q` to
  (0,0,0,1), which is a valid identity, so detect "missing" by the event
  actually lacking `q` if distinguishable, else accept identity as a real
  reading) → return `double.nan`; callers already treat NaN as
  out-of-every-band (`isInBand` is IEEE-safe) and the feed drops NaN samples.
- Unit-test against canonical quaternions (identity = flat screen-up → camera
  at the ground → **180** (clamped 179.999); rotated 90° about X to upright
  portrait → **90**; screen-down flat → **0**; a 30°-past-vertical lean-back →
  **60**). Derive expected values by hand in the test comments.
- Add a `SmoothedOrientation.cameraTiltDegrees` convenience getter in
  `imu_rotation_channel.dart` delegating to the pure function.

**iOS caveat:** the Swift sensor port is device-unverified. The convention
must hold on both platforms — the quaternion both sides emit must map
body→world with the same frames. Add a device-QA line item (§7) rather than
trusting it.

## 4. Client changes

### 4.1 Config: new bundled defaults + widened validation

In `capture_config.dart` → `CaptureConfig.bundledDefault`:

```dart
PitchBand(id: 'low',  minDegrees: 0,   maxDegrees: 60,  segments: 12),
PitchBand(id: 'mid',  minDegrees: 60,  maxDegrees: 120, segments: 10),
PitchBand(id: 'high', minDegrees: 120, maxDegrees: 180, segments: 8),
```

(Keep the legacy per-band `segments` values — real counts come from
`guided_capture_variant_segments` via `effectiveSegmentsFor`.) Bump `version`.
Update the `PitchBand.fromMap` fallback `maxDegrees: 90` default to something
sane on the new scale (e.g. 180). In `capture_config_validator.dart`, change
the degree clamp from [0, 90] to **[0, 180]** and update its doc header. Apply
the same range change to any validity rules in `pitch_band_resolution.dart`
and the override provider.

### 4.2 Feed: replace the pitch provider with a tilt provider

Rename honestly — do NOT leave a `pitchDegrees` field that secretly carries
tilt. In `current_pitch_provider.dart` (rename file to
`current_tilt_provider.dart`): `TiltSample { tiltDegrees, sensorSupported }`,
`currentTiltProvider` mapping each `SmoothedOrientation` through
`cameraTiltDegrees` (drop NaN, keep the existing secondary EMA and the
error→unsupported degrade; EMA on tilt is safe — no wraparound on [0,180]).
Keep `sharedOrientationProvider` as-is (the ring/yaw resolver also feeds off
it). Migrate every consumer found by grepping `currentPitchProvider`,
`PitchSample`, `pitchDegrees` — tilt meter, capture screen pitch-tick loop
(shutter gate + auto-capture in-band checks), `guidance_engine.dart`.
`CapturePitchGuide` stays as the membership primitive; update its doc header
to name the new convention (it compares "tilt degrees" now, still min-incl /
max-excl).

### 4.3 UI

- Tilt meter: replace the stale fallback `TiltTarget(30, 60, 'mid')` with the
  new mid band (60–120); confirm `tiltGaugeRangeForBand` produces sensible
  gauge spans for 60°-wide bands (padding, needle clamp).
- Instruction copy: wherever level intro/capture screens instruct the tilt
  ("Screen 6" family, level B/C intro wrappers, help-sheet `CaptureTip`s),
  align wording with: C = "Tilt the phone up", A = "Hold the phone straight",
  B = "Tilt the phone down". Grep for degree numbers in user-facing strings.
- Analytics: event shapes unchanged (`pitch_band_fallback`,
  `tilt_meter_out_of_band` etc. already carry min/max verbatim). Just confirm
  nothing logs a hardcoded scale assumption.

## 5. Backend sync (`recapture-api/`)

- Update the served pitch-band DEFAULTS (wherever `remoteConfigService.ts`
  sources its baked defaults — plus the seeded store doc if one exists) to the
  §1 values, and widen any Zod `min`/`max` bounds in `remoteConfigSchema.ts`
  that assume ≤ 90.
- Resolve the `min`/`max` vs `minDegrees`/`maxDegrees` wire-shape question
  from §2 the same way on both sides (one mapping, tested).
- Bump the served config `version` so client ETag/304 caches roll over.
- Tests: schema accepts the new defaults; endpoint golden-response tests
  updated.

## 6. Tests (client)

- `camera_tilt` unit tests: canonical quaternions (§3), clamp at both ends,
  NaN propagation.
- Config: bundled defaults tile [0,180] with no gap/overlap
  (`low.max == mid.min`, `mid.max == high.min`); sanitizer preserves a 179°
  band and still rejects/clamps > 180; version bumped.
- Resolver/override tests: re-pin to the new ranges (the old "Level C stays
  positive [0,30)" expectations are obsolete).
- Feed: quaternion stream in → `TiltSample` out (EMA seeded, NaN dropped,
  error → unsupported).
- Band membership sweep: tilt 0/59.9/60/119.9/120/179.999 map to
  low/low/mid/mid/high/high; 180 physical (clamped) → high.
- Tilt meter + shutter-gate widget tests re-pinned to new band numbers.
- Full `flutter analyze` + `flutter test` green; backend `npm test` green.

## 7. Device QA checklist (manual, after implementation)

- Android device: hold phone flat screen-up → meter reads ~180 (TOP zone);
  upright → ~90 (EYE zone); screen-down → ~0 (BOTTOM zone). Shutter enables
  only in the active level's zone; auto-capture fires only in-zone.
- Sweep slowly through vertical while leaning back — the reading must pass
  smoothly through 90→60 without folding back (the Euler-pitch failure mode).
- iOS device (when available): same three poses — verifies the Swift
  quaternion frame convention (§3 caveat).

## 8. Out of scope

Roll-constraint warning (separate axis), yaw/segment logic and the known
`eyeRingSegments` bug, native Kotlin/Swift changes, placement guide, any
upload/backend-job behavior.
