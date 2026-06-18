// test/imu/imu_rotation_channel_test.dart
//
// Verifies the Dart side of the IMU rotation-vector transport: sample parsing
// (Float64List + plain List, malformed shapes) and the EventChannel wrapper
// (rate clamping, sample mapping, error propagation, filtering of junk events).
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/platform/imu_rotation_channel.dart';
import 'package:recapture/utils/constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ImuRotationSample.fromEvent', () {
    test('parses a Float64List quaternion payload', () {
      final s = ImuRotationSample.fromEvent({
        'q': Float64List.fromList([0.1, 0.2, 0.3, 0.9]),
        'accuracy': 3,
        'timestampNs': 123456789,
      });
      expect(s, isNotNull);
      expect(s!.qx, closeTo(0.1, 1e-9));
      expect(s.qy, closeTo(0.2, 1e-9));
      expect(s.qz, closeTo(0.3, 1e-9));
      expect(s.qw, closeTo(0.9, 1e-9));
      expect(s.accuracy, 3);
      expect(s.timestampNs, 123456789);
      expect(s.quaternion, [s.qx, s.qy, s.qz, s.qw]);
    });

    test('parses a plain List<num> quaternion (defensive)', () {
      final s = ImuRotationSample.fromEvent({
        'q': <num>[0, 0, 0, 1],
        'accuracy': 1,
        'timestampNs': 7,
      });
      expect(s, isNotNull);
      expect(s!.qw, 1.0);
      expect(s.accuracy, 1);
    });

    test('defaults accuracy/timestamp when absent', () {
      final s = ImuRotationSample.fromEvent({
        'q': Float64List.fromList([0, 0, 0, 1]),
      });
      expect(s, isNotNull);
      expect(s!.accuracy, 0);
      expect(s.timestampNs, 0);
    });

    test('rejects malformed shapes', () {
      expect(ImuRotationSample.fromEvent(null), isNull);
      expect(ImuRotationSample.fromEvent('not a map'), isNull);
      expect(ImuRotationSample.fromEvent(<String, dynamic>{}), isNull);
      // q too short
      expect(
        ImuRotationSample.fromEvent({'q': Float64List.fromList([0, 0, 1])}),
        isNull,
      );
      // q not a list
      expect(ImuRotationSample.fromEvent({'q': 'xyz'}), isNull);
      // non-numeric component
      expect(
        ImuRotationSample.fromEvent({
          'q': <Object>[0, 0, 0, 'oops'],
        }),
        isNull,
      );
    });
  });

  group('ImuRotationStream', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = EventChannel(AppConfig.channelImuRotation);

    tearDown(() => messenger.setMockStreamHandler(channel, null));

    test('clamps rateHz into 50..100 and forwards it on listen', () async {
      Object? listenArgs;
      messenger.setMockStreamHandler(
        channel,
        MockStreamHandler.inline(
          onListen: (args, sink) {
            listenArgs = args;
            sink.endOfStream();
          },
        ),
      );

      await ImuRotationStream(channel).samples(rateHz: 240).first.catchError(
            (_) => const ImuRotationSample(
              qx: 0, qy: 0, qz: 0, qw: 1, accuracy: 0, timestampNs: 0),
          );

      expect(listenArgs, {'rateHz': 100});
    });

    test('clamps a too-low rate up to 50', () async {
      Object? listenArgs;
      messenger.setMockStreamHandler(
        channel,
        MockStreamHandler.inline(
          onListen: (args, sink) {
            listenArgs = args;
            sink.endOfStream();
          },
        ),
      );

      await ImuRotationStream(channel)
          .samples(rateHz: 10)
          .toList()
          .catchError((_) => <ImuRotationSample>[]);

      expect(listenArgs, {'rateHz': 50});
    });

    test('maps native events to samples and filters junk', () async {
      messenger.setMockStreamHandler(
        channel,
        MockStreamHandler.inline(
          onListen: (args, sink) {
            sink.success({
              'q': Float64List.fromList([0, 0, 0, 1]),
              'accuracy': 3,
              'timestampNs': 1000,
            });
            sink.success({'q': 'garbage'}); // filtered
            sink.success({
              'q': Float64List.fromList([1, 0, 0, 0]),
              'accuracy': 2,
              'timestampNs': 2000,
            });
            sink.endOfStream();
          },
        ),
      );

      final samples = await ImuRotationStream(channel).samples().toList();

      expect(samples.length, 2);
      expect(samples[0].timestampNs, 1000);
      expect(samples[0].accuracy, 3);
      expect(samples[1].timestampNs, 2000);
      expect(samples[1].qx, 1.0);
    });

    test('propagates an unavailable-sensor error', () async {
      messenger.setMockStreamHandler(
        channel,
        MockStreamHandler.inline(
          onListen: (args, sink) {
            sink.error(
              code: 'SENSOR_UNAVAILABLE',
              message: 'TYPE_ROTATION_VECTOR sensor not available.',
            );
            sink.endOfStream();
          },
        ),
      );

      expect(
        ImuRotationStream(channel).samples().toList(),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'SENSOR_UNAVAILABLE')),
      );
    });
  });

  group('SmoothedOrientation.fromEvent', () {
    test('parses a full smoothed-orientation event', () {
      final s = SmoothedOrientation.fromEvent({
        'yaw': 3.14159,
        'pitch': -0.5,
        'roll': 0.25,
        'q': Float64List.fromList([0, 0, 0.7071, 0.7071]),
        'timestampNs': 555,
      });
      expect(s, isNotNull);
      expect(s!.yaw, closeTo(3.14159, 1e-9));
      expect(s.pitch, closeTo(-0.5, 1e-9));
      expect(s.roll, closeTo(0.25, 1e-9));
      expect(s.qz, closeTo(0.7071, 1e-9));
      expect(s.qw, closeTo(0.7071, 1e-9));
      expect(s.timestampNs, 555);
    });

    test('exposes degree conversions', () {
      final s = SmoothedOrientation.fromEvent({
        'yaw': math.pi,
        'pitch': math.pi / 2,
        'roll': 0.0,
        'timestampNs': 1,
      })!;
      expect(s.yawDegrees, closeTo(180.0, 1e-9));
      expect(s.pitchDegrees, closeTo(90.0, 1e-9));
      expect(s.rollDegrees, closeTo(0.0, 1e-9));
    });

    test('tolerates a missing quaternion (identity default)', () {
      final s = SmoothedOrientation.fromEvent({
        'yaw': 0.0,
        'pitch': 0.0,
        'roll': 0.0,
        'timestampNs': 9,
      });
      expect(s, isNotNull);
      expect(s!.qw, 1.0);
      expect(s.qx, 0.0);
    });

    test('rejects malformed shapes', () {
      expect(SmoothedOrientation.fromEvent(null), isNull);
      expect(SmoothedOrientation.fromEvent('nope'), isNull);
      // Missing a required Euler component.
      expect(
        SmoothedOrientation.fromEvent({'yaw': 0.0, 'pitch': 0.0}),
        isNull,
      );
    });
  });

  group('ImuOrientationStream', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = EventChannel(AppConfig.channelImuOrientation);

    tearDown(() => messenger.setMockStreamHandler(channel, null));

    test('forwards clamped rateHz and tauMs on listen', () async {
      Object? listenArgs;
      messenger.setMockStreamHandler(
        channel,
        MockStreamHandler.inline(
          onListen: (args, sink) {
            listenArgs = args;
            sink.endOfStream();
          },
        ),
      );

      await ImuOrientationStream(channel)
          .orientation(rateHz: 500, tauMs: 80)
          .toList()
          .catchError((_) => <SmoothedOrientation>[]);

      expect(listenArgs, {'rateHz': 100, 'tauMs': 80.0});
    });

    test('maps smoothed events and filters junk', () async {
      messenger.setMockStreamHandler(
        channel,
        MockStreamHandler.inline(
          onListen: (args, sink) {
            sink.success({
              'yaw': 0.1,
              'pitch': 0.2,
              'roll': 0.3,
              'q': Float64List.fromList([0, 0, 0, 1]),
              'timestampNs': 100,
            });
            sink.success({'pitch': 0.0}); // filtered (no yaw/roll)
            sink.endOfStream();
          },
        ),
      );

      final out = await ImuOrientationStream(channel).orientation().toList();
      expect(out.length, 1);
      expect(out.single.yaw, closeTo(0.1, 1e-9));
      expect(out.single.timestampNs, 100);
    });
  });
}
