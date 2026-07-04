// test/upload/upload_background_session_client_test.dart
//
// The Dart client for the iOS background-upload URLSession: argument
// forwarding + the wire arg names, PlatformException propagation for the
// validation error codes, the platform guard (no-op off iOS), and tolerant
// typed decoding of the progress/success/failure event payloads.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/platform/upload_background_session.dart';
import 'package:recapture/utils/constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AppConfig.channelUploadEngine);
  const eventChannel = EventChannel(AppConfig.channelUploadEvents);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final calls = <MethodCall>[];

  void setHandler(Future<Object?>? Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(() {
    calls.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockStreamHandler(eventChannel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  group('enqueueUpload', () {
    test('forwards taskID/localPath/uploadURL/headers on the wire', () async {
      setHandler((_) async => null);
      await UploadBackgroundSessionClient().enqueueUpload(
        taskId: 't-1',
        localPath: '/captures/p/j/images/EYE/eye_0001.jpg',
        uploadUrl: 'https://s3.example.com/presigned',
        headers: const {'Content-Type': 'image/jpeg'},
      );

      expect(calls.single.method, 'enqueueUpload');
      expect(calls.single.arguments, {
        'taskID': 't-1',
        'localPath': '/captures/p/j/images/EYE/eye_0001.jpg',
        'uploadURL': 'https://s3.example.com/presigned',
        'headers': {'Content-Type': 'image/jpeg'},
      });
    });

    test('native validation errors propagate as PlatformException', () async {
      setHandler((_) async => throw PlatformException(
          code: 'FILE_NOT_FOUND', message: 'No file exists at localPath.'));

      expect(
        () => UploadBackgroundSessionClient().enqueueUpload(
          taskId: 't-1',
          localPath: '/missing.jpg',
          uploadUrl: 'https://s3.example.com/x',
        ),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'FILE_NOT_FOUND')),
      );
    });

    test('non-iOS target → no-op (no channel invoke)', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      setHandler((_) async => null);

      await UploadBackgroundSessionClient().enqueueUpload(
        taskId: 't-1', localPath: '/f.jpg', uploadUrl: 'https://x');

      expect(calls, isEmpty);
    });
  });

  group('events', () {
    Future<List<BackgroundUploadEvent>> collect(List<Object?> payloads) async {
      messenger.setMockStreamHandler(
        eventChannel,
        MockStreamHandler.inline(onListen: (args, sink) {
          for (final p in payloads) {
            sink.success(p);
          }
          sink.endOfStream();
        }),
      );
      return UploadBackgroundSessionClient().events().toList();
    }

    test('decodes progress / success / failure payloads', () async {
      final events = await collect([
        {
          'type': 'progress',
          'taskID': 't-1',
          'bytesSent': 1024,
          'totalBytes': 204800,
          'progress': 0.005,
        },
        {
          'type': 'success',
          'taskID': 't-1',
          'statusCode': 200,
          'localPath': '/f.jpg',
          'completedAt': '2026-07-04T10:00:00Z',
        },
        {
          'type': 'failure',
          'taskID': 't-2',
          'errorCode': -1001,
          'errorDescription': 'timed out',
          'retryRecommended': true,
        },
      ]);

      final progress = events[0] as BackgroundUploadProgress;
      expect(progress.taskId, 't-1');
      expect(progress.bytesSent, 1024);
      expect(progress.totalBytes, 204800);
      expect(progress.isIndeterminate, isFalse);

      final success = events[1] as BackgroundUploadSuccess;
      expect(success.statusCode, 200);
      expect(success.localPath, '/f.jpg');
      expect(success.completedAt, '2026-07-04T10:00:00Z');

      final failure = events[2] as BackgroundUploadFailure;
      expect(failure.taskId, 't-2');
      expect(failure.errorCode, -1001);
      expect(failure.retryRecommended, isTrue);
    });

    test('progress -1 (unknown Content-Length) decodes as indeterminate',
        () async {
      final events = await collect([
        {
          'type': 'progress',
          'taskID': 't-1',
          'bytesSent': 10,
          'totalBytes': -1,
          'progress': -1.0,
        },
      ]);
      final p = events.single as BackgroundUploadProgress;
      expect(p.isIndeterminate, isTrue);
      expect(p.totalBytes, -1);
    });

    test('unknown types and garbled payloads are dropped, never thrown',
        () async {
      final events = await collect([
        {'type': 'telemetry', 'taskID': 't-1'}, // unknown type
        {'type': 'success'}, // missing taskID
        'not-a-map',
        {
          'type': 'success',
          'taskID': 'good',
          'statusCode': 201,
        }, // tolerant: optional fields defaulted
      ]);

      expect(events, hasLength(1));
      final ok = events.single as BackgroundUploadSuccess;
      expect(ok.taskId, 'good');
      expect(ok.statusCode, 201);
      expect(ok.localPath, ''); // absent → defaulted, not a crash
    });

    test('non-iOS target → empty stream (no native subscription)', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final events =
          await UploadBackgroundSessionClient().events().toList();
      expect(events, isEmpty);
    });
  });
}
