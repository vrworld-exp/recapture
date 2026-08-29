// lib/platform/exposure_channel.dart
//
// Real-time exposure check (mean of the luma plane on the downscaled 640px
// frame, shared with the blur pass). Historically this file WAS the native
// EventChannel wrapper; it is now the platform-agnostic face of the SAME
// [FrameQualityPort] blur_channel.dart uses — one port, because on both
// platforms both metrics come from one downscale of one frame, which is what
// makes their `timestampNs` / `frameIndex` genuinely paired.
//
//   • native → the `exposure` EventChannel, unchanged;
//   • web    → the ported metric over the shared 640px grayscale
//     (capture_ports/frame_quality_port_web.dart).
//
// Warn-only — exposure rejects/gates nothing; the band is the signal, the UI
// hint lives in the capture flow. Channel: com.mayasabhaxr.recapture/exposure
import 'package:flutter/services.dart';

import 'capture_ports/frame_quality_port.dart';
import 'capture_ports/frame_quality_port_stub.dart'
    if (dart.library.io) 'capture_ports/frame_quality_port_io.dart'
    if (dart.library.js_interop) 'capture_ports/frame_quality_port_web.dart';
import 'exposure_policy.dart';

export 'capture_ports/frame_quality_models.dart' show ExposureResult;
export 'exposure_policy.dart' show ExposureBand, ExposureThresholdPolicy;

/// Streams per-frame exposure results.
///
/// [darkBelow]/[brightAbove] (0–255 scale) are configurable hints with platform
/// defaults (40 / 220); the caller may source them from remote config. They are
/// validated (`darkBelow < brightAbove`, else defaults). Malformed events are
/// filtered out.
class ExposureAnalysisStream {
  ExposureAnalysisStream([EventChannel? channel])
      : _port = createFrameQualityPort(exposureChannel: channel);

  final FrameQualityPort _port;

  /// Default thresholds (match the native `ExposureThresholdPolicy` defaults).
  static const double defaultDarkBelow =
      ExposureThresholdPolicy.defaultDarkBelow;
  static const double defaultBrightAbove =
      ExposureThresholdPolicy.defaultBrightAbove;

  /// [darkBelow]/[brightAbove] are the dark/bright band cutoffs. Any omitted
  /// value uses the platform default.
  Stream<ExposureResult> results({double? darkBelow, double? brightAbove}) =>
      _port.exposure(darkBelow: darkBelow, brightAbove: brightAbove);
}
