# Blur detection (variance of Laplacian @ 640px)

Computes a per-frame **sharpness score** (variance of the Laplacian) on a grayscale
image downscaled to 640px width, and a sharp/blurry **decision** against a
configurable threshold. Blurry frames ruin 3D/photogrammetry reconstruction; this
is the signal the capture flow uses to gate (capture only sharp) or post-filter
(reject blurry). This task provides the METRIC + decision only — the accept/reject
policy lives in the capture flow, and no reconstruction is done here.

Channel: `com.mayasabhaxr.recapture/blur` (`AppConfig.channelBlur`).

## Two correctness anchors

1. **Grayscale = the luma (Y) plane.** A CameraX `ImageAnalysis` frame is
   YUV_420_888; `plane[0]` IS grayscale — no YUV→RGB→gray conversion. But the plane
   is **padded**, so it MUST be read by `rowStride`/`pixelStride`; treating it as a
   contiguous `width×height` buffer reads garbage. (`BlurMetric.downscaleLuma`
   samples by stride.)
2. **Downscale to 640px width first.** The raw Laplacian variance scales with
   resolution, so a threshold tuned at one resolution is wrong at another.
   Normalizing every frame to 640px width (aspect preserved) makes **one** threshold
   valid across source resolutions/devices. Sources ≤640px wide are NOT upscaled
   (that would inflate the metric).

## The metric

```
gray = downscaleLuma(Yplane, …strides…, targetWidth = 640)   // nearest, center-sampled
L    = 3×3 Laplacian [[0,1,0],[1,-4,1],[0,1,0]] over gray's interior
score = var(L) = mean(L²) − mean(L)²        // higher = sharper
sharp = score >= threshold                  // inclusive
```

Pure Kotlin (`BlurMetric`) — no OpenCV (not a dependency); the convolution over a
640px buffer is well within frame budget. A uniform/low-texture image yields ~0
variance → classified blurry (expected).

## Threshold (configurable, content-sensitive)

Default `BlurMetric.DEFAULT_THRESHOLD = 100.0` at 640px width. The ABSOLUTE value
is **content-sensitive**: low-texture, dark, or uniform scenes score low even when
in focus — so this is a tunable default, **not** a universal constant. Configured
per subscription via the channel's `blurThreshold` listen arg
(`BlurAnalysisStream.results(blurThreshold:)`); the Flutter caller may source it
from P1 `GET /remote-config` "thresholds" (that wiring is the caller's).

## Real-time path (ImageAnalysis)

`BlurAnalysisManager` owns an `ImageAnalysis` use case bound into the SAME CameraX
session as Preview + ImageCapture (pulled by `CameraPreviewManager` at bind, like
the capture use case). Per the classic CameraX pitfalls:

- **`STRATEGY_KEEP_ONLY_LATEST`** — slow processing DROPS frames, never queues/stalls.
- The analyzer runs on its **own executor** (off the main thread); the emit is
  marshalled to the **main thread** for the EventSink.
- Every `ImageProxy` is **`close()`d in a `finally`** (an unclosed proxy stalls the
  analyzer — a classic freeze). When nobody is subscribed, frames are drained
  cheaply (closed without computing).

**Use-case-limit fallback:** Preview + ImageCapture + ImageAnalysis is a
3-use-case combination not guaranteed on every device. `CameraPreviewManager.bindUseCases`
tries the full set and, if rejected (`IllegalArgumentException`), rebinds without
analysis — preview/capture always survive; blur analysis is simply a no-op on such
devices.

## Output + frame association

```
{ sharpnessScore: double, sharp: bool, width: 640, height: int, timestampNs: long, frameIndex: long }
```

`timestampNs` is the frame's sensor timestamp — the SAME camera clock as a captured
frame's `captureTimestampNs` — so the capture flow can associate the score with the
right frame (or record it in the sidecar). `frameIndex` is a monotonic analyzer
counter; gaps indicate frames dropped under load (keep-only-latest).

> Sidecar recording (capture path): the score shares the capture clock, so the
> capture/metadata flow can join on `timestampNs`. Wiring it into the sidecar is
> left to that flow; this task streams the signal.

> Shared pass: `BlurAnalysisManager` reuses this one 640px downscale to also compute
> the **exposure** mean-luminance signal on a parallel channel — one frame pass, two
> metrics. See docs/camera/exposure-check.md.

## Pieces

| Layer | File | Role |
|-------|------|------|
| Native | `android/.../camera/BlurMetric.kt` | Pure: stride-correct luma downscale to 640px, 3×3 Laplacian variance, analyze→score+decision. JVM-testable. |
| Native | `android/.../camera/BlurAnalysisManager.kt` | Owns the ImageAnalysis use case + analyzer (keep-only-latest, off-main, always-close); streams results; threshold config. |
| Native | `android/.../camera/CameraPreviewManager.kt` | Binds the analysis use case into the shared session with graceful 3-use-case fallback (`bindUseCases`). |
| Native | `android/.../MainActivity.kt` | Wires the analysis provider + registers the blur EventChannel. |
| Dart | `lib/platform/blur_channel.dart` | `BlurResult` + `BlurAnalysisStream` (threshold). |

## Tests

- `android/.../test/.../camera/BlurMetricTest.kt` — JVM: padded-stride + pixelStride
  reads, downscale-to-640 aspect + no-upscale, variance (uniform=0, checkerboard
  high, sharp>blurred edge), **resolution-independence** (same scene at 1× vs 2×
  → identical 640px score), and the threshold decision (inclusive `>=`).
- `test/blur/blur_channel_test.dart` — result parsing (malformed) and the stream
  (threshold forwarded/omitted, mapping + junk filtering).

On-device acceptance (sharp-vs-blurred same scene, padded-stride device correctness,
resolution-independence across 1080p vs 4000px, low-texture content sensitivity,
analyzer frame-drop under artificial slowdown with ImageProxy always closed,
score↔frame association, off-main profiling) is verified manually per the task's
testing steps.
```
