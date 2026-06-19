// test/imu/sensor_stream_hardening_test.dart
//
// Covers the hardening of the device-motion sensor decoder + stream
// (com.mayasabhaxr.recapture/sensors): malformed events now throw a structured
// SensorParseException (not a raw TypeError), and SensorStreamChannel.stream
// isolates a bad frame (drops it) rather than letting it terminate the live
// subscription — while real channel errors (PlatformException) still propagate.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/native/sensor_stream.dart';
import 'package:recapture/utils/constants.dart';

Map<dynamic, dynamic> _valid(int timestamp) => <dynamic, dynamic>{
      'timestamp': timestamp,
      'orientation': {'alpha': 1.0, 'beta': 2.0, 'gamma': 3.0},
      'accelerometer': {'x': 0.1, 'y': 0.2, 'z': 9.8},
      'deviceMotionSupported': true,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SensorStreamPayload.fromMap structured errors', () {
    test('non-Map root throws SensorParseException (not TypeError)', () {
      expect(
        () => SensorStreamPayload.fromMap('not a map'),
        throwsA(isA<SensorParseException>()),
      );
    });

    test('missing timestamp throws SensorParseException', () {
      final raw = _valid(1)..remove('timestamp');
      expect(
        () => SensorStreamPayload.fromMap(raw),
        throwsA(isA<SensorParseException>()),
      );
    });

    test('non-numeric timestamp throws SensorParseException, not a TypeError',
        () {
      final raw = _valid(1)..['timestamp'] = 'oops';
      expect(
        () => SensorStreamPayload.fromMap(raw),
        throwsA(isA<SensorParseException>()),
      );
    });

    test('orientation present but not a Map throws with a labelled message', () {
      final raw = _valid(1)..['orientation'] = 'bad';
      expect(
        () => SensorStreamPayload.fromMap(raw),
        throwsA(
          isA<SensorParseException>()
              .having((e) => e.message, 'message', contains('orientation')),
        ),
      );
    });

    test('a double timestamp is coerced to int (tolerant)', () {
      final raw = _valid(1)..['timestamp'] = 42.0;
      expect(SensorStreamPayload.fromMap(raw).timestamp, 42);
    });

    test('missing sub-maps still default to zeros (behaviour preserved)', () {
      final raw = <dynamic, dynamic>{'timestamp': 7, 'deviceMotionSupported': false};
      final p = SensorStreamPayload.fromMap(raw);
      expect(p.orientation.alpha, 0.0);
      expect(p.accelerometer.z, 0.0);
      expect(p.timestamp, 7);
    });
  });

  group('SensorStreamChannel.stream isolation', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final channel = EventChannel(AppConfig.channelSensors);

    tearDown(() => messenger.setMockStreamHandler(channel, null));

    test('a malformed frame is skipped; surrounding valid frames still emit',
        () async {
      messenger.setMockStreamHandler(
        channel,
        MockStreamHandler.inline(
          onListen: (args, sink) {
            sink.success(_valid(1));
            sink.success('not a map'); // malformed → dropped, not fatal
            sink.success(_valid(2));
            sink.endOfStream();
          },
        ),
      );

      final frames = await SensorStreamChannel().stream.toList();

      expect(frames.map((f) => f.timestamp).toList(), [1, 2]);
    });

    test('a channel error (PlatformException) propagates, not swallowed',
        () async {
      messenger.setMockStreamHandler(
        channel,
        MockStreamHandler.inline(
          onListen: (args, sink) {
            sink.error(code: 'SENSOR_UNAVAILABLE', message: 'no hardware');
          },
        ),
      );

      await expectLater(
        SensorStreamChannel().stream,
        emitsError(isA<PlatformException>()),
      );
    });
  });

  test('SensorStreamPayload is const-constructible', () {
    const p = SensorStreamPayload(
      timestamp: 0,
      orientation: OrientationAngles(alpha: 0, beta: 0, gamma: 0),
      accelerometer: AccelerometerVector(x: 0, y: 0, z: 0),
      deviceMotionSupported: false,
    );
    expect(p.timestamp, 0);
  });
}
