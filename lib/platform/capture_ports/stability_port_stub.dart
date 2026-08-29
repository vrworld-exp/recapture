// lib/platform/capture_ports/stability_port_stub.dart
//
// Compile-time fallback for the platform-split [StabilityPort]. Only reachable
// on a target with neither `dart:io` nor `dart:js_interop`; it degrades exactly
// like an absent sensor rather than throwing at import time.
import 'package:flutter/services.dart';

import 'stability_port.dart';

StabilityPort createStabilityPort([EventChannel? channel]) =>
    const _UnsupportedStabilityPort();

class _UnsupportedStabilityPort implements StabilityPort {
  const _UnsupportedStabilityPort();

  @override
  Stream<StabilityEvent> events({
    double gyroThresh = 0.8,
    double accelThresh = 0.15,
    int dwellMs = 250,
  }) =>
      Stream<StabilityEvent>.error(
        PlatformException(
          code: 'STABILITY_UNAVAILABLE',
          message: 'Motion sensing is not supported on this platform.',
        ),
      );
}
