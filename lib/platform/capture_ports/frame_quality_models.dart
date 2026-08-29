// lib/platform/capture_ports/frame_quality_models.dart
//
// The per-frame quality result types, moved out of lib/platform/blur_channel.dart
// and lib/platform/exposure_channel.dart (both of which re-export them) so the
// port interface and both implementations can share them without an import
// cycle. Shapes, units and the local-classification fallback are unchanged.
//
// The units matter more than usual here: `sharpnessScore` is a
// variance-of-Laplacian measured at a NORMALIZED 640px width and
// `meanLuminance` is a 0-255 average, on both platforms. The web analyzer
// normalizes to the same 640px width for exactly that reason — so the existing
// BlurThresholdPolicy / ExposureThresholdPolicy constants, and
// CaptureQualityDecision above them, keep discriminating without a web-specific
// threshold set.
import 'package:flutter/foundation.dart';

import '../blur_policy.dart';
import '../exposure_policy.dart';

/// One per-frame blur result.
@immutable
class BlurResult {
  const BlurResult({
    required this.sharpnessScore,
    required this.sharp,
    required this.band,
    required this.rejectBelow,
    required this.acceptAbove,
    required this.width,
    required this.height,
    required this.timestampNs,
    required this.frameIndex,
  });

  /// Variance of the Laplacian at [width]px (640). Higher = sharper. The absolute
  /// value is content-sensitive (low-texture/dark scenes score low even in focus).
  final double sharpnessScore;

  /// `sharpnessScore >= threshold` — sharp enough per the (single) configured
  /// threshold. For three-band capture decisions prefer [band].
  final bool sharp;

  /// Three-band policy classification (reject/warn/accept) of [sharpnessScore].
  /// reject = don't use; warn = borderline/flag; accept = use. The concrete
  /// capture action is the capture flow's, not this transport's.
  final BlurBand band;

  /// The active band thresholds the native side used for [band].
  final double rejectBelow;
  final double acceptAbove;

  /// The normalized analysis width (640) and the aspect-preserved height.
  final int width;
  final int height;

  /// The frame's sensor timestamp (same camera clock as a captured frame's
  /// `captureTimestampNs`), for associating the score with the right frame.
  final int timestampNs;

  /// Monotonic analyzer frame counter (gaps indicate dropped frames under load).
  final int frameIndex;

  /// Parses a native event map; returns null for an unknown/malformed shape.
  static BlurResult? fromEvent(Object? event) {
    if (event is! Map) return null;
    final score = (event['sharpnessScore'] as num?)?.toDouble();
    final sharp = event['sharp'];
    if (score == null || sharp is! bool) return null;
    final rejectBelow = (event['rejectBelow'] as num?)?.toDouble() ??
        BlurThresholdPolicy.defaultRejectBelow;
    final acceptAbove = (event['acceptAbove'] as num?)?.toDouble() ??
        BlurThresholdPolicy.defaultAcceptAbove;
    // Prefer the native band; if absent, classify locally with the same policy
    // (so the band is always present and consistent).
    final band = BlurBand.fromWire(event['band']) ??
        BlurThresholdPolicy(rejectBelow: rejectBelow, acceptAbove: acceptAbove)
            .classify(score);
    return BlurResult(
      sharpnessScore: score,
      sharp: sharp,
      band: band,
      rejectBelow: rejectBelow,
      acceptAbove: acceptAbove,
      width: (event['width'] as num?)?.toInt() ?? 0,
      height: (event['height'] as num?)?.toInt() ?? 0,
      timestampNs: (event['timestampNs'] as num?)?.toInt() ?? 0,
      frameIndex: (event['frameIndex'] as num?)?.toInt() ?? 0,
    );
  }
}

/// One per-frame exposure result.
@immutable
class ExposureResult {
  const ExposureResult({
    required this.meanLuminance,
    required this.band,
    required this.darkBelow,
    required this.brightAbove,
    required this.width,
    required this.height,
    required this.timestampNs,
    required this.frameIndex,
  });

  /// Mean luminance of the frame in `[0, 255]` (scale-independent — the average of
  /// the 640px-downscaled Y plane). `NaN` for an undeterminable frame (then [band]
  /// is [ExposureBand.unknown]).
  final double meanLuminance;

  /// Three-band classification (dark/ok/bright) of [meanLuminance], or
  /// [ExposureBand.unknown]. Both dark and bright are WARN states ([ExposureBand.isWarning]).
  final ExposureBand band;

  /// The active band thresholds the native side used for [band].
  final double darkBelow;
  final double brightAbove;

  /// The normalized analysis width (640) and the aspect-preserved height (shared
  /// with the blur stream's frame).
  final int width;
  final int height;

  /// The frame's sensor timestamp (same camera clock as a captured frame's
  /// `captureTimestampNs`, and the SAME value as the blur stream for this frame),
  /// for associating the mean with the right frame.
  final int timestampNs;

  /// Monotonic analyzer frame counter, shared with the blur stream (gaps indicate
  /// dropped frames under load).
  final int frameIndex;

  /// Parses a native event map; returns null for an unknown/malformed shape.
  static ExposureResult? fromEvent(Object? event) {
    if (event is! Map) return null;
    final mean = (event['meanLuminance'] as num?)?.toDouble();
    if (mean == null) return null;
    final darkBelow = (event['darkBelow'] as num?)?.toDouble() ??
        ExposureThresholdPolicy.defaultDarkBelow;
    final brightAbove = (event['brightAbove'] as num?)?.toDouble() ??
        ExposureThresholdPolicy.defaultBrightAbove;
    // Prefer the native band; if absent/unrecognized, classify locally with the
    // same policy (so the band is always present and consistent).
    final band = ExposureBand.fromWire(event['band']) ??
        ExposureThresholdPolicy(darkBelow: darkBelow, brightAbove: brightAbove)
            .classify(mean);
    return ExposureResult(
      meanLuminance: mean,
      band: band,
      darkBelow: darkBelow,
      brightAbove: brightAbove,
      width: (event['width'] as num?)?.toInt() ?? 0,
      height: (event['height'] as num?)?.toInt() ?? 0,
      timestampNs: (event['timestampNs'] as num?)?.toInt() ?? 0,
      frameIndex: (event['frameIndex'] as num?)?.toInt() ?? 0,
    );
  }
}
