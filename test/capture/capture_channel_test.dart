// test/capture/capture_channel_test.dart
//
// Verifies the Dart side of the still-capture transport: the MethodChannel
// wrapper (captureSingle / startBurst / startAutoCapture / stopAutoCapture, with
// graceful degradation) and the EventChannel event parsing.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/platform/event_channels.dart';
import 'package:recapture/platform/method_channels.dart';
import 'package:recapture/utils/constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AppConfig.channelCapture);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final calls = <MethodCall>[];

  void setHandler(Future<Object?>? Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(calls.clear);
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('CaptureChannel', () {
    test('captureSingle parses the frame', () async {
      setHandler((call) async => <String, dynamic>{
            'id': 'cap_1_00000',
            'path': '/data/cap/frame.jpg',
            'timestampNs': 123456789,
          });

      final frame = await CaptureChannel().captureSingle();

      expect(frame, isNotNull);
      expect(frame!.id, 'cap_1_00000');
      expect(frame.path, '/data/cap/frame.jpg');
      expect(frame.timestampNs, 123456789);
    });

    test('startBurst forwards count + intervalMs and returns the session id',
        () async {
      setHandler((call) async => <String, dynamic>{'sessionId': 'cap_42'});

      final id = await CaptureChannel().startBurst(10, intervalMs: 250);

      expect(id, 'cap_42');
      expect(calls.single.method, 'startBurst');
      expect(calls.single.arguments, {'count': 10, 'intervalMs': 250});
    });

    test('startAutoCapture forwards intervalMs', () async {
      setHandler((call) async => <String, dynamic>{'sessionId': 'cap_auto'});

      final id = await CaptureChannel().startAutoCapture(intervalMs: 500);

      expect(id, 'cap_auto');
      expect(calls.single.method, 'startAutoCapture');
      expect(calls.single.arguments, {'intervalMs': 500});
    });

    test('stopAutoCapture invokes the native method', () async {
      setHandler((call) async => null);
      await CaptureChannel().stopAutoCapture();
      expect(calls.single.method, 'stopAutoCapture');
    });

    test('BUSY/NO_CAMERA PlatformException → null / no throw', () async {
      setHandler((call) async {
        throw PlatformException(code: 'BUSY', message: 'already running');
      });

      final c = CaptureChannel();
      expect(await c.captureSingle(), isNull);
      expect(await c.startBurst(5), isNull);
      expect(await c.startAutoCapture(), isNull);
    });

    test('missing plugin → graceful nulls / no throw', () async {
      // No handler registered → MissingPluginException.
      final c = CaptureChannel();
      expect(await c.captureSingle(), isNull);
      expect(await c.startBurst(3), isNull);
      await c.stopAutoCapture(); // must not throw
    });

    test('configureCaptureResolution forwards the policy map and acks', () async {
      setHandler((call) async => <String, dynamic>{
            'accepted': true,
            'appliesOnNextBind': true,
          });

      const policy = CaptureResolutionPolicy(
        targetLongEdge: 3000,
        aspectRatio: CaptureAspectRatio.ratio4x3,
        fallbackRule: CaptureFallbackRule.closestHigherThenLower,
        jpegQuality: 90,
      );
      final ok = await CaptureChannel().configureCaptureResolution(policy);

      expect(ok, isTrue);
      expect(calls.single.method, 'configureCaptureResolution');
      expect(calls.single.arguments, {
        'aspectRatio': '4:3',
        'fallbackRule': 'closest-higher-then-lower',
        'jpegQuality': 90,
        'targetLongEdge': 3000,
      });
    });

    test('configureCaptureResolution exact size omits longEdge', () async {
      setHandler((call) async => <String, dynamic>{'accepted': true});

      const policy = CaptureResolutionPolicy(targetWidth: 4000, targetHeight: 3000);
      await CaptureChannel().configureCaptureResolution(policy);

      expect(calls.single.arguments, {
        'aspectRatio': '4:3',
        'fallbackRule': 'closest-higher-then-lower',
        'jpegQuality': 90,
        'targetWidth': 4000,
        'targetHeight': 3000,
      });
    });

    test('configureCaptureResolution INVALID_ARGS → false', () async {
      setHandler((call) async {
        throw PlatformException(code: 'INVALID_ARGS', message: 'bad policy');
      });
      final ok = await CaptureChannel()
          .configureCaptureResolution(const CaptureResolutionPolicy());
      expect(ok, isFalse);
    });

    test('getActiveCaptureResolution parses actual + fellBack', () async {
      setHandler((call) async => <String, dynamic>{
            'width': 4032,
            'height': 3024,
            'jpegQuality': 90,
            'aspectRatio': '4:3',
            'fellBack': true,
            'bound': true,
            'target': {'width': 3000, 'height': 2250, 'longEdge': 3000},
          });

      final res = await CaptureChannel().getActiveCaptureResolution();

      expect(res, isNotNull);
      expect(res!.width, 4032);
      expect(res.height, 3024);
      expect(res.jpegQuality, 90);
      expect(res.aspectRatio, CaptureAspectRatio.ratio4x3);
      expect(res.fellBack, isTrue);
      expect(res.bound, isTrue);
      expect(res.targetLongEdge, 3000);
    });

    test('getActiveCaptureResolution missing plugin → null', () async {
      final res = await CaptureChannel().getActiveCaptureResolution();
      expect(res, isNull);
    });
  });

  group('CaptureEvent.fromEvent', () {
    test('parses a frame event with total', () {
      final e = CaptureEvent.fromEvent({
        'type': 'frame',
        'id': 'cap_1_00002',
        'path': '/p/2.jpg',
        'timestampNs': 999,
        'index': 2,
        'total': 10,
      });
      expect(e, isA<CaptureFrameEvent>());
      final f = e! as CaptureFrameEvent;
      expect(f.index, 2);
      expect(f.total, 10);
      expect(f.timestampNs, 999);
    });

    test('parses an auto-capture frame (null total)', () {
      final f = CaptureEvent.fromEvent({
        'type': 'frame',
        'id': 'x',
        'path': '/p.jpg',
        'timestampNs': 1,
        'index': 7,
      }) as CaptureFrameEvent;
      expect(f.total, isNull);
    });

    test('parses completed and error events', () {
      final c = CaptureEvent.fromEvent(
          {'type': 'completed', 'count': 10, 'sessionId': 'cap_42'});
      expect(c, isA<CaptureCompletedEvent>());
      expect((c! as CaptureCompletedEvent).count, 10);

      final err =
          CaptureEvent.fromEvent({'type': 'error', 'index': 3, 'message': 'disk full'});
      expect(err, isA<CaptureErrorEvent>());
      expect((err! as CaptureErrorEvent).index, 3);
      expect((err as CaptureErrorEvent).message, 'disk full');
    });

    test('parses a metadata event', () {
      final e = CaptureEvent.fromEvent({
        'type': 'metadata',
        'frameId': 'cap_1_00000',
        'index': 0,
        'jpegPath': '/p/0.jpg',
        'sidecarPath': '/p/0.json',
        'exifOk': true,
        'sidecarOk': true,
      });
      expect(e, isA<CaptureMetadataEvent>());
      final m = e! as CaptureMetadataEvent;
      expect(m.frameId, 'cap_1_00000');
      expect(m.index, 0);
      expect(m.sidecarPath, '/p/0.json');
      expect(m.exifOk, isTrue);
      expect(m.sidecarOk, isTrue);
      expect(m.error, isNull);
    });

    test('parses a metadata event carrying an error', () {
      final m = CaptureEvent.fromEvent({
        'type': 'metadata',
        'frameId': 'x',
        'jpegPath': '/p/x.jpg',
        'sidecarPath': '/p/x.json',
        'exifOk': false,
        'sidecarOk': true,
        'error': 'exif: boom',
      }) as CaptureMetadataEvent;
      expect(m.exifOk, isFalse);
      expect(m.error, 'exif: boom');
    });

    test('unknown / malformed events → null (filtered)', () {
      expect(CaptureEvent.fromEvent({'type': 'mystery'}), isNull);
      expect(CaptureEvent.fromEvent('not a map'), isNull);
      expect(CaptureEvent.fromEvent(null), isNull);
    });
  });
}
