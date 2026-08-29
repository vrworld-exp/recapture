// lib/platform/imu_rotation_channel.dart
//
// Device-orientation entry point for the guided capture. Historically this file
// WAS the native EventChannel wrapper; it is now the platform-agnostic face of
// [OrientationPort] (capture_ports/orientation_port.dart), which resolves to:
//
//   • native → the TYPE_ROTATION_VECTOR EventChannels (`imu_rotation` at
//     50–100 Hz with capture-aligned CLOCK_MONOTONIC timestamps, and the
//     parallel low-pass-filtered `imu_orientation`) — unchanged behaviour,
//     the code simply moved into capture_ports/orientation_port_io.dart;
//   • web    → `DeviceOrientationEvent` converted into the same body→world
//     quaternion and smoothed by the Dart port of the native filter
//     (capture_ports/orientation_port_web.dart).
//
// The class names, constructors (including the injectable [EventChannel] the
// channel tests pass), method signatures and sample types are all unchanged, so
// every call site — `ImuOrientationStream().orientation()` in
// current_tilt_provider.dart included — is untouched by the web work.
//
// [ImuRotationSample] / [SmoothedOrientation] now live in
// capture_ports/orientation_models.dart and are re-exported here.
// Channel names: com.mayasabhaxr.recapture/imu_rotation, .../imu_orientation
import 'package:flutter/services.dart';

import 'capture_ports/orientation_port.dart';
import 'capture_ports/orientation_port_stub.dart'
    if (dart.library.io) 'capture_ports/orientation_port_io.dart'
    if (dart.library.js_interop) 'capture_ports/orientation_port_web.dart';

export 'capture_ports/orientation_models.dart'
    show ImuRotationSample, SmoothedOrientation;

/// Streams raw rotation-vector samples.
///
/// The [rateHz] (clamped to 50..100) is a best-effort HINT to the OS; rely on
/// each [ImuRotationSample.timestampNs] for cadence, not the requested rate.
/// Malformed events are filtered out; an absent sensor surfaces as a stream
/// error (`PlatformException('SENSOR_UNAVAILABLE')`) rather than a silent empty
/// stream — on web that also covers "iOS Safari has not granted motion access".
class ImuRotationStream {
  ImuRotationStream([EventChannel? channel])
      : _port = createOrientationPort(rotationChannel: channel);

  final OrientationPort _port;

  static const int minRateHz = 50;
  static const int maxRateHz = 100;

  /// Subscribes at [rateHz] (clamped to [minRateHz]..[maxRateHz]). Registers the
  /// sensor on listen and unregisters on cancel.
  Stream<ImuRotationSample> samples({int rateHz = maxRateHz}) =>
      _port.samples(rateHz: rateHz);
}

/// Streams low-pass-smoothed orientation (the capture level/guide source).
///
/// [tauMs] is the smoothing time constant (larger = smoother but laggier);
/// [rateHz] is the same best-effort 50..100 Hz hint as the raw stream. An absent
/// sensor surfaces as a `PlatformException('SENSOR_UNAVAILABLE')`.
class ImuOrientationStream {
  ImuOrientationStream([EventChannel? channel])
      : _port = createOrientationPort(orientationChannel: channel);

  final OrientationPort _port;

  static const int minRateHz = ImuRotationStream.minRateHz;
  static const int maxRateHz = ImuRotationStream.maxRateHz;

  /// Default time constant — smooth but not laggy for a live guide (matches the
  /// native `OrientationFilter.DEFAULT_TAU_NS` and the Dart port of it).
  static const double defaultTauMs = 100.0;

  Stream<SmoothedOrientation> orientation({
    int rateHz = maxRateHz,
    double tauMs = defaultTauMs,
  }) =>
      _port.orientation(rateHz: rateHz, tauMs: tauMs);
}
