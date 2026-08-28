# IMU rotation-vector stream (device orientation @ 50–100Hz)

Streams device orientation from Android's `TYPE_ROTATION_VECTOR` sensor to Flutter
over an `EventChannel`, with each sample timestamped in a clock domain that
**aligns with captured-frame timestamps**. This is the sensor source the later
pose/frame-fusion task joins to frames — this task produces the stream only (no
fusion, no other sensors, no camera/permission/lifecycle of the camera).

Channel: `com.mayasabhaxr.recapture/imu_rotation` (`AppConfig.channelImuRotation`).

## Clock domain — the correctness crux

| | Source | Android clock | Notes |
|--|--------|---------------|-------|
| Sensor sample | `SensorEvent.timestamp` | **CLOCK_BOOTTIME** (`elapsedRealtimeNanos`) | advances during deep sleep |
| Captured frame | `ImageProxy.imageInfo.timestamp` → sidecar `captureTimestampNs` | treated as **CLOCK_MONOTONIC** (`System.nanoTime`) | does **not** advance during deep sleep |

These two clocks differ by accumulated deep-sleep time. If the IMU stream and the
frames sat on different clocks, frame↔pose alignment would be silently wrong.

**Decision:** the IMU stream emits `timestampNs` **converted into the camera's
monotonic domain** (the same domain as a frame's `captureTimestampNs`), so the
fusion task can join the two directly without per-consumer reconciliation. The
camera task is left untouched (scope rule) — the timestamp source on a camera is a
device characteristic (`SENSOR_INFO_TIMESTAMP_SOURCE`) that isn't reliably settable
anyway, so we reconcile on the sensor side instead.

**Conversion:** at each (re)registration we sample a paired reading and store the
offset

```
monotonicMinusBootNs = System.nanoTime() − SystemClock.elapsedRealtimeNanos()   // ≤ 0
timestampNs          = SensorEvent.timestamp + monotonicMinusBootNs
```

During an **active foreground capture** there is no deep sleep (screen on, camera
open), so the offset is stable across the session and the conversion is exact.
The offset is re-measured whenever the listener re-registers (listen / foreground),
so any deep-sleep drift between sessions is reabsorbed. The pure conversion lives
in `ImuRotationMath.toMonotonicNs` (JVM-tested).

> Caveat: a minority of devices report the camera sensor timestamp on
> `TIMESTAMP_SOURCE_REALTIME` (boottime). On those, frames are already on the boot
> clock and the converted IMU timestamp would be offset by the deep-sleep delta.
> This app treats `captureTimestampNs` as monotonic (see
> `docs/camera/capture-metadata.md`); if a target device is found to be REALTIME,
> reconcile there. The paired-reading approach above makes the offset auditable.

## Sample contract

```
onListen(args: { rateHz?: 50..100 })  → registers the sensor, starts streaming
onCancel()                            → unregisters, stops

Sample: { q: [x, y, z, w], accuracy: int, timestampNs: long }
```

- `q` — a **unit quaternion** (`[x, y, z, w]`), sent as a native `double[]`
  (`Float64List` on the Dart side) for compact, allocation-light encoding. Older
  sensors that emit only `x,y,z` have `w` derived as `√(1 − (x²+y²+z²))`; the
  result is renormalized (`ImuRotationMath.quaternion`).
- `accuracy` — `SensorManager.SENSOR_STATUS_*` (0 unreliable … 3 high), the latest
  value from `onAccuracyChanged`, stamped on every sample. Rotation-vector accuracy
  tracks magnetometer calibration — low values mean unreliable yaw.
- `timestampNs` — camera-aligned (CLOCK_MONOTONIC), as above.

**Unavailable sensor** → the stream raises a `SENSOR_UNAVAILABLE` error
(`PlatformException` on the Dart side), never a silent empty stream.

## Rate

50–100Hz is a **best-effort hint** (`samplingPeriodUs = 1_000_000 / rateHz`):
100Hz → 10_000µs, 50Hz → 20_000µs. The OS may cap (thermal/limits), so consumers
**reconstruct cadence from `timestampNs`**, never from an assumed fixed rate. This
window is below the 200Hz `HIGH_SAMPLING_RATE_SENSORS` threshold, so **no manifest
permission is required** (and none is added).

## Threading

- Sensor callbacks are delivered on a dedicated `HandlerThread` (`imu-rotation`),
  never the main thread — even at 100Hz.
- Each sample is marshalled to the **platform main thread** before the
  `EventSink` is touched (the `EventChannel` sink contract requires this).

## Lifecycle (no leak / no battery drain)

| Event | Action |
|-------|--------|
| stream `onListen` | register the listener (if foregrounded + sensor present) |
| stream `onCancel` | unregister, drop the sink |
| Activity `onPause` (background) | unregister (keep "listening" state) |
| Activity `onResume` (foreground) | re-register **only if still subscribed** |
| Activity finish / `dispose` | unregister + quit the `HandlerThread` |

Registration is `@Synchronized` and guarded against double-register and
register-after-dispose. The host lifecycle is wired in `MainActivity`
(`onResume`/`onPause`/`onDestroy`).

## Sensor choice tradeoff

This task uses `TYPE_ROTATION_VECTOR` per spec — it fuses accel+gyro+**mag** for
absolute orientation including yaw, but is susceptible to magnetic interference
(reflected in `accuracy`). `TYPE_GAME_ROTATION_VECTOR` (accel+gyro, no mag) is
drift-free from magnetic interference but its yaw drifts over time, and is often
preferred for AR/capture. If the capture use case proves sensitive to magnetic
environments, switching the default sensor here is a one-line change — flagged for
the fusion task to confirm.

## Pieces

| Layer | File | Role |
|-------|------|------|
| Native | `android/.../sensors/ImuRotationMath.kt` | Pure: rate clamp + period, quaternion (incl. 3-value `w` derivation + normalize), boot→monotonic conversion. JVM-testable. |
| Native | `android/.../sensors/ImuRotationStreamManager.kt` | `EventChannel.StreamHandler` + `SensorEventListener`: HandlerThread delivery, main-thread sink, register/unregister lifecycle, availability error. |
| Native | `android/.../MainActivity.kt` | Registers the channel; wires host `onResume`/`onPause`/`onDestroy`. |
| Dart | `lib/platform/imu_rotation_channel.dart` | `ImuRotationSample` + `ImuRotationStream` (rate clamp, parse, filter, error). |

## Tests

- `android/.../test/.../sensors/ImuRotationMathTest.kt` — JVM unit tests: rate
  clamp/period, quaternion (4-value passthrough+normalize, 3-value `w`, degenerate
  → identity, empty), boot→monotonic conversion.
- `test/imu/imu_rotation_channel_test.dart` — sample parsing (Float64List + plain
  list, malformed shapes) and the stream wrapper (rate clamping forwarded on
  listen, sample mapping + junk filtering, `SENSOR_UNAVAILABLE` propagation).

On-device acceptance (steady ~50/100Hz stream, frame↔IMU timestamp comparability,
no main-thread jank/ANR at 100Hz, unregister on cancel/background verified via the
sensor service, accuracy changes under magnetic interference, absent-sensor report)
is verified manually per the task's testing steps.
```
