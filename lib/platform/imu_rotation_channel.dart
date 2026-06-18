// lib/platform/imu_rotation_channel.dart
//
// EventChannel wrapper for the native TYPE_ROTATION_VECTOR stream (device
// orientation at 50–100Hz). Each sample carries a unit quaternion, the sensor
// accuracy, and a timestamp ALREADY converted into the camera's monotonic clock
// domain (CLOCK_MONOTONIC) so it aligns with a captured frame's
// `captureTimestampNs` — the join key the later pose/frame-fusion task uses.
//
// Also wraps the parallel smoothed-orientation channel (`imu_orientation`):
// low-pass-filtered yaw/pitch/roll for the capture level/guide. See
// SmoothedOrientation / ImuOrientationStream below.
// Channel names: com.mayasabhaxr.recapture/imu_rotation, .../imu_orientation
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/constants.dart';

/// One device-orientation sample from the rotation-vector sensor.
@immutable
class ImuRotationSample {
  const ImuRotationSample({
    required this.qx,
    required this.qy,
    required this.qz,
    required this.qw,
    required this.accuracy,
    required this.timestampNs,
  });

  /// Unit quaternion components (x, y, z, w).
  final double qx;
  final double qy;
  final double qz;
  final double qw;

  /// Sensor accuracy/status (`SensorManager.SENSOR_STATUS_*`): 0 unreliable, 1
  /// low, 2 medium, 3 high. Rotation-vector accuracy tracks magnetometer
  /// calibration — low values mean unreliable yaw, so weight/ignore accordingly.
  final int accuracy;

  /// Capture-aligned timestamp in nanoseconds (CLOCK_MONOTONIC — the same domain
  /// as a frame's `captureTimestampNs`). The requested rate is best-effort, so
  /// rely on this timestamp for cadence, never an assumed fixed rate.
  final int timestampNs;

  /// The quaternion as a 4-element `[x, y, z, w]` list.
  List<double> get quaternion => [qx, qy, qz, qw];

  /// Parses a native sample map; returns null for an unknown/malformed shape
  /// (so a stray event can be filtered rather than crash the stream).
  static ImuRotationSample? fromEvent(Object? event) {
    if (event is! Map) return null;
    // `q` arrives as a Float64List (native double[]) — itself a List<double> —
    // or, defensively, any List of numbers.
    final q = event['q'];
    if (q is! List || q.length < 4) return null;
    double at(int i) {
      final v = q[i];
      return v is num ? v.toDouble() : double.nan;
    }

    final qx = at(0), qy = at(1), qz = at(2), qw = at(3);
    if (qx.isNaN || qy.isNaN || qz.isNaN || qw.isNaN) return null;
    return ImuRotationSample(
      qx: qx,
      qy: qy,
      qz: qz,
      qw: qw,
      accuracy: (event['accuracy'] as num?)?.toInt() ?? 0,
      timestampNs: (event['timestampNs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Streams native rotation-vector samples over the [EventChannel].
///
/// The [rateHz] (clamped to 50..100) is a best-effort HINT to the OS; rely on
/// each [ImuRotationSample.timestampNs] for cadence, not the requested rate.
/// Malformed events are filtered out; an absent sensor surfaces as a stream error
/// (`PlatformException('SENSOR_UNAVAILABLE')`) rather than a silent empty stream.
class ImuRotationStream {
  ImuRotationStream([EventChannel? channel])
      : _channel = channel ?? const EventChannel(AppConfig.channelImuRotation);

  final EventChannel _channel;

  static const int minRateHz = 50;
  static const int maxRateHz = 100;

  /// Subscribes to the native stream at [rateHz] (clamped to [minRateHz]..
  /// [maxRateHz]). Registers the sensor on listen and unregisters on cancel.
  Stream<ImuRotationSample> samples({int rateHz = maxRateHz}) {
    final clamped = rateHz.clamp(minRateHz, maxRateHz);
    return _channel
        .receiveBroadcastStream(<String, dynamic>{'rateHz': clamped})
        .map(ImuRotationSample.fromEvent)
        .where((s) => s != null)
        .cast<ImuRotationSample>();
  }
}

/// One low-pass-smoothed orientation sample (for the capture level/guide).
///
/// Smoothing happens natively in the quaternion domain (so it is wraparound- and
/// gimbal-safe); [yaw]/[pitch]/[roll] are derived from the smoothed quaternion.
@immutable
class SmoothedOrientation {
  const SmoothedOrientation({
    required this.yaw,
    required this.pitch,
    required this.roll,
    required this.qx,
    required this.qy,
    required this.qz,
    required this.qw,
    required this.timestampNs,
  });

  /// Yaw/pitch/roll in **radians**, matching Android's
  /// `SensorManager.getOrientation` convention (azimuth, pitch, roll).
  final double yaw;
  final double pitch;
  final double roll;

  /// The smoothed unit quaternion (x, y, z, w).
  final double qx;
  final double qy;
  final double qz;
  final double qw;

  /// UNCHANGED from the source sample (CLOCK_MONOTONIC; downstream join key).
  final int timestampNs;

  static const double _radToDeg = 180.0 / math.pi;

  double get yawDegrees => yaw * _radToDeg;
  double get pitchDegrees => pitch * _radToDeg;
  double get rollDegrees => roll * _radToDeg;

  /// Parses a native smoothed-orientation map; null for a malformed shape.
  static SmoothedOrientation? fromEvent(Object? event) {
    if (event is! Map) return null;
    final yaw = (event['yaw'] as num?)?.toDouble();
    final pitch = (event['pitch'] as num?)?.toDouble();
    final roll = (event['roll'] as num?)?.toDouble();
    if (yaw == null || pitch == null || roll == null) return null;
    final q = event['q'];
    final hasQ = q is List && q.length >= 4;
    double qAt(int i) => hasQ && q[i] is num ? (q[i] as num).toDouble() : 0.0;
    return SmoothedOrientation(
      yaw: yaw,
      pitch: pitch,
      roll: roll,
      qx: qAt(0),
      qy: qAt(1),
      qz: qAt(2),
      qw: hasQ ? qAt(3) : 1.0,
      timestampNs: (event['timestampNs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Streams native low-pass-smoothed orientation over the parallel
/// `imu_orientation` [EventChannel].
///
/// [tauMs] is the smoothing time constant (larger = smoother but laggier);
/// [rateHz] is the same best-effort 50..100 Hz hint as the raw stream. An absent
/// sensor surfaces as a `PlatformException('SENSOR_UNAVAILABLE')`.
class ImuOrientationStream {
  ImuOrientationStream([EventChannel? channel])
      : _channel = channel ?? const EventChannel(AppConfig.channelImuOrientation);

  final EventChannel _channel;

  static const int minRateHz = ImuRotationStream.minRateHz;
  static const int maxRateHz = ImuRotationStream.maxRateHz;

  /// Default time constant — smooth but not laggy for a live guide (matches the
  /// native `OrientationFilter.DEFAULT_TAU_NS`).
  static const double defaultTauMs = 100.0;

  Stream<SmoothedOrientation> orientation({
    int rateHz = maxRateHz,
    double tauMs = defaultTauMs,
  }) {
    final clampedRate = rateHz.clamp(minRateHz, maxRateHz);
    final safeTau = tauMs < 0 ? 0.0 : tauMs;
    return _channel
        .receiveBroadcastStream(<String, dynamic>{
          'rateHz': clampedRate,
          'tauMs': safeTau,
        })
        .map(SmoothedOrientation.fromEvent)
        .where((s) => s != null)
        .cast<SmoothedOrientation>();
  }
}
