// test/capture/permission_analytics_test.dart
//
// Verifies the permission-funnel analytics: events fire on grant/deny
// TRANSITIONS only (request resolution + resume-detected changes), never on
// passive check()/resume re-checks, exactly once per transition, with correct
// properties — and that analytics failure never breaks the gate.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/data/local/permission_flow_box.dart';
import 'package:recapture/domain/entities/permission_flow_state.dart';
import 'package:recapture/domain/entities/permission_item.dart';
import 'package:recapture/platform/permissions_service.dart';
import 'package:recapture/presentation/screens/capture/permissions_screen.dart';
import 'package:recapture/utils/analytics.dart';

class _FakeService extends PermissionsService {
  _FakeService(this._statuses);

  final Map<AppPermissionType, AppPermissionStatus> _statuses;

  /// Result returned by request() per type (defaults to granted).
  final Map<AppPermissionType, AppPermissionStatus> requestResults = {};

  void setStatus(AppPermissionType t, AppPermissionStatus s) => _statuses[t] = s;

  @override
  Future<AppPermissionStatus> status(AppPermissionType type) async =>
      _statuses[type] ?? AppPermissionStatus.notRequested;

  @override
  Future<AppPermissionStatus> request(AppPermissionType type) async {
    final r = requestResults[type] ?? AppPermissionStatus.granted;
    _statuses[type] = r;
    return r;
  }
}

class _FakeFlowStore implements PermissionFlowStore {
  final Map<AppPermissionType, PermissionFlowState> _state = {};
  @override
  Future<PermissionFlowState> get(AppPermissionType type) async =>
      _state[type] ?? PermissionFlowState.initial;
  @override
  Future<void> markAsked(AppPermissionType type) async {}
  @override
  Future<void> markSkipped(AppPermissionType type) async {}
}

const _camera = AppPermissionType.camera;
const _motion = AppPermissionType.motion;
const _photos = AppPermissionType.photos;

typedef _Event = (String name, Map<String, Object?> props);

void main() {
  late List<_Event> events;

  setUp(() {
    events = [];
    Analytics.testSink = (name, props) => events.add((name, props));
  });
  tearDown(() => Analytics.testSink = null);

  List<_Event> only(String name) =>
      events.where((e) => e.$1 == name).toList();

  Future<_FakeService> pump(
    WidgetTester tester,
    Map<AppPermissionType, AppPermissionStatus> initial,
  ) async {
    final service = _FakeService({...initial});
    final router = GoRouter(
      initialLocation: AppRoutes.permissions,
      routes: [
        GoRoute(
          path: AppRoutes.permissions,
          name: AppRouteNames.permissions,
          builder: (_, __) =>
              PermissionsScreen(service: service, flowStore: _FakeFlowStore()),
        ),
        GoRoute(
          path: AppRoutes.levelAIntro,
          name: AppRouteNames.levelAIntro,
          builder: (_, __) => const Scaffold(body: Text('LEVEL_A_INTRO')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(theme: AppTheme.dark, routerConfig: router),
    );
    await tester.pumpAndSettle();
    return service;
  }

  Future<void> resume(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
  }

  testWidgets('granting Camera via prompt fires camera_granted once (source: prompt)',
      (tester) async {
    // Camera denied + others granted so only the Camera card offers "Allow".
    await pump(tester, {
      _camera: AppPermissionStatus.denied,
      _motion: AppPermissionStatus.granted,
      _photos: AppPermissionStatus.granted,
    });

    await tester.tap(find.text('Allow')); // the lone Camera Allow
    await tester.pumpAndSettle();

    final fired = only(AnalyticsEvents.permissionCameraGranted);
    expect(fired, hasLength(1));
    expect(fired.single.$2['source'], 'prompt');
    expect(only(AnalyticsEvents.permissionDenied), isEmpty);
  });

  testWidgets('a non-granted request fires permission_denied with correct props',
      (tester) async {
    final service = await pump(tester, {
      _camera: AppPermissionStatus.granted, // so only Motion shows "Allow"
      _motion: AppPermissionStatus.denied,
      _photos: AppPermissionStatus.granted,
    });
    service.requestResults[_motion] = AppPermissionStatus.permanentlyDenied;

    await tester.tap(find.text('Allow')); // the lone Motion Allow
    await tester.pumpAndSettle();

    final denied = only(AnalyticsEvents.permissionDenied);
    expect(denied, hasLength(1));
    expect(denied.single.$2, {
      'permission': 'motion',
      'status': 'permanentlyDenied',
      'criticality': 'recommended',
    });
    expect(only(AnalyticsEvents.permissionMotionGranted), isEmpty);
  });

  testWidgets('no events fire on initial load (baseline) even if already granted',
      (tester) async {
    await pump(tester, {
      _camera: AppPermissionStatus.granted,
      _motion: AppPermissionStatus.granted,
      _photos: AppPermissionStatus.granted,
    });

    expect(only(AnalyticsEvents.permissionCameraGranted), isEmpty);
    expect(only(AnalyticsEvents.permissionMotionGranted), isEmpty);
    expect(only(AnalyticsEvents.permissionDenied), isEmpty);
  });

  testWidgets('grant via Settings (resume transition) fires once with settings_return',
      (tester) async {
    final service = await pump(tester, {_camera: AppPermissionStatus.denied});

    // User grants Camera in Settings while backgrounded.
    service.setStatus(_camera, AppPermissionStatus.granted);
    await resume(tester);

    final fired = only(AnalyticsEvents.permissionCameraGranted);
    expect(fired, hasLength(1));
    expect(fired.single.$2['source'], 'settings_return');

    // A further resume with no change emits nothing more.
    await resume(tester);
    expect(only(AnalyticsEvents.permissionCameraGranted), hasLength(1));
  });

  testWidgets('passive resume with no status change emits nothing', (tester) async {
    await pump(tester, {
      _camera: AppPermissionStatus.denied,
      _motion: AppPermissionStatus.granted,
      _photos: AppPermissionStatus.granted,
    });
    events.clear();

    await resume(tester);
    await resume(tester);

    expect(events.where((e) => e.$1.startsWith('permission_')), isEmpty);
  });

  testWidgets('revocation in Settings (granted → denied on resume) fires permission_denied',
      (tester) async {
    final service = await pump(tester, {_camera: AppPermissionStatus.granted});

    service.setStatus(_camera, AppPermissionStatus.permanentlyDenied);
    await resume(tester);

    final denied = only(AnalyticsEvents.permissionDenied);
    expect(denied, hasLength(1));
    expect(denied.single.$2['permission'], 'camera');
    expect(denied.single.$2['status'], 'permanentlyDenied');
    expect(denied.single.$2['criticality'], 'required');
  });

  testWidgets('analytics failure never breaks the gate (fire-and-forget)',
      (tester) async {
    Analytics.testSink = (_, __) => throw StateError('analytics down');

    final service = await pump(tester, {
      _camera: AppPermissionStatus.denied,
      _motion: AppPermissionStatus.granted,
      _photos: AppPermissionStatus.granted,
    });
    service.requestResults[_camera] = AppPermissionStatus.granted;

    await tester.tap(find.text('Allow'));
    await tester.pumpAndSettle();

    // No exception surfaced, and the grant still enabled Continue.
    expect(tester.takeException(), isNull);
    final continueBtn = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Continue'));
    expect(continueBtn.onPressed, isNotNull);
  });
}
