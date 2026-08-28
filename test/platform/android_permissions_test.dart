// test/platform/android_permissions_test.dart
//
// Tests the Android native permissions path: the AndroidPermissionChannel
// wrapper (status mapping + graceful failure) and PermissionsService's Android
// delegation (logical-key mapping + native-status → AppPermissionStatus).
//
// The native side is mocked at the MethodChannel boundary, so these run on the
// plain Dart test host. The platform branch is forced via `platformOverride`
// rather than relying on the host's defaultTargetPlatform.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/permission_item.dart';
import 'package:recapture/platform/permissions/android_permission_channel.dart';
import 'package:recapture/platform/permissions_service.dart';
import 'package:recapture/utils/constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AppConfig.channelPermissions);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Installs a mock native handler that records calls and returns [reply]
  /// (or throws, when [error] is set). Returns the recorded call list.
  List<MethodCall> mockNative({Object? reply, PlatformException? error}) {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (error != null) throw error;
      return reply;
    });
    return calls;
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('AndroidPermissionChannel', () {
    test('passes method + permission and returns the native status', () async {
      final calls = mockNative(reply: 'granted');
      const wrapper = AndroidPermissionChannel();

      expect(await wrapper.check('camera'), 'granted');
      expect(await wrapper.request('storage'), 'granted');

      expect(calls.map((c) => c.method), ['check', 'request']);
      expect(calls[0].arguments, {'permission': 'camera'});
      expect(calls[1].arguments, {'permission': 'storage'});
    });

    test('null native reply degrades to denied', () async {
      mockNative(reply: null);
      const wrapper = AndroidPermissionChannel();
      expect(await wrapper.check('camera'), 'denied');
    });

    test('PlatformException (e.g. NO_ACTIVITY) degrades to denied', () async {
      mockNative(error: PlatformException(code: 'NO_ACTIVITY'));
      const wrapper = AndroidPermissionChannel();
      expect(await wrapper.request('camera'), 'denied');
    });

    test('missing plugin degrades to denied', () async {
      // No mock handler installed → MissingPluginException.
      messenger.setMockMethodCallHandler(channel, null);
      const wrapper = AndroidPermissionChannel();
      expect(await wrapper.check('camera'), 'denied');
    });

    test('openAppSettings returns the native launch outcome', () async {
      final calls = mockNative(reply: true);
      const wrapper = AndroidPermissionChannel();
      expect(await wrapper.openAppSettings(), isTrue);
      expect(calls.single.method, 'openAppSettings');
    });

    test('openAppSettings false when native could not launch', () async {
      mockNative(reply: false);
      expect(await const AndroidPermissionChannel().openAppSettings(), isFalse);
    });

    test('openAppSettings degrades to false on exception / missing plugin',
        () async {
      mockNative(error: PlatformException(code: 'whatever'));
      expect(await const AndroidPermissionChannel().openAppSettings(), isFalse);

      messenger.setMockMethodCallHandler(channel, null); // MissingPlugin
      expect(await const AndroidPermissionChannel().openAppSettings(), isFalse);
    });
  });

  group('PermissionsService (Android delegation)', () {
    PermissionsService service() => const PermissionsService(
          platformOverride: TargetPlatform.android,
        );

    test('maps camera/photos to the right native key (motion needs no native call)',
        () async {
      final calls = mockNative(reply: 'granted');
      final svc = service();

      await svc.status(AppPermissionType.camera);
      await svc.status(AppPermissionType.photos);

      expect(
        calls.map((c) => (c.arguments as Map)['permission']),
        ['camera', 'storage'],
      );
    });

    test('motion is permission-free: granted with no native call, any platform',
        () async {
      // Mock returns 'denied' — proving the result comes from the short-circuit,
      // not the channel (which is never invoked for motion).
      final androidCalls = mockNative(reply: 'denied');
      const android = PermissionsService(platformOverride: TargetPlatform.android);
      expect(await android.status(AppPermissionType.motion),
          AppPermissionStatus.granted);
      expect(await android.request(AppPermissionType.motion),
          AppPermissionStatus.granted);
      expect(androidCalls, isEmpty);

      // iOS path: motion must also short-circuit (never reaching permission_handler,
      // whose plugin channel is unmocked here).
      const ios = PermissionsService(platformOverride: TargetPlatform.iOS);
      expect(await ios.status(AppPermissionType.motion),
          AppPermissionStatus.granted);
      expect(await ios.request(AppPermissionType.motion),
          AppPermissionStatus.granted);
    });

    test('check uses the no-prompt native method', () async {
      final calls = mockNative(reply: 'granted');
      await service().status(AppPermissionType.camera);
      expect(calls.single.method, 'check');
    });

    test('request triggers the prompting native method', () async {
      final calls = mockNative(reply: 'granted');
      await service().request(AppPermissionType.camera);
      expect(calls.single.method, 'request');
    });

    test('native status strings map to AppPermissionStatus', () async {
      Future<AppPermissionStatus> resolve(String native) async {
        mockNative(reply: native);
        return service().request(AppPermissionType.photos);
      }

      expect(await resolve('granted'), AppPermissionStatus.granted);
      expect(await resolve('limited'), AppPermissionStatus.granted);
      expect(await resolve('denied'), AppPermissionStatus.denied);
      expect(await resolve('permanentlyDenied'),
          AppPermissionStatus.permanentlyDenied);
      expect(await resolve('restricted'), AppPermissionStatus.restricted);
      expect(await resolve('unexpected'), AppPermissionStatus.denied);
    });

    test('a native failure surfaces as denied, never throws', () async {
      mockNative(error: PlatformException(code: 'ALREADY_IN_FLIGHT'));
      expect(await service().request(AppPermissionType.camera),
          AppPermissionStatus.denied);
    });

    test('openSettings routes through the native channel on Android', () async {
      final calls = mockNative(reply: true);
      expect(await service().openSettings(), isTrue);
      expect(calls.single.method, 'openAppSettings');
    });

    test('openSettings returns false when the native launch fails', () async {
      mockNative(reply: false);
      expect(await service().openSettings(), isFalse);
    });
  });
}
