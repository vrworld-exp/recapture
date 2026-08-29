// lib/platform/capture_ports/orientation_models.dart
//
// The orientation sample types. They used to live in
// lib/platform/imu_rotation_channel.dart; they moved here (and are re-exported
// from that file, so every existing import keeps working) purely so the port
// interface and BOTH its implementations can depend on them without an import
// cycle back through the channel wrapper.
//
// Nothing about the shapes changed: the same fields, the same `fromEvent`
// parsing, the same radians/nanoseconds units, the same
// `SensorManager.getOrientation` convention. The web port produces these by
// converting `DeviceOrientationEvent` angles (see orientation_math.dart), so
// downstream code cannot tell which platform filled them in.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../domain/capture/camera_tilt.dart' as camera_tilt;

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
  ///
  /// The browser exposes no accuracy signal, so the web port reports 3 (high)
  /// when `DeviceOrientationEvent.absolute` is true and 1 (low) otherwise.
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

/// One low-pass-smoothed orientation sample (for the capture level/guide).
///
/// Smoothing happens in the quaternion domain (so it is wraparound- and
/// gimbal-safe) — natively on Android, and in [DartOrientationFilter] on web;
/// [yaw]/[pitch]/[roll] are derived from the smoothed quaternion.
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
    this.hasQuaternion = true,
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

  /// Whether the native event actually carried a quaternion. [fromEvent]
  /// defaults an ABSENT `q` to the identity (0,0,0,1) — a valid pose (flat,
  /// screen up) — so this flag is the only way to tell "missing" from "flat";
  /// [cameraTiltDegrees] returns NaN when it is false.
  final bool hasQuaternion;

  /// UNCHANGED from the source sample (CLOCK_MONOTONIC; downstream join key).
  final int timestampNs;

  static const double _radToDeg = 180.0 / math.pi;

  double get yawDegrees => yaw * _radToDeg;
  double get pitchDegrees => pitch * _radToDeg;
  double get rollDegrees => roll * _radToDeg;

  /// The camera-tilt angle on the 0–180° scale (0 = camera at the sky, 90 =
  /// level with the horizon, ~180 = at the ground) — the ONE scalar the guided
  /// capture's band logic consumes. Derived from the smoothed quaternion (see
  /// `lib/domain/capture/camera_tilt.dart`); NaN when the event carried no
  /// quaternion or a degenerate one.
  double get cameraTiltDegrees => hasQuaternion
      ? camera_tilt.cameraTiltDegrees(qx: qx, qy: qy, qz: qz, qw: qw)
      : double.nan;

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
      hasQuaternion: hasQ,
      timestampNs: (event['timestampNs'] as num?)?.toInt() ?? 0,
    );
  }
}
