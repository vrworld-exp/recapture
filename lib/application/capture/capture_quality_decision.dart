// lib/application/capture/capture_quality_decision.dart
//
// The SHARED, pure quality-decision core used by BOTH the manual capture path
// and the auto-capture trigger. It combines the two per-frame quality bands —
// blur (BlurThresholdPolicy → BlurBand, the only check that can REJECT) and
// exposure (ExposureThresholdPolicy → ExposureBand, WARN-only) — into one
// overall verdict, WORST-OF:
//
//   blur REJECT                         → reject   (too blurry is disqualifying)
//   else blur WARN  OR  exposure ≠ OK   → warn     (borderline / dark / bright / unknown)
//   else (blur ACCEPT and exposure OK)  → accept
//
// It does NOT compute scores (native) or classify bands (blur_policy /
// exposure_policy own that) — it composes their outputs. The verdict type is the
// EXISTING [CaptureVerdict] (accepted/warn/reject) so it flows straight into the
// post-shot toast and the auto-capture controller's quality hook — no parallel
// enum. The two paths share THIS decision; they differ only in what they DO with
// a WARN (manual asks the user keep/retake; auto applies a default).
import '../../domain/entities/capture_evaluation.dart';
import '../../platform/blur_policy.dart';
import '../../platform/exposure_policy.dart';

/// The two per-frame quality bands for one captured still. [ExposureBand.unknown]
/// (an indeterminable mean) is a non-OK, fail-safe-to-WARN value — never silently
/// accepted.
class CaptureQuality {
  const CaptureQuality({required this.blur, required this.exposure});

  final BlurBand blur;
  final ExposureBand exposure;

  /// The worst-of overall verdict for this frame.
  CaptureVerdict get verdict => evaluateCaptureQuality(blur, exposure);

  @override
  bool operator ==(Object other) =>
      other is CaptureQuality &&
      other.blur == blur &&
      other.exposure == exposure;

  @override
  int get hashCode => Object.hash(blur, exposure);

  @override
  String toString() => 'CaptureQuality(blur: $blur, exposure: $exposure)';
}

/// Worst-of combination of [blur] and [exposure] into an overall verdict. Pure,
/// deterministic, exhaustive. Exposure is warn-only (its DARK/BRIGHT/UNKNOWN all
/// warn, never reject), so only [BlurBand.reject] yields a REJECT.
CaptureVerdict evaluateCaptureQuality(BlurBand blur, ExposureBand exposure) {
  if (blur == BlurBand.reject) return CaptureVerdict.reject;
  if (blur == BlurBand.warn || exposure != ExposureBand.ok) {
    return CaptureVerdict.warn;
  }
  return CaptureVerdict.accepted;
}
