// test/blur/blur_channel_test.dart
//
// Verifies the Dart side of the blur-detection transport: result parsing
// (malformed shapes) and the EventChannel wrapper (threshold forwarding, mapping
// and filtering of events).
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/platform/blur_channel.dart';
import 'package:recapture/utils/constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BlurResult.fromEvent', () {
    test('parses a full result including the native band', () {
      final r = BlurResult.fromEvent({
        'sharpnessScore': 245.6,
        'sharp': true,
        'band': 'accept',
        'rejectBelow': 40.0,
        'acceptAbove': 80.0,
        'width': 640,
        'height': 360,
        'timestampNs': 987654321,
        'frameIndex': 12,
      });
      expect(r, isNotNull);
      expect(r!.sharpnessScore, closeTo(245.6, 1e-9));
      expect(r.sharp, isTrue);
      expect(r.band, BlurBand.accept);
      expect(r.rejectBelow, 40.0);
      expect(r.acceptAbove, 80.0);
      expect(r.width, 640);
      expect(r.height, 360);
      expect(r.timestampNs, 987654321);
      expect(r.frameIndex, 12);
    });

    test('derives the band locally when the native band is absent', () {
      // A score of 60 with default thresholds → WARN, even without a `band` key.
      final r = BlurResult.fromEvent({
        'sharpnessScore': 60.0,
        'sharp': false,
      });
      expect(r, isNotNull);
      expect(r!.band, BlurBand.warn);
      expect(r.rejectBelow, 40.0);
      expect(r.acceptAbove, 80.0);
    });

    test('rejects malformed shapes', () {
      expect(BlurResult.fromEvent(null), isNull);
      expect(BlurResult.fromEvent('nope'), isNull);
      // Missing score.
      expect(BlurResult.fromEvent({'sharp': true}), isNull);
      // `sharp` not a bool.
      expect(
        BlurResult.fromEvent({'sharpnessScore': 1.0, 'sharp': 'yes'}),
        isNull,
      );
    });
  });

  group('BlurAnalysisStream', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = EventChannel(AppConfig.channelBlur);

    tearDown(() => messenger.setMockStreamHandler(channel, null));

    test('forwards configured thresholds (single + band) on listen', () async {
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

      await BlurAnalysisStream(channel)
          .results(blurThreshold: 150.0, rejectBelow: 30, acceptAbove: 70)
          .toList()
          .catchError((_) => <BlurResult>[]);

      expect(listenArgs,
          {'blurThreshold': 150.0, 'rejectBelow': 30.0, 'acceptAbove': 70.0});
    });

    test('omits the threshold when not provided', () async {
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

      await BlurAnalysisStream(channel)
          .results()
          .toList()
          .catchError((_) => <BlurResult>[]);

      expect(listenArgs, <String, dynamic>{});
    });

    test('maps native events and filters junk', () async {
      messenger.setMockStreamHandler(
        channel,
        MockStreamHandler.inline(
          onListen: (args, sink) {
            sink.success({
              'sharpnessScore': 300.0,
              'sharp': true,
              'width': 640,
              'height': 480,
              'timestampNs': 1,
              'frameIndex': 0,
            });
            sink.success({'sharp': true}); // filtered (no score)
            sink.success({
              'sharpnessScore': 20.0,
              'sharp': false,
              'width': 640,
              'height': 480,
              'timestampNs': 2,
              'frameIndex': 1,
            });
            sink.endOfStream();
          },
        ),
      );

      final out = await BlurAnalysisStream(channel).results().toList();
      expect(out.length, 2);
      expect(out[0].sharp, isTrue);
      expect(out[1].sharp, isFalse);
      expect(out[1].timestampNs, 2);
    });
  });
}
