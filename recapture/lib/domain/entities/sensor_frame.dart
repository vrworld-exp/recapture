// lib/domain/entities/sensor_frame.dart
import 'package:freezed_annotation/freezed_annotation.dart';

part 'sensor_frame.freezed.dart';

/// Response from CaptureChannel.getOrientation().
///
/// Mirrors the native stub response shape:
///   { yaw: double, pitch: double, roll: double,
///     gyroMagnitude: double, accelMagnitude: double, timestamp: int }
///
/// Angle convention (per PRD Photo Acceptance Criteria §4.2):
///   "Camera Elevation Angle" — 0° = horizontal, positive = downward,
///   negative = upward.
///
/// P3 TODO: This is currently a polled MethodChannel response with static
/// zeros. P3 may replace this with an EventChannel stream
/// (50-100Hz from TYPE_ROTATION_VECTOR / CMDeviceMotion) — if so, this
/// model is reused as the stream's element type, and CaptureChannel.
/// getOrientation() may be removed in favor of a Stream<SensorFrame>.
@freezed
class SensorFrame with _$SensorFrame {
  const factory SensorFrame({
    /// Yaw angle in degrees.
    required double yaw,

    /// Camera elevation angle in degrees.
    /// 0° = horizontal, positive = downward, negative = upward.
    required double pitch,

    /// Roll angle in degrees. Roll constraint: ±15° (warn, don't block).
    required double roll,

    /// Gyroscope magnitude in rad/s.
    /// Stability gate: must be < 0.8 rad/s for 250ms before capture.
    required double gyroMagnitude,

    /// Linear acceleration magnitude in g.
    /// Stability gate: must be < 0.15g for 250ms before capture.
    required double accelMagnitude,

    /// Sensor reading timestamp, converted from native ms-since-epoch.
    required DateTime timestamp,
  }) = _SensorFrame;

  /// Parses the raw Map returned by the native MethodChannel.
  factory SensorFrame.fromMap(Map<dynamic, dynamic> map) {
    return SensorFrame(
      yaw: (map['yaw'] as num).toDouble(),
      pitch: (map['pitch'] as num).toDouble(),
      roll: (map['roll'] as num).toDouble(),
      gyroMagnitude: (map['gyroMagnitude'] as num).toDouble(),
      accelMagnitude: (map['accelMagnitude'] as num).toDouble(),
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
    );
  }

  /// A zeroed-out frame — useful as an initial/placeholder value before
  /// the first real sensor reading arrives.
  factory SensorFrame.zero() => SensorFrame(
        yaw: 0.0,
        pitch: 0.0,
        roll: 0.0,
        gyroMagnitude: 0.0,
        accelMagnitude: 0.0,
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      );
}
