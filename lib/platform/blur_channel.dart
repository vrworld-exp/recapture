// lib/platform/blur_channel.dart
//
// Real-time blur detection (variance of the Laplacian on a 640px-width
// grayscale of each analysis frame). Historically this file WAS the native
// EventChannel wrapper; it is now the platform-agnostic face of
// [FrameQualityPort] (capture_ports/frame_quality_port.dart), which resolves to:
//
//   • native → the `blur` EventChannel, unchanged;
//   • web    → the ported metric run over the live `<video>` downscaled to the
//     SAME 640px normalization width (capture_ports/frame_quality_port_web.dart
//     + frame_quality_math.dart), so the score lands on the scale the
//     thresholds here were tuned at.
//
// The score/decision is the signal; the accept/reject policy lives in the
// capture flow. Channel name: com.mayasabhaxr.recapture/blur
import 'package:flutter/services.dart';

import 'capture_ports/frame_quality_port.dart';
import 'capture_ports/frame_quality_port_stub.dart'
    if (dart.library.io) 'capture_ports/frame_quality_port_io.dart'
    if (dart.library.js_interop) 'capture_ports/frame_quality_port_web.dart';

export 'blur_policy.dart' show BlurBand, BlurThresholdPolicy;
export 'capture_ports/frame_quality_models.dart' show BlurResult;

/// Streams per-frame blur results.
///
/// [blurThreshold] (variance cutoff at 640px width) is a configurable hint with
/// a platform default; the caller may source it from remote config. Malformed
/// events are filtered out.
class BlurAnalysisStream {
  BlurAnalysisStream([EventChannel? channel])
      : _port = createFrameQualityPort(blurChannel: channel);

  final FrameQualityPort _port;

  /// Default cutoff (matches the native `BlurMetric.DEFAULT_THRESHOLD` and the
  /// Dart port of it). The value is content-sensitive — tune per scene/use case.
  static const double defaultThreshold = 100.0;

  /// [blurThreshold] is the single sharp/blurry cutoff; [rejectBelow]/
  /// [acceptAbove] are the three-band policy thresholds. Any omitted value uses
  /// the platform default.
  Stream<BlurResult> results({
    double? blurThreshold,
    double? rejectBelow,
    double? acceptAbove,
  }) =>
      _port.blur(
        blurThreshold: blurThreshold,
        rejectBelow: rejectBelow,
        acceptAbove: acceptAbove,
      );
}
