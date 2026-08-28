# Capture resolution & JPEG-quality policy

Governs the **resolution and JPEG quality** of captured stills so frames are
CONSISTENT within a session and PREDICTABLE across devices. Photogrammetry needs
known, uniform input dimensions; CameraX otherwise picks a per-device default size.

Scope is **sizing/encoding only** — this does not trigger captures (burst task),
manage permissions, or own the session lifecycle (preview/P2).

## Key constraint: bind-time, not mid-session

A CameraX `ResolutionSelector` is consumed when the `ImageCapture` use case is
**bound**. "Configurable" therefore means *configured before a bind*: a policy
change is **staged** and realized on the **next bind**, which the preview/session
task performs (`CameraPreviewManager` rebinds Preview + ImageCapture together).
It never swaps the live use case under a running session — so every frame in a
session shares one resolution + quality automatically.

UX implication: changing capture resolution happens **between sessions**, not
during one. A reconfigure mid-session is accepted and acknowledged, but takes
effect only when the session task next rebinds.

## The policy

| Field | Meaning |
|-------|---------|
| `targetWidth` + `targetHeight` | Exact target (supply both), normalised to landscape. |
| `targetLongEdge` | Long edge in px (used when exact size is absent); paired with `aspectRatio`. |
| `aspectRatio` | `4:3` or `16:9` — **MUST match preview/analysis** (no FOV mismatch). |
| `fallbackRule` | `closest-higher-then-lower` (default) \| `closest-lower` \| `none`/`exact`. |
| `jpegQuality` | 1..100 (clamped); default 90. |

Defaults (nothing supplied): 4:3, long-edge 3000, quality 90,
closest-higher-then-lower. Invalid input (unknown aspect/fallback, partial or
non-positive size, non-positive long edge) is **rejected** with `INVALID_ARGS`
and the prior policy stands; quality is clamped rather than rejected (fail-safe).

## How a target maps to a supported size (deterministic)

The exact target may be unsupported. Mapping is delegated to CameraX's
`ResolutionStrategy` (built from the target bound size + `fallbackRule`), then a
`ResolutionFilter` orders the surviving candidates by **closeness of the long edge
to the intended long edge** so the long-edge intent is honoured predictably across
devices. The ordering is a *total order* (`ResolutionMath.orderByLongEdge`: long-edge
distance → larger long edge → larger area → larger width → larger height), so the
same device always yields the same choice. Targets above/below device limits are
clamped by the strategy. The **actual** chosen size is reported, never silently
diverged from the target.

## Aspect-ratio parity with preview

`CameraCaptureManager` pushes the policy's aspect ratio to
`CameraPreviewManager.captureAspectRatio` (default 4:3); both the Preview and the
ImageCapture build an `AspectRatioStrategy` for the same ratio, so the streams
share one FOV. The Preview re-reads it at the next bind, matching the capture
stream that lands on the same bind.

## Reporting

`getActiveCaptureResolution()` →
`{ width, height, jpegQuality, aspectRatio, target: { width, height, longEdge }, fellBack, bound }`

- When `bound`, `width`/`height` are the ACTUAL output size read from the bound
  `ImageCapture.resolutionInfo`, and `fellBack` is true if it diverged from the target.
- Before the first bind, `bound` is false and `width`/`height` report the resolved
  target (intent); `fellBack` is false (no actual size exists yet).

## Pieces

| Layer | File | Role |
|-------|------|------|
| Native | `android/.../camera/CaptureResolutionPolicy.kt` | Policy value/validation, `ResolutionSelector` builder, pure `ResolutionMath` (unit-testable). |
| Native | `android/.../camera/CameraCaptureManager.kt` | Builds the `ImageCapture` from the policy at bind (`useCaseForBind`); `configureCaptureResolution` / `getActiveCaptureResolution`. |
| Native | `android/.../camera/CameraPreviewManager.kt` | Pulls the capture use case per bind; matches Preview aspect ratio. |
| Native host | `android/.../MainActivity.kt` | Routes the two new channel methods; wires the use-case provider + aspect callback. |
| Dart | `lib/platform/method_channels.dart` | `CaptureResolutionPolicy`, `ActiveCaptureResolution`, `CaptureChannel.configure*/getActive*`. |

## Channel `com.mayasabhaxr.recapture/capture`

| Method | Args | Returns |
|--------|------|---------|
| `configureCaptureResolution` | policy map | `{ accepted, appliesOnNextBind, target, jpegQuality, aspectRatio }` or `INVALID_ARGS` |
| `getActiveCaptureResolution` | — | `{ width, height, jpegQuality, aspectRatio, target, fellBack, bound }` |

## Tests

- `android/.../test/.../camera/CaptureResolutionPolicyTest.kt` — JVM unit tests for
  deterministic long-edge ordering, `Dimensions` helpers, validation/defaults,
  clamping, and `fellBack` reporting.
- `test/capture/capture_channel_test.dart` — Dart wrapper: policy map forwarding,
  exact-size vs long-edge, `INVALID_ARGS → false`, actual-resolution parsing,
  graceful degradation.

On-device acceptance (multi-device fallback, EXIF orientation across frames,
all-frames-identical-resolution) is verified manually per the task's testing steps.
