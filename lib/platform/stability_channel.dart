// lib/platform/stability_channel.dart
//
// Stability entry point for the capture HUD and the auto-capture trigger.
// Historically this file WAS the native EventChannel wrapper; it is now the
// platform-agnostic face of [StabilityPort]
// (capture_ports/stability_port.dart), which resolves to:
//
//   • native → the gyro + gravity-removed linear-accel motion detector on the
//     `stability` channel (gate: gyroMag < gyroThresh AND linAccelMag <
//     accelThresh, held continuously for dwellMs) — unchanged, the code moved
//     into capture_ports/stability_port_io.dart;
//   • web    → `devicemotion` fed into a Dart port of that same gate
//     (capture_ports/stability_math.dart + stability_port_web.dart), so
//     "stable" means the same physical steadiness in a browser.
//
// Class names, the injectable [EventChannel] constructor argument, method
// signatures and the event types are unchanged, so every call site is
// untouched. [StabilityEvent] and friends now live in
// capture_ports/stability_models.dart and are re-exported here.
// Channel name: com.mayasabhaxr.recapture/stability
import 'package:flutter/services.dart';

import 'capture_ports/stability_port.dart';
import 'capture_ports/stability_port_stub.dart'
    if (dart.library.io) 'capture_ports/stability_port_io.dart'
    if (dart.library.js_interop) 'capture_ports/stability_port_web.dart';

export 'capture_ports/stability_models.dart'
    show
        StabilityEvent,
        StabilityStateEvent,
        StabilityTriggerEvent,
        StabilityScoreEvent;

/// Streams stability events.
///
/// Thresholds are best-effort hints with the gate's defaults (0.8 rad/s, 0.15 g,
/// 250 ms) and may be sourced from remote config by the caller. An absent sensor
/// surfaces as a `PlatformException('STABILITY_UNAVAILABLE')` — on web that also
/// covers "iOS Safari has not granted motion access".
class StabilityGateStream {
  StabilityGateStream([EventChannel? channel])
      : _port = createStabilityPort(channel);

  final StabilityPort _port;

  static const double defaultGyroThreshRadS = 0.8;
  static const double defaultAccelThreshG = 0.15;
  static const int defaultDwellMs = 250;

  /// All stability events (state transitions + triggers + scores). Malformed
  /// events are filtered. [gyroThresh] rad/s, [accelThresh] in g, [dwellMs] are
  /// forwarded to the gate (invalid values fall back to the defaults).
  Stream<StabilityEvent> events({
    double gyroThresh = defaultGyroThreshRadS,
    double accelThresh = defaultAccelThreshG,
    int dwellMs = defaultDwellMs,
  }) =>
      _port.events(
        gyroThresh: gyroThresh,
        accelThresh: accelThresh,
        dwellMs: dwellMs,
      );

  /// Only the "stable" triggers (for an auto-capture driver that ignores state).
  Stream<StabilityTriggerEvent> triggers({
    double gyroThresh = defaultGyroThreshRadS,
    double accelThresh = defaultAccelThreshG,
    int dwellMs = defaultDwellMs,
  }) =>
      events(gyroThresh: gyroThresh, accelThresh: accelThresh, dwellMs: dwellMs)
          .where((e) => e is StabilityTriggerEvent)
          .cast<StabilityTriggerEvent>();

  /// Only the continuous score samples (for a UI stillness meter that ignores
  /// the debounced state/trigger). Throttled (~10 Hz).
  Stream<StabilityScoreEvent> scores({
    double gyroThresh = defaultGyroThreshRadS,
    double accelThresh = defaultAccelThreshG,
    int dwellMs = defaultDwellMs,
  }) =>
      events(gyroThresh: gyroThresh, accelThresh: accelThresh, dwellMs: dwellMs)
          .where((e) => e is StabilityScoreEvent)
          .cast<StabilityScoreEvent>();
}
