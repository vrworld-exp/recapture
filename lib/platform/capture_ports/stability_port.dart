// lib/platform/capture_ports/stability_port.dart
//
// PORT: "is the device being held still enough to shoot".
//
// Native reads the debounced gyro + linear-accel gate over the `stability`
// EventChannel; web runs the SAME gate (ported in stability_math.dart) over
// `devicemotion`. Both emit the identical [StabilityEvent] vocabulary — no new
// enum, no web-only state — so `stabilityProvider` and the auto-capture trigger
// are untouched.
import 'stability_models.dart';

export 'stability_models.dart';

/// Stability sources for the capture HUD and the auto-capture trigger.
///
/// Failure contract (shared): an absent/denied motion sensor surfaces as a
/// **stream error** (`PlatformException('STABILITY_UNAVAILABLE')`), which
/// `stabilityProvider` maps onto `StabilitySample(sensorSupported: false)`.
abstract interface class StabilityPort {
  /// All stability events (debounced state transitions, "entered stable"
  /// triggers, and throttled continuous scores). [gyroThresh] is rad/s,
  /// [accelThresh] is in g, [dwellMs] is the continuous hold required.
  Stream<StabilityEvent> events({
    double gyroThresh,
    double accelThresh,
    int dwellMs,
  });
}
