// test/imu/sensor_stream_payload_test.dart
//
// Locks the native↔Dart contract for the device-motion `sensorStream` channel
// (com.mayasabhaxr.recapture/sensors). These maps mirror EXACTLY what the iOS
// `SensorStreamHandler` emits (and what the future Android equivalent must), so
// the decoder is verified against the real payload shape — including the
// unsupported marker and the additive `attitude` key the decoder must ignore.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/native/sensor_stream.dart';

void main() {
  test('decodes a full device-motion frame (extra attitude key ignored)', () {
    // Shape emitted by SensorStreamHandler.makePayload.
    final raw = <dynamic, dynamic>{
      'timestamp': 1718800000000,
      'orientation': {'alpha': 90.0, 'beta': -12.5, 'gamma': 45.0},
      'accelerometer': {'x': 0.1, 'y': -0.2, 'z': 9.7},
      'deviceMotionSupported': true,
      // Additive radians key — must not break decoding.
      'attitude': {'yaw': 1.5707, 'pitch': -0.218, 'roll': 0.785},
    };

    final payload = SensorStreamPayload.fromMap(raw);

    expect(payload.timestamp, 1718800000000);
    expect(payload.orientation.alpha, 90.0);
    expect(payload.orientation.beta, -12.5);
    expect(payload.orientation.gamma, 45.0);
    expect(payload.accelerometer.x, 0.1);
    expect(payload.accelerometer.y, -0.2);
    expect(payload.accelerometer.z, 9.7);
    expect(payload.deviceMotionSupported, isTrue);
  });

  test('decodes the unsupported marker (simulator / no device motion)', () {
    // Shape emitted by SensorStreamHandler.unsupportedPayload.
    final raw = <dynamic, dynamic>{
      'timestamp': 1718800000001,
      'orientation': {'alpha': 0.0, 'beta': 0.0, 'gamma': 0.0},
      'accelerometer': {'x': 0.0, 'y': 0.0, 'z': 0.0},
      'deviceMotionSupported': false,
    };

    final payload = SensorStreamPayload.fromMap(raw);

    expect(payload.deviceMotionSupported, isFalse);
    expect(payload.orientation.alpha, 0.0);
    expect(payload.accelerometer.z, 0.0);
  });

  test('integer-valued doubles from the platform channel decode as doubles', () {
    // The standard codec can deliver a whole number as an int; the decoder must
    // coerce via num.toDouble() rather than cast.
    final raw = <dynamic, dynamic>{
      'timestamp': 42,
      'orientation': {'alpha': 0, 'beta': 0, 'gamma': 0},
      'accelerometer': {'x': 0, 'y': 0, 'z': 0},
      'deviceMotionSupported': true,
    };

    final payload = SensorStreamPayload.fromMap(raw);

    expect(payload.orientation.alpha, 0.0);
    expect(payload.orientation.alpha, isA<double>());
    expect(payload.timestamp, 42);
  });
}
