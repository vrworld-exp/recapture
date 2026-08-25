# Low-pass orientation filter (smoothed yaw/pitch/roll)

Smooths the IMU rotation-vector orientation to reduce high-frequency jitter,
producing stable yaw/pitch/roll (+ a smoothed quaternion) for a UI capture
level/orientation guide. Consumes the IMU stream (see
`docs/camera/imu-rotation-stream.md`); registers **no** sensors and does **no**
pose/frame fusion.

Channel: `com.mayasabhaxr.recapture/imu_orientation` (`AppConfig.channelImuOrientation`).

## Why quaternion-domain (not scalar Euler low-pass)

Low-passing yaw/pitch/roll as independent scalars is **wrong**: Euler angles wrap
(averaging 359° and 1° gives 180° — the opposite direction) and gimbal-lock near
pitch ±90°. So the filter smooths in the **quaternion domain** and derives YPR from
the smoothed quaternion afterwards.

```
smoothedQ ← nlerp(smoothedQ, qNew, α)        // shortest-path, then normalize
yaw,pitch,roll ← toEuler(smoothedQ)          // SensorManager.getOrientation convention
```

- **Shortest path / double-cover:** `q` and `−q` are the same rotation. Before the
  blend, if `dot(smoothedQ, qNew) < 0` the new sample's sign is flipped, so the
  blend never takes the long way (no jerk on a sign flip). This also keeps the
  blend ≤90° apart, so nlerp is never antipodal/degenerate.
- **nlerp, not slerp:** at 50–100 Hz the per-sample step is tiny, where nlerp ≈
  slerp at a fraction of the cost. Each step renormalizes (no numeric drift).

## dt-aware time constant

The IMU rate is best-effort and variable, so a fixed blend factor would smooth
differently at 50 vs 100 Hz. Instead the blend factor is **time-constant based**:

```
α = 1 − exp(−dt/τ)     dt = timestampNs − prevTimestampNs   (clamped to [0,1])
```

This makes smoothing **rate-independent**: the retained fraction over a given
elapsed time is the same however `dt` is subdivided. `τ` is the smoothing time
constant — larger = smoother but laggier, smaller = more responsive but noisier.

- **Default τ = 100 ms** (`OrientationFilter.DEFAULT_TAU_NS`) — tuned smooth-but-not-
  laggy for a live guide. Configurable per subscription via the channel's listen
  arg `tauMs` (`ImuOrientationStream.orientation(tauMs: …)`). Could later be driven
  by remote config; that wiring is out of scope here.
- **Extremes:** `τ = 0` → `α = 1` (passthrough, no smoothing); very large `τ` →
  `α ≈ 0` (heavy smoothing). Both are NaN-free.

## First-sample / gap policy

| Condition | Behavior |
|-----------|----------|
| First sample (or after `reset()`) | `smoothedQ = sample` — no spurious blend |
| `dt > gapResetNs` (default **500 ms**: dropped samples / pause-resume) | re-initialize to the new sample (no snap *through* a long-stale orientation) |
| Non-monotonic `dt < 0` | re-initialize |
| `dt ≤ 0` mid-stream (same timestamp) | `α = 0` (no update) |

The filter is `reset()` on every fresh subscription and on each sensor
(re)registration (resume), so it never blends across a background gap.

## Output contract

```
Input  (from IMU): { q:[x,y,z,w], accuracy, timestampNs }
Output (smoothed): { yaw, pitch, roll, q:[x,y,z,w], timestampNs }
```

- `yaw`/`pitch`/`roll` — **radians**, matching `SensorManager.getOrientation`
  (azimuth, pitch, roll). The Dart `SmoothedOrientation` exposes `*Degrees` getters.
  Note the convention's sign: a +θ rotation about an axis yields −θ in the
  corresponding angle (this is reproduced exactly from getOrientation).
- `q` — the smoothed unit quaternion (`double[]` → `Float64List`).
- `timestampNs` — **unchanged** from the source sample (CLOCK_MONOTONIC), so the
  smoothed output stays joinable to captured frames.

## Transport & threading

A **parallel** EventChannel alongside the raw IMU stream (matching that task's
transport), both served by `ImuRotationStreamManager`, which owns the single sensor
registration (the IMU task owns the sensor — smoothing does not re-register). The
sensor is registered when **either** channel is subscribed and dropped only when
both are gone. The filter runs on the IMU **HandlerThread** (a few quaternion ops
per sample, minimal allocation); only the emit is marshalled to the **main thread**
for the EventSink (per the IMU contract). The raw stream is never altered.

## Pieces

| Layer | File | Role |
|-------|------|------|
| Native | `android/.../sensors/OrientationFilter.kt` | Pure `OrientationMath` (alpha, double-cover nlerp, normalize, quaternion→Euler) + stateful `OrientationFilter` + `SmoothedOrientation`. JVM-testable. |
| Native | `android/.../sensors/ImuRotationStreamManager.kt` | Parallel orientation channel + filter wiring; dual-sink registration; off-main filter, on-main emit. |
| Native | `android/.../MainActivity.kt` | Registers the `imu_orientation` EventChannel. |
| Dart | `lib/platform/imu_rotation_channel.dart` | `SmoothedOrientation` (+ degree getters) and `ImuOrientationStream` (rateHz + tauMs). |

## Tests

- `android/.../test/.../sensors/OrientationFilterTest.kt` — JVM: alpha (passthrough/
  no-update/formula/rate-independent-composition), double-cover nlerp + aliasing,
  quaternion→Euler (identity, gimbal ±90° stability), and the filter (first-sample
  init, steady-target convergence without overshoot, **yaw wraparound no-180°-
  artifact**, large-gap re-init, τ→0 passthrough, huge-τ barely-moves, **rate-
  independent smoothing**, unit-norm over a long run).
- `test/imu/imu_rotation_channel_test.dart` — `SmoothedOrientation` parsing (full,
  degree conversion, missing-q default, malformed) and `ImuOrientationStream`
  (clamped rateHz + tauMs forwarded, sample mapping + junk filtering).

On-device acceptance (visible jitter reduction vs raw, no wraparound artifact on a
live yaw sweep, pitch ±90° stability, no jerk on sign flips, steady-vs-throttled
rate comparison, no 100 Hz jank, off-main compute / on-main emit) is verified
manually per the task's testing steps.
```
