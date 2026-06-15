// lib/domain/entities/capture_config_validator.dart
//
// Pure Dart. Clamps/drops out-of-range values so a malformed or hostile remote
// config can never break capture. The result is always a valid, non-empty
// [CaptureConfig] — if nothing usable remains, it falls back to bundled bands.
import 'capture_config.dart';

/// Sanitizes a parsed config:
///   - drops bands with `segments <= 0` or (after clamping) `maxDegrees <= minDegrees`
///   - clamps band degrees into [0, 90] and segments into [1, 64]
///   - clamps thresholds: minSharpness [0, 1], minCoveragePct [0, 100],
///     maxTiltDeltaDeg [1, 45]
///   - if no valid bands remain, uses [CaptureConfig.bundledDefault] bands
CaptureConfig sanitizeCaptureConfig(CaptureConfig cfg) {
  final bands = <PitchBand>[];
  for (final b in cfg.pitchBands) {
    if (b.segments <= 0) continue; // drop degenerate band count
    final min = b.minDegrees.clamp(0.0, 90.0).toDouble();
    final max = b.maxDegrees.clamp(0.0, 90.0).toDouble();
    if (max <= min) continue; // drop inverted/zero-width band after clamping
    bands.add(b.copyWith(
      minDegrees: min,
      maxDegrees: max,
      segments: b.segments.clamp(1, 64).toInt(),
    ));
  }

  final safeBands =
      bands.isEmpty ? CaptureConfig.bundledDefault.pitchBands : bands;

  final t = cfg.thresholds;
  final safeThresholds = CaptureThresholds(
    minSharpness: t.minSharpness.clamp(0.0, 1.0).toDouble(),
    minCoveragePct: t.minCoveragePct.clamp(0.0, 100.0).toDouble(),
    maxTiltDeltaDeg: t.maxTiltDeltaDeg.clamp(1.0, 45.0).toDouble(),
  );

  return cfg.copyWith(pitchBands: safeBands, thresholds: safeThresholds);
}
