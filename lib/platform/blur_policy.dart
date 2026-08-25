// lib/platform/blur_policy.dart
//
// Three-band classification policy for the blur/sharpness score (variance of
// Laplacian @ 640px, from the blur-detection task): REJECT (<rejectBelow),
// WARN (rejectBelow..acceptAbove inclusive), ACCEPT (>acceptAbove). Mirrors the
// native BlurThresholdPolicy so the capture flow / UI can classify a score from
// any source (e.g. a captured frame's sidecar) consistently with the live stream.
//
// This is the POLICY meaning only — the concrete capture action (skip / keep /
// prompt) is wired by the capture flow, not here.
import 'package:flutter/foundation.dart';

/// The actionable band a sharpness score falls into.
enum BlurBand {
  /// Too blurry — don't use the frame.
  reject,

  /// Borderline — usable but flagged; the capture flow decides.
  warn,

  /// Sharp enough — use the frame.
  accept;

  /// Parses the native wire form (`reject`/`warn`/`accept`); null if unknown.
  static BlurBand? fromWire(Object? wire) => switch (wire) {
        'reject' => BlurBand.reject,
        'warn' => BlurBand.warn,
        'accept' => BlurBand.accept,
        _ => null,
      };
}

/// Configurable, validated thresholds + the classification.
@immutable
class BlurThresholdPolicy {
  const BlurThresholdPolicy._(this.rejectBelow, this.acceptAbove);

  /// Builds a validated policy. A non-finite input falls back to the per-field
  /// default; an inverted pair (`rejectBelow > acceptAbove`) falls back to BOTH
  /// defaults. `rejectBelow == acceptAbove` is allowed (empty WARN → binary).
  factory BlurThresholdPolicy({double? rejectBelow, double? acceptAbove}) {
    final r = (rejectBelow != null && rejectBelow.isFinite)
        ? rejectBelow
        : defaultRejectBelow;
    final a = (acceptAbove != null && acceptAbove.isFinite)
        ? acceptAbove
        : defaultAcceptAbove;
    return r <= a
        ? BlurThresholdPolicy._(r, a)
        : const BlurThresholdPolicy._(defaultRejectBelow, defaultAcceptAbove);
  }

  static const double defaultRejectBelow = 40;
  static const double defaultAcceptAbove = 80;

  static const BlurThresholdPolicy defaults =
      BlurThresholdPolicy._(defaultRejectBelow, defaultAcceptAbove);

  final double rejectBelow;
  final double acceptAbove;

  /// `score < rejectBelow` → reject; `score > acceptAbove` → accept; else warn
  /// (so exactly [rejectBelow] and [acceptAbove] are warn). Non-finite fails safe
  /// to reject — never accept.
  BlurBand classify(double score) {
    if (!score.isFinite) return BlurBand.reject;
    if (score < rejectBelow) return BlurBand.reject;
    if (score > acceptAbove) return BlurBand.accept;
    return BlurBand.warn;
  }
}
