// test/stability/stability_channel_test.dart
//
// Verifies the Dart side of the stability-gate transport: event parsing
// (state/trigger discrimination, malformed shapes) and the EventChannel wrapper
// (threshold args forwarded, event mapping/filtering, trigger filtering, error
// propagation).
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/platform/stability_channel.dart';
import 'package:recapture/utils/constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StabilityEvent.fromEvent', () {
    test('parses a state transition', () {
      final e = StabilityEvent.fromEvent({
        'type': 'state',
        'stable': true,
        'gyroMag': 0.12,
        'linAccelMag': 0.4,
        'timestampNs': 12345,
      });
      expect(e, isA<StabilityStateEvent>());
      final s = e! as StabilityStateEvent;
      expect(s.stable, isTrue);
      expect(s.gyroMag, closeTo(0.12, 1e-9));
      expect(s.linAccelMag, closeTo(0.4, 1e-9));
      expect(s.timestampNs, 12345);
    });

    test('parses a trigger', () {
      final e = StabilityEvent.fromEvent({
        'type': 'trigger',
        'event': 'stable',
        'timestampNs': 999,
      });
      expect(e, isA<StabilityTriggerEvent>());
      expect((e! as StabilityTriggerEvent).timestampNs, 999);
    });

    test('parses a continuous score sample', () {
      final e = StabilityEvent.fromEvent({
        'type': 'score',
        'score': 0.87,
        'gyroMag': 0.05,
        'linAccelMag': 0.2,
        'timestampNs': 555,
      });
      expect(e, isA<StabilityScoreEvent>());
      final s = e! as StabilityScoreEvent;
      expect(s.score, closeTo(0.87, 1e-9));
      expect(s.gyroMag, closeTo(0.05, 1e-9));
      expect(s.linAccelMag, closeTo(0.2, 1e-9));
      expect(s.timestampNs, 555);
    });

    test('rejects a score event missing the score field', () {
      expect(
        StabilityEvent.fromEvent({'type': 'score', 'timestampNs': 1}),
        isNull,
      );
    });

    test('rejects malformed / unknown shapes', () {
      expect(StabilityEvent.fromEvent(null), isNull);
      expect(StabilityEvent.fromEvent('nope'), isNull);
      expect(StabilityEvent.fromEvent({'type': 'mystery'}), isNull);
      // state without a bool `stable`
      expect(
        StabilityEvent.fromEvent({'type': 'state', 'timestampNs': 1}),
        isNull,
      );
    });
  });

  group('StabilityGateStream', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = EventChannel(AppConfig.channelStability);

    tearDown(() => messenger.setMockStreamHandler(channel, null));

    test('forwards thresholds on listen', () async {
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

      await StabilityGateStream(channel)
          .events(gyroThresh: 0.6, accelThresh: 0.2, dwellMs: 300)
          .toList()
          .catchError((_) => <StabilityEvent>[]);

      expect(listenArgs, {'gyroThresh': 0.6, 'accelThresh': 0.2, 'dwellMs': 300});
    });

    test('maps state + trigger events and filters junk', () async {
      messenger.setMockStreamHandler(
        channel,
        MockStreamHandler.inline(
          onListen: (args, sink) {
            sink.success({
              'type': 'state',
              'stable': true,
              'gyroMag': 0.1,
              'linAccelMag': 0.3,
              'timestampNs': 100,
            });
            sink.success({
              'type': 'trigger',
              'event': 'stable',
              'timestampNs': 100,
            });
            sink.success({'type': 'noise'}); // filtered
            sink.endOfStream();
          },
        ),
      );

      final out = await StabilityGateStream(channel).events().toList();
      expect(out.length, 2);
      expect(out[0], isA<StabilityStateEvent>());
      expect(out[1], isA<StabilityTriggerEvent>());
    });

    test('triggers() yields only trigger events', () async {
      messenger.setMockStreamHandler(
        channel,
        MockStreamHandler.inline(
          onListen: (args, sink) {
            sink.success({
              'type': 'state',
              'stable': false,
              'gyroMag': 1.0,
              'linAccelMag': 2.0,
              'timestampNs': 1,
            });
            sink.success({
              'type': 'trigger',
              'event': 'stable',
              'timestampNs': 2,
            });
            sink.endOfStream();
          },
        ),
      );

      final triggers = await StabilityGateStream(channel).triggers().toList();
      expect(triggers.length, 1);
      expect(triggers.single.timestampNs, 2);
    });

    test('scores() yields only continuous score events', () async {
      messenger.setMockStreamHandler(
        channel,
        MockStreamHandler.inline(
          onListen: (args, sink) {
            sink.success({
              'type': 'state',
              'stable': true,
              'gyroMag': 0.1,
              'linAccelMag': 0.3,
              'timestampNs': 1,
            });
            sink.success({
              'type': 'score',
              'score': 0.5,
              'gyroMag': 0.4,
              'linAccelMag': 0.7,
              'timestampNs': 2,
            });
            sink.endOfStream();
          },
        ),
      );

      final scores = await StabilityGateStream(channel).scores().toList();
      expect(scores.length, 1);
      expect(scores.single.score, closeTo(0.5, 1e-9));
      expect(scores.single.timestampNs, 2);
    });

    test('propagates an unavailable-sensor error', () {
      messenger.setMockStreamHandler(
        channel,
        MockStreamHandler.inline(
          onListen: (args, sink) {
            sink.error(
              code: 'STABILITY_UNAVAILABLE',
              message: 'Stability sensors unavailable: gyroscope',
            );
            sink.endOfStream();
          },
        ),
      );

      expect(
        StabilityGateStream(channel).events().toList(),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'STABILITY_UNAVAILABLE')),
      );
    });
  });
}
