// lib/platform/capture_ports/orientation_port_stub.dart
//
// Compile-time fallback for the platform-split [OrientationPort]. Only
// reachable on a hypothetical target with neither `dart:io` nor
// `dart:js_interop`; it fails the same way an absent sensor does
// (`SENSOR_UNAVAILABLE`) rather than throwing at import time, so a stray build
// degrades to "guidance unavailable" instead of crashing the capture screen.
import 'package:flutter/services.dart';

import 'orientation_port.dart';

OrientationPort createOrientationPort({
  EventChannel? rotationChannel,
  EventChannel? orientationChannel,
}) =>
    const _UnsupportedOrientationPort();

class _UnsupportedOrientationPort implements OrientationPort {
  const _UnsupportedOrientationPort();

  @override
  Stream<ImuRotationSample> samples({int rateHz = 100}) => _error();

  @override
  Stream<SmoothedOrientation> orientation({
    int rateHz = 100,
    double tauMs = 100.0,
  }) =>
      _error();

  static Stream<T> _error<T>() => Stream<T>.error(
        PlatformException(
          code: 'SENSOR_UNAVAILABLE',
          message: 'Device orientation is not supported on this platform.',
        ),
      );
}
