// lib/platform/capture_ports/orientation_port.dart
//
// PORT: "where does device orientation come from".
//
// Native fills it from the rotation-vector EventChannels
// (`imu_rotation` / `imu_orientation`); web fills it from
// `DeviceOrientationEvent` + the Dart port of the native smoothing filter. The
// consumer (lib/platform/imu_rotation_channel.dart, and through it every
// application-layer provider) sees ONE contract and never learns which.
//
// The interface lives alone in this file, with no conditional import, so both
// implementations can depend on it without an import cycle. The
// `createOrientationPort` factory is selected by the conditional import at the
// consumer (the pattern proven by
// lib/application/projects/model_export_service.dart).
import 'orientation_models.dart';

export 'orientation_models.dart';

/// Device-orientation sources for the guided capture.
///
/// Failure contract (identical on both sides, because the app depends on it):
/// an absent / denied / unusable sensor surfaces as a **stream error**
/// (`PlatformException('SENSOR_UNAVAILABLE')`), never as a silent empty
/// stream. `currentTiltProvider` maps that error onto
/// `TiltSample(sensorSupported: false)`, which fails open for `full` and — by
/// design — keeps the `meshy` hard gate closed.
abstract interface class OrientationPort {
  /// Raw rotation-vector samples. [rateHz] is a best-effort hint (clamped
  /// 50..100 by the caller); rely on each sample's `timestampNs` for cadence.
  Stream<ImuRotationSample> samples({int rateHz});

  /// Low-pass-smoothed orientation for the level/guide. [tauMs] is the
  /// smoothing time constant (larger = smoother but laggier).
  Stream<SmoothedOrientation> orientation({int rateHz, double tauMs});
}
