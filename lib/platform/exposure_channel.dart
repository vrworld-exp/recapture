// lib/platform/exposure_channel.dart
//
// EventChannel wrapper for the native real-time exposure check (mean of the Y/luma
// plane on the downscaled 640px frame, shared with the blur pass). Emits a
// per-frame mean luminance (0–255) + dark/ok/bright band for a "too dark"/"too
// bright" indicator. Warn-only — exposure rejects/gates nothing; the band is the
// signal, the UI hint lives in the capture flow. Channel: ../exposure
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/constants.dart';
import 'exposure_policy.dart';

export 'exposure_policy.dart' show ExposureBand, ExposureThresholdPolicy;

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

/// Streams native per-frame exposure results over the [EventChannel].
///
/// [darkBelow]/[brightAbove] (0–255 scale) are configurable hints with native
/// defaults (40 / 220); the caller may source them from remote config. They are
/// validated natively (`darkBelow < brightAbove`, else defaults). Malformed events
/// are filtered out.
class ExposureAnalysisStream {
  ExposureAnalysisStream([EventChannel? channel])
      : _channel = channel ?? const EventChannel(AppConfig.channelExposure);

  final EventChannel _channel;

  /// Default thresholds (match the native `ExposureThresholdPolicy` defaults).
  static const double defaultDarkBelow = ExposureThresholdPolicy.defaultDarkBelow;
  static const double defaultBrightAbove =
      ExposureThresholdPolicy.defaultBrightAbove;

  /// [darkBelow]/[brightAbove] are the dark/bright band cutoffs (validated
  /// natively). Any omitted value uses the native default.
  Stream<ExposureResult> results({double? darkBelow, double? brightAbove}) {
    final args = <String, dynamic>{
      if (darkBelow != null) 'darkBelow': darkBelow,
      if (brightAbove != null) 'brightAbove': brightAbove,
    };
    return _channel
        .receiveBroadcastStream(args)
        .map(ExposureResult.fromEvent)
        .where((r) => r != null)
        .cast<ExposureResult>();
  }
}
