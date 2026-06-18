# Stability gate (motion trigger for auto-capture)

Detects when the device is held steady enough to capture and emits a **debounced**
stable/unstable state plus a "stable" **trigger** the auto-capture flow consumes.
Consumes raw `TYPE_GYROSCOPE` + `TYPE_LINEAR_ACCELERATION` (not the rotation-vector
stream); does **not** capture, smooth orientation, or do pose fusion.

Channel: `com.mayasabhaxr.recapture/stability` (`AppConfig.channelStability`).

## The gate

```
gyroMag < gyroThresh (0.8 rad/s)  AND  linAccelMag < accelThresh (0.15 g ≈ 1.47 m/s²)
held CONTINUOUSLY for dwellMs (250 ms)  →  STABLE
```

- **Magnitudes:** `gyroMag = |gyro|` in rad/s; `linAccelMag = |linear accel|` in
  m/s². The g threshold is converted to m/s² **once, explicitly**
  (`StabilityMath.gToMs2`, 0.15 × 9.81) — no silent ×9.81 elsewhere.
- **Strict `<`:** a value exactly at the threshold is NOT stable (defined,
  consistent).
- **Most-recent-of-each:** the two sensors arrive independently, so the AND is
  re-evaluated on every sample using the latest value of EACH — never requiring
  synchronized pairs (`StabilityGate.onGyro` / `onLinearAccel`).

## Why LINEAR acceleration (not raw accelerometer)

Raw `TYPE_ACCELEROMETER` reads ~1 g at rest, so `|raw| < 0.15 g` would **never**
pass and the gate would never open. The 0.15 g check uses gravity-removed
`TYPE_LINEAR_ACCELERATION`. On devices lacking it, the manager falls back to
`TYPE_ACCELEROMETER` with a dt-aware low-pass **gravity estimator**
(`GravityEstimator`, τ ≈ 0.5 s): it tracks gravity slowly and subtracts it to
approximate linear acceleration (first sample assumed pure gravity → linear ≈ 0).
Approximate vs a hardware linear-accel sensor, but correct enough to gate 0.15 g.

## dt-aware dwell

The 250 ms is measured from **sensor timestamps**, not a sample count or wall
clock (the rate is best-effort/variable). When the combined condition first holds,
the start timestamp is recorded; STABLE fires once `now − start ≥ dwellMs`. Any
break in the condition — or an inter-sample gap beyond `gapResetNs` (default
500 ms: pause/resume, dropped run) — **resets** the dwell, so no false STABLE is
emitted across a gap. A brief motion spike during the dwell resets the timer; a
fresh continuous 250 ms is then required.

## Debounced output (transitions only)

State and triggers are emitted **on transitions**, never per sample.

```
onListen({ gyroThresh?, accelThresh? (g), dwellMs? }) → register, start evaluating
onCancel()                                            → unregister, stop

State (on flip):    { type:"state", stable:bool, gyroMag, linAccelMag, timestampNs }
Trigger (on enter): { type:"trigger", event:"stable", timestampNs }   // auto-capture
```

Entry is debounced by the 250 ms dwell (no exit hysteresis added — the dwell
already prevents entry flicker; add separate exit thresholds later if exit flicker
proves a concern). `timestampNs` is the camera-aligned CLOCK_MONOTONIC value
(converted via the IMU task's offset, consistent across sensor tasks); the dwell
itself uses deltas, so the domain is immaterial to it.

## Configurable thresholds

`gyroThresh` (rad/s), `accelThresh` (g), `dwellMs` are passed on listen and
validated in `StabilityConfig.build` — missing/non-finite/non-positive thresholds
and negative dwell fall back to the defaults (0.8, 0.15 g, 250 ms). The Flutter
caller may source these from P1 `GET /remote-config` "thresholds"; that wiring is
the caller's, kept out of this native gate.

## Threading / lifecycle / availability

- Sensor callbacks run on a dedicated `HandlerThread` (`stability-gate`);
  transitions are marshalled to the **main thread** for the EventSink.
- Registered on listen, unregistered on cancel and on background (`onHostPause`);
  re-registered on foreground only if still subscribed. The dwell + gravity
  estimate are **reset** on every (re)registration (no stale carry across a pause).
  The HandlerThread is quit on `dispose`.
- If the gyroscope or any usable accelerometer is absent, the stream raises
  `STABILITY_UNAVAILABLE` (naming the missing sensor) rather than silently never
  triggering.

## Pieces

| Layer | File | Role |
|-------|------|------|
| Native | `android/.../sensors/StabilityGate.kt` | Pure: `StabilityMath` (magnitude, g→m/s²), `GravityEstimator` (fallback), `StabilityConfig` (validate/convert), `StabilityGate` (dt-aware dwell state machine). JVM-testable. |
| Native | `android/.../sensors/StabilityStreamManager.kt` | Registers gyro + linear-accel (accelerometer+gravity fallback), off-main compute, on-main transition emit, lifecycle, availability error. |
| Native | `android/.../MainActivity.kt` | Registers the channel; wires host pause/resume/destroy. |
| Dart | `lib/platform/stability_channel.dart` | `StabilityEvent` (state/trigger), `StabilityGateStream` (`events` / `triggers`, thresholds). |

## Tests

- `android/.../test/.../sensors/StabilityGateTest.kt` — JVM: g→m/s² conversion,
  config defaults/validation, gravity fallback (rest≈0 / motion detected), and the
  dwell machine (stable-after-250ms-not-before, motion-spike reset, AND of both
  sensors, most-recent-of-each, rate-independent dwell, leaving-stable, large-gap
  reset, strict boundary, reset).
- `test/stability/stability_channel_test.dart` — event parsing (state/trigger,
  malformed) and the stream (thresholds forwarded, mapping/filtering, `triggers()`,
  `STABILITY_UNAVAILABLE` propagation).

On-device acceptance (STABLE within ~250 ms when still with `linAccelMag`≈0 proving
linear accel is used; raw-accel-never-passes demonstration; spike resets; rotational-
vs-translational-only stay unstable; steady-vs-throttled dwell; pause/resume reset;
linear-accel-absent fallback; off-main profiling) is verified manually per the
task's testing steps.
```
