// lib/platform/capture_ports/frame_quality_port_stub.dart
//
// Compile-time fallback for the platform-split [FrameQualityPort]. Only
// reachable on a target with neither `dart:io` nor `dart:js_interop`. Both
// streams are simply empty: blur and exposure are advisory signals, so their
// absence must show as "no reading yet", never as an error the HUD has to
// render.
import 'package:flutter/services.dart';

import 'frame_quality_port.dart';

FrameQualityPort createFrameQualityPort({
  EventChannel? blurChannel,
  EventChannel? exposureChannel,
}) =>
    const _UnsupportedFrameQualityPort();

class _UnsupportedFrameQualityPort implements FrameQualityPort {
  const _UnsupportedFrameQualityPort();

  @override
  Stream<BlurResult> blur({
    double? blurThreshold,
    double? rejectBelow,
    double? acceptAbove,
  }) =>
      const Stream<BlurResult>.empty();

  @override
  Stream<ExposureResult> exposure({double? darkBelow, double? brightAbove}) =>
      const Stream<ExposureResult>.empty();
}
