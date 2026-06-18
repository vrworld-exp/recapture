// lib/platform/blur_channel.dart
//
// EventChannel wrapper for the native real-time blur detector (variance of the
// Laplacian on a 640px-width grayscale of each ImageAnalysis frame). Emits a
// per-frame sharpness score + sharp/blurry decision for a "too blurry / hold
// steady" indicator. The score/decision is the signal; the accept/reject policy
// lives in the capture flow. Channel name: com.mayasabhaxr.recapture/blur
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/constants.dart';
import 'blur_policy.dart';

export 'blur_policy.dart' show BlurBand, BlurThresholdPolicy;

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

/// Streams native per-frame blur results over the [EventChannel].
///
/// [blurThreshold] (variance cutoff at 640px width) is a configurable hint with a
/// native default; the caller may source it from remote config. Malformed events
/// are filtered out.
class BlurAnalysisStream {
  BlurAnalysisStream([EventChannel? channel])
      : _channel = channel ?? const EventChannel(AppConfig.channelBlur);

  final EventChannel _channel;

  /// Default cutoff (matches the native `BlurMetric.DEFAULT_THRESHOLD`). The value
  /// is content-sensitive — tune per scene/use case.
  static const double defaultThreshold = 100.0;

  /// [blurThreshold] is the single sharp/blurry cutoff; [rejectBelow]/[acceptAbove]
  /// are the three-band policy thresholds (validated natively). Any omitted value
  /// uses the native default.
  Stream<BlurResult> results({
    double? blurThreshold,
    double? rejectBelow,
    double? acceptAbove,
  }) {
    final args = <String, dynamic>{
      if (blurThreshold != null && blurThreshold >= 0) 'blurThreshold': blurThreshold,
      if (rejectBelow != null) 'rejectBelow': rejectBelow,
      if (acceptAbove != null) 'acceptAbove': acceptAbove,
    };
    return _channel
        .receiveBroadcastStream(args)
        .map(BlurResult.fromEvent)
        .where((r) => r != null)
        .cast<BlurResult>();
  }
}
