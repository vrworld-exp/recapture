// test/platform/permission_facade_test.dart
//
// Tests the unified permission facade (PermissionsService): the two backend
// normalizers (exhaustively), routing dispatch per (permission, platform) with
// fake backends, settings routing, the loud failure on a missing/unsupported
// route, and the encapsulation guardrail (permission_handler confined to the
// facade). No real OS calls — both backends are injected fakes.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:recapture/domain/entities/permission_item.dart';
import 'package:recapture/platform/permissions/android_permission_channel.dart';
import 'package:recapture/platform/permissions_service.dart';

/// Fake Android native channel — records calls, returns a fixed status string.
class _FakeAndroidChannel extends AndroidPermissionChannel {
  _FakeAndroidChannel(this.reply);

  final String reply;
  final List<String> checks = [];
  final List<String> requests = [];
  int settingsCalls = 0;
  bool settingsResult = true;

  @override
  Future<String> check(String permission) async {
    checks.add(permission);
    return reply;
  }

  @override
  Future<String> request(String permission) async {
    requests.add(permission);
    return reply;
  }

  @override
  Future<bool> openAppSettings() async {
    settingsCalls++;
    return settingsResult;
  }
}

/// Fake permission_handler backend — records calls, returns a fixed status.
class _FakeHandler extends PermissionHandlerBackend {
  _FakeHandler(this.reply);

  final ph.PermissionStatus reply;
  final List<ph.Permission> statuses = [];
  final List<ph.Permission> requests = [];
  int settingsCalls = 0;
  bool settingsResult = true;

  @override
  Future<ph.PermissionStatus> status(ph.Permission permission) async {
    statuses.add(permission);
    return reply;
  }

  @override
  Future<ph.PermissionStatus> request(ph.Permission permission) async {
    requests.add(permission);
    return reply;
  }

  @override
  Future<bool> openAppSettings() async {
    settingsCalls++;
    return settingsResult;
  }
}

PermissionsService _service(
  TargetPlatform platform, {
  required _FakeAndroidChannel android,
  required _FakeHandler handler,
}) =>
    PermissionsService(
      android: android,
      handler: handler,
      platformOverride: platform,
    );

