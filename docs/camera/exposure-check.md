# Exposure check (mean luminance, dark/ok/bright)

Computes a per-frame **mean luminance** (average brightness on the 0–255 scale) and
warns when the frame is too dark or too bright: `< 40` → DARK, `> 220` → BRIGHT,
`40–220` → OK. A frame-quality signal **parallel to the blur check** — it WARNS
(so the capture flow / UI can prompt "too dark"/"too bright" while the user adjusts)
and it does **not** reject frames and does **not** change camera exposure settings
(that is the focus/exposure-lock task; this only measures).

Channel: `com.mayasabhaxr.recapture/exposure` (`AppConfig.channelExposure`).

## Two correctness anchors

1. **The Y (luma) plane IS luminance.** A CameraX `ImageAnalysis` frame is
   YUV_420_888; the 8-bit `plane[0]` values are luminance directly — no YUV→RGB
   conversion. The plane is **padded**, so it MUST be read by `rowStride`/
   `pixelStride` (handled by `BlurMetric.downscaleLuma`).
2. **Mean luminance is scale-independent.** Averaging does not change with
   resolution or subsampling, so the 40/220 thresholds stay valid regardless of the
   downscale — and this **shares the blur task's single downscaled-luma pass**
   instead of a second traversal.

## Shared frame pass (no duplicate traversal)

`BlurAnalysisManager` owns the one `ImageAnalysis` use case + analyzer. Per frame it
downscales the Y plane to 640px **once** (`BlurMetric.downscaleLuma`) and computes
**both** metrics from that single `GrayImage` buffer:

```
gray = downscaleLuma(Yplane, …strides…, 640)   // ONE stride-correct pass
blur     = laplacianVariance(gray)             // BlurMetric  → sharp/blurry
exposure = mean(gray)                          // ExposureMetric → dark/ok/bright
```

Frames are processed when **either** channel is subscribed; both results carry the
SAME `timestampNs` and `frameIndex`, so a consumer can join the exposure band to the
same frame as the blur score. This mirrors the IMU manager's parallel
raw/orientation channels sharing one sensor registration.

## The metric + bands

```
mean = sum(luma) / count        // in [0, 255], scale-independent
band = mean < darkBelow   -> DARK    // < 40, warn
       mean > brightAbove -> BRIGHT  // > 220, warn
       else               -> OK      // 40..220 inclusive (both edges are OK)
```

Boundary semantics (per spec): `< darkBelow` → DARK; `> brightAbove` → BRIGHT;
otherwise OK — so **exactly 40 and exactly 220 are OK**. Both DARK and BRIGHT are
**WARN** states, never reject. A non-finite mean (an empty/undeterminable frame) is
reported as an explicit `unknown` band — never silently OK.

## Thresholds (configurable, validated, remote-config-tunable)

Defaults `darkBelow = 40`, `brightAbove = 220` on the 0–255 scale. Configured per
subscription via the channel's `darkBelow`/`brightAbove` listen args
(`ExposureAnalysisStream.results(darkBelow:, brightAbove:)`); the Flutter caller may
source them from P1 `GET /remote-config` "thresholds" (that wiring is the caller's).
Validation (`ExposureThresholdPolicy.validated`): a non-finite value falls back to
its per-field default; a non-separated pair (`darkBelow >= brightAbove`, which would
leave no OK band) falls back to BOTH defaults — note equality is **not** allowed here
(unlike the blur policy's empty-WARN case), because DARK and BRIGHT must be strictly
separated by a non-empty OK band. Updates apply to subsequent frames; the active
thresholds ride along on every result.

## Output + frame association

```
{ meanLuminance: double, band: "dark"|"ok"|"bright"|"unknown",
  darkBelow: double, brightAbove: double,
  width: 640, height: int, timestampNs: long, frameIndex: long }
```

`timestampNs` is the frame's sensor timestamp (the SAME camera clock as a captured
frame's `captureTimestampNs`, and the same value as the blur stream for that frame),
for associating the mean with the right frame or recording it in the sidecar.

## Known limitation (mean vs histogram)

The MEAN can read OK on a high-contrast scene that clips in BOTH the shadows and the
highlights (the bright and dark regions average to mid-grey). This is an inherent
limitation of a single mean — documented, not papered over. Histogram/clipping
analysis is a possible future refinement, out of scope here.

## Real-time path

Same analyzer as the blur check: `STRATEGY_KEEP_ONLY_LATEST` (slow processing DROPS
frames, never stalls), off the main thread, every `ImageProxy` `close()`d in a
`finally`, and when nobody is subscribed frames are drained cheaply (closed without
computing).

## Pieces

| Layer | File | Role |
|-------|------|------|
| Native | `android/.../camera/ExposureMetric.kt` | Pure: mean of the (shared) downscaled luma `GrayImage`. JVM-testable. |
| Native | `android/.../camera/ExposureThresholdPolicy.kt` | Pure: dark/ok/bright banding, configurable + validated thresholds. JVM-testable. |
| Native | `android/.../camera/BlurAnalysisManager.kt` | Shares the one downscale pass; emits exposure on the parallel `exposureHandler`. |
| Native | `android/.../MainActivity.kt` | Registers the exposure EventChannel (`blurAnalysis.exposureHandler`). |
| Dart | `lib/platform/exposure_policy.dart` | `ExposureBand` + `ExposureThresholdPolicy` (mirror). |
| Dart | `lib/platform/exposure_channel.dart` | `ExposureResult` + `ExposureAnalysisStream` (thresholds). |

## Tests

- `android/.../test/.../camera/ExposureMetricTest.kt` — JVM: correct averaging
  (dark/mid/bright, unsigned bytes), scale-independence (1× vs 2× → identical mean),
  stride-padding ignored, empty-frame NaN guard.
- `android/.../test/.../camera/ExposureThresholdPolicyTest.kt` — JVM: boundary table
  (40/220 → OK), configurable/validated (invalid AND equal → defaults), runtime
  update, non-finite → null (unknown).
- `test/exposure/exposure_policy_test.dart` — Dart mirror of the banding/validation.
- `test/exposure/exposure_channel_test.dart` — result parsing (malformed, native vs
  local band, unknown) and the stream (thresholds forwarded/omitted, mapping +
  filtering).

On-device acceptance (dark/mid/bright scenes, boundary precision, padded-stride
device correctness, shared-pass profiling, high-contrast clipping limitation,
analyzer frame-drop with `ImageProxy` always closed, band↔frame association) is
verified manually per the task's testing steps.
