// lib/native/sensor_stream.dart
import '../utils/constants.dart';
import 'event_channel.dart';

/// Device orientation angles in degrees (mirrors Web DeviceOrientationEvent).
final class OrientationAngles {
  const OrientationAngles({
    required this.alpha,
    required this.beta,
    required this.gamma,
  });

  final double alpha;
  final double beta;
  final double gamma;
}

/// Raw accelerometer reading in m/s².
final class AccelerometerVector {
  const AccelerometerVector({
    required this.x,
    required this.y,
    required this.z,
  });

  final double x;
  final double y;
  final double z;
}

/// Payload emitted on every sensor tick from the native IMU pipeline.
final class SensorStreamPayload {
  const SensorStreamPayload({
    required this.timestamp,
    required this.orientation,
    required this.accelerometer,
    required this.deviceMotionSupported,
  });

  factory SensorStreamPayload.fromMap(dynamic raw) {
    final map = raw as Map<dynamic, dynamic>;
    final orient = (map['orientation'] as Map<dynamic, dynamic>?) ?? {};
    final accel = (map['accelerometer'] as Map<dynamic, dynamic>?) ?? {};
    return SensorStreamPayload(
      timestamp: map['timestamp'] as int,
      orientation: OrientationAngles(
        alpha: (orient['alpha'] as num? ?? 0).toDouble(),
        beta: (orient['beta'] as num? ?? 0).toDouble(),
        gamma: (orient['gamma'] as num? ?? 0).toDouble(),
      ),
      accelerometer: AccelerometerVector(
        x: (accel['x'] as num? ?? 0).toDouble(),
        y: (accel['y'] as num? ?? 0).toDouble(),
        z: (accel['z'] as num? ?? 0).toDouble(),
      ),
      deviceMotionSupported: (map['deviceMotionSupported'] as bool?) ?? false,
    );
  }

  final int timestamp;
  final OrientationAngles orientation;
  final AccelerometerVector accelerometer;
  final bool deviceMotionSupported;
}

/// Typed [NativeEventChannel] that streams [SensorStreamPayload] from the
/// native IMU sensor pipeline.
class SensorStreamChannel extends NativeEventChannel<SensorStreamPayload> {
  SensorStreamChannel()
      : super(AppConfig.channelSensors, SensorStreamPayload.fromMap);
}