void main() {
  group('normalizeHandlerStatus (permission_handler → AppPermissionStatus)', () {
    test('is exhaustive over PermissionStatus (no value throws)', () {
      for (final s in ph.PermissionStatus.values) {
        expect(normalizeHandlerStatus(s), isA<AppPermissionStatus>());
      }
    });

    test('maps each value to the expected app status', () {
      expect(normalizeHandlerStatus(ph.PermissionStatus.granted),
          AppPermissionStatus.granted);
      expect(normalizeHandlerStatus(ph.PermissionStatus.limited),
          AppPermissionStatus.granted);
      expect(normalizeHandlerStatus(ph.PermissionStatus.provisional),
          AppPermissionStatus.granted);
      expect(normalizeHandlerStatus(ph.PermissionStatus.denied),
          AppPermissionStatus.denied);
      expect(normalizeHandlerStatus(ph.PermissionStatus.permanentlyDenied),
          AppPermissionStatus.permanentlyDenied);
      expect(normalizeHandlerStatus(ph.PermissionStatus.restricted),
          AppPermissionStatus.restricted);
    });
  });

  group('normalizeNativeStatus (channel string → AppPermissionStatus)', () {
    test('maps the full native vocabulary', () {
      expect(normalizeNativeStatus('granted'), AppPermissionStatus.granted);
      expect(normalizeNativeStatus('limited'), AppPermissionStatus.granted);
      expect(normalizeNativeStatus('unavailable'), AppPermissionStatus.granted);
      expect(normalizeNativeStatus('denied'), AppPermissionStatus.denied);
      expect(normalizeNativeStatus('permanentlyDenied'),
          AppPermissionStatus.permanentlyDenied);
      expect(normalizeNativeStatus('restricted'),
          AppPermissionStatus.restricted);
    });

    test('unknown strings default to denied (safe, re-promptable)', () {
      expect(normalizeNativeStatus('totally-unknown'),
          AppPermissionStatus.denied);
      expect(normalizeNativeStatus(''), AppPermissionStatus.denied);
    });
  });

  group('routing dispatch — Android', () {
    test('camera/photos → native channel (logical keys), motion → neither',
        () async {
      final android = _FakeAndroidChannel('granted');
      final handler = _FakeHandler(ph.PermissionStatus.granted);
      final svc = _service(TargetPlatform.android,
          android: android, handler: handler);

      expect(await svc.status(AppPermissionType.camera),
          AppPermissionStatus.granted);
      expect(await svc.status(AppPermissionType.photos),
          AppPermissionStatus.granted);
      expect(await svc.status(AppPermissionType.motion),
          AppPermissionStatus.granted);
      await svc.request(AppPermissionType.camera);

      expect(android.checks, ['camera', 'storage']); // photos → storage key
      expect(android.requests, ['camera']);
      expect(handler.statuses, isEmpty); // permission_handler never touched
      expect(handler.requests, isEmpty);
    });
  });

  group('routing dispatch — iOS', () {
    test('camera/photos → permission_handler, motion → neither', () async {
      final android = _FakeAndroidChannel('granted');
      final handler = _FakeHandler(ph.PermissionStatus.granted);
      final svc =
          _service(TargetPlatform.iOS, android: android, handler: handler);

      expect(await svc.status(AppPermissionType.camera),
          AppPermissionStatus.granted);
      expect(await svc.status(AppPermissionType.photos),
          AppPermissionStatus.granted);
      expect(await svc.status(AppPermissionType.motion),
          AppPermissionStatus.granted);

      expect(handler.statuses, [ph.Permission.camera, ph.Permission.photos]);
      expect(android.checks, isEmpty); // native channel never touched on iOS
    });
  });

  test('a permission routed differently per platform yields the same status',
      () async {
    // photos: androidNative on Android, permission_handler on iOS — both denied.
    final androidSvc = _service(
      TargetPlatform.android,
      android: _FakeAndroidChannel('denied'),
      handler: _FakeHandler(ph.PermissionStatus.granted),
    );
    final iosSvc = _service(
      TargetPlatform.iOS,
      android: _FakeAndroidChannel('granted'),
      handler: _FakeHandler(ph.PermissionStatus.denied),
    );
    expect(await androidSvc.status(AppPermissionType.photos),
        AppPermissionStatus.denied);
    expect(await iosSvc.status(AppPermissionType.photos),
        AppPermissionStatus.denied);
  });

  group('openSettings routing', () {
    test('Android → native channel only', () async {
      final android = _FakeAndroidChannel('granted');
      final handler = _FakeHandler(ph.PermissionStatus.granted);
      final svc = _service(TargetPlatform.android,
          android: android, handler: handler);

      expect(await svc.openSettings(), isTrue);
      expect(android.settingsCalls, 1);
      expect(handler.settingsCalls, 0);
    });

    test('iOS → permission_handler only', () async {
      final android = _FakeAndroidChannel('granted');
      final handler = _FakeHandler(ph.PermissionStatus.granted);
      final svc =
          _service(TargetPlatform.iOS, android: android, handler: handler);

      expect(await svc.openSettings(), isTrue);
      expect(handler.settingsCalls, 1);
      expect(android.settingsCalls, 0);
    });
  });

  group('missing / unsupported route fails loudly', () {
    test('an unsupported platform throws (not a silent no-op)', () async {
      final svc = _service(
        TargetPlatform.windows,
        android: _FakeAndroidChannel('granted'),
        handler: _FakeHandler(ph.PermissionStatus.granted),
      );
      await expectLater(
          svc.status(AppPermissionType.camera), throwsStateError);
      await expectLater(
          svc.request(AppPermissionType.camera), throwsStateError);
      expect(svc.openSettings, throwsStateError);
    });
  });

  test('encapsulation: permission_handler is used only via the facade', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final normalized = entity.path.replaceAll(r'\', '/');
      if (normalized.endsWith('lib/platform/permissions_service.dart')) continue;
      if (entity.readAsStringSync().contains('package:permission_handler')) {
        offenders.add(normalized);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'permission_handler must be reached only through PermissionsService; '
          'found direct use in: $offenders',
    );
  });
}
