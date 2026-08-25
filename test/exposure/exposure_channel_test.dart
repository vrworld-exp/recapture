// test/exposure/exposure_channel_test.dart
//
// Verifies the Dart side of the exposure-check transport: result parsing
// (malformed shapes, native vs locally-derived band, unknown band) and the
// EventChannel wrapper (threshold forwarding, mapping + junk filtering).
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/platform/exposure_channel.dart';
import 'package:recapture/utils/constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ExposureResult.fromEvent', () {
    test('parses a full result including the native band', () {
      final r = ExposureResult.fromEvent({
        'meanLuminance': 18.4,
        'band': 'dark',
        'darkBelow': 40.0,
        'brightAbove': 220.0,
        'width': 640,
        'height': 360,
        'timestampNs': 987654321,
        'frameIndex': 12,
      });
      expect(r, isNotNull);
      expect(r!.meanLuminance, closeTo(18.4, 1e-9));
      expect(r.band, ExposureBand.dark);
      expect(r.band.isWarning, isTrue);
      expect(r.darkBelow, 40.0);
      expect(r.brightAbove, 220.0);
      expect(r.width, 640);
      expect(r.height, 360);
      expect(r.timestampNs, 987654321);
      expect(r.frameIndex, 12);
    });

    test('derives the band locally when the native band is absent', () {
      // A mean of 230 with default thresholds → bright, even without a `band` key.
      final r = ExposureResult.fromEvent({'meanLuminance': 230.0});
      expect(r, isNotNull);
      expect(r!.band, ExposureBand.bright);
      expect(r.darkBelow, 40.0);
      expect(r.brightAbove, 220.0);
    });

    test('passes through an explicit unknown band', () {
      final r = ExposureResult.fromEvent({
        'meanLuminance': double.nan,
        'band': 'unknown',
      });
      expect(r, isNotNull);
      expect(r!.band, ExposureBand.unknown);
      expect(r.meanLuminance.isNaN, isTrue);
    });

    test('rejects malformed shapes', () {
      expect(ExposureResult.fromEvent(null), isNull);
      expect(ExposureResult.fromEvent('nope'), isNull);
      // Missing mean.
      expect(ExposureResult.fromEvent({'band': 'ok'}), isNull);
    });
  });

  group('ExposureAnalysisStream', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = EventChannel(AppConfig.channelExposure);

    tearDown(() => messenger.setMockStreamHandler(channel, null));

    test('forwards configured thresholds on listen', () async {
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

      await ExposureAnalysisStream(channel)
          .results(darkBelow: 50, brightAbove: 200)
          .toList()
          .catchError((_) => <ExposureResult>[]);

      expect(listenArgs, {'darkBelow': 50.0, 'brightAbove': 200.0});
    });

    test('omits thresholds when not provided', () async {
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

      await ExposureAnalysisStream(channel)
          .results()
          .toList()
          .catchError((_) => <ExposureResult>[]);

      expect(listenArgs, <String, dynamic>{});
    });

    test('maps native events and filters junk', () async {
      messenger.setMockStreamHandler(
        channel,
        MockStreamHandler.inline(
          onListen: (args, sink) {
            sink.success({
              'meanLuminance': 15.0,
              'band': 'dark',
              'width': 640,
              'height': 480,
              'timestampNs': 1,
              'frameIndex': 0,
            });
            sink.success({'band': 'ok'}); // filtered (no mean)
            sink.success({
              'meanLuminance': 240.0,
              'band': 'bright',
              'width': 640,
              'height': 480,
              'timestampNs': 2,
              'frameIndex': 1,
            });
            sink.endOfStream();
          },
        ),
      );

      final out = await ExposureAnalysisStream(channel).results().toList();
      expect(out.length, 2);
      expect(out[0].band, ExposureBand.dark);
      expect(out[1].band, ExposureBand.bright);
      expect(out[1].timestampNs, 2);
    });
  });
}
