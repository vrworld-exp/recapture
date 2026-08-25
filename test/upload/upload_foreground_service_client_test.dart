// test/upload/upload_foreground_service_client_test.dart
//
// The Dart trigger for the Android upload foreground service (STUB). Verifies
// argument forwarding + method names on Android, the platform guard (no-op off
// Android), and graceful degradation when the native channel is absent.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/platform/upload_foreground_service.dart';
import 'package:recapture/utils/constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AppConfig.channelUploadService);
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
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('start forwards done/total to startUploadService', () async {
    setHandler((_) async => null);
    await UploadForegroundServiceClient().start(done: 2, total: 10);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'startUploadService');
    expect(calls.single.arguments, {'done': 2, 'total': 10});
  });

  test('updateProgress forwards done/total', () async {
    setHandler((_) async => null);
    await UploadForegroundServiceClient().updateProgress(done: 5, total: 8);

    expect(calls.single.method, 'updateProgress');
    expect(calls.single.arguments, {'done': 5, 'total': 8});
  });

  test('stop invokes stopUploadService', () async {
    setHandler((_) async => null);
    await UploadForegroundServiceClient().stop();

    expect(calls.single.method, 'stopUploadService');
  });

  test('scheduleNetworkResume / cancelNetworkResume invoke the WorkManager '
      'scheduling methods', () async {
    setHandler((_) async => null);
    final client = UploadForegroundServiceClient();
    await client.scheduleNetworkResume();
    await client.cancelNetworkResume();

    expect(calls.map((c) => c.method),
        ['scheduleNetworkResume', 'cancelNetworkResume']);
  });

  test('hasNotificationsPermission returns the native bool', () async {
    setHandler((_) async => true);
    final ok = await UploadForegroundServiceClient().hasNotificationsPermission();
    expect(ok, isTrue);
    expect(calls.single.method, 'hasNotificationsPermission');
  });

  test('missing plugin → calls degrade gracefully (no throw)', () async {
    // No handler registered → MissingPluginException, swallowed.
    final client = UploadForegroundServiceClient();
    await client.start(done: 1, total: 1);
    await client.updateProgress(done: 1, total: 1);
    await client.stop();
    await client.scheduleNetworkResume();
    await client.cancelNetworkResume();
    expect(await client.hasNotificationsPermission(), isFalse);
  });

  test('non-Android target → every call is a no-op (no channel invoke)', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    setHandler((_) async => true);
    final client = UploadForegroundServiceClient();

    await client.start(done: 1, total: 2);
    await client.updateProgress(done: 1, total: 2);
    await client.stop();
    final ok = await client.hasNotificationsPermission();

    expect(calls, isEmpty); // never reached the native channel
    expect(ok, isFalse);
  });
}
