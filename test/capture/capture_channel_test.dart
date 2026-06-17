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

    test('unknown / malformed events → null (filtered)', () {
      expect(CaptureEvent.fromEvent({'type': 'mystery'}), isNull);
      expect(CaptureEvent.fromEvent('not a map'), isNull);
      expect(CaptureEvent.fromEvent(null), isNull);
    });
  });
}
