// lib/platform/capture_ports/frame_quality_port.dart
//
// PORT: "how sharp and how bright is the frame the user is pointing at".
//
// Blur and exposure are ONE port because they are one native pass: the Android
// analyzer downscales each ImageAnalysis frame to 640px width once and computes
// both metrics over that single grayscale buffer, which is why a blur result and
// an exposure result for the same frame share a `timestampNs` and a
// `frameIndex`. Splitting them here would have let the web side drift into two
// independent passes with unrelated frame indices.
//
// Native reads the `blur` / `exposure` EventChannels. Web draws the live
// `<video>` into a canvas at the SAME 640px normalization width, converts RGBA
// to Rec.601 luma, and runs the ported metrics (frame_quality_math.dart) — so
// scores land on the scale the existing thresholds were tuned against.
import 'frame_quality_models.dart';

export 'frame_quality_models.dart';

/// Per-frame quality signals for the capture HUD and the quality gate.
abstract interface class FrameQualityPort {
  /// Per-frame sharpness. [blurThreshold] is the single sharp/blurry cutoff;
  /// [rejectBelow]/[acceptAbove] are the three-band policy thresholds. Any
  /// omitted value uses the platform default.
  Stream<BlurResult> blur({
    double? blurThreshold,
    double? rejectBelow,
    double? acceptAbove,
  });

  /// Per-frame mean luminance (0–255) + dark/ok/bright band. Warn-only.
  Stream<ExposureResult> exposure({double? darkBelow, double? brightAbove});
}
