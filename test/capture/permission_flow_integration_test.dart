// test/capture/permission_flow_integration_test.dart
//
// Integration of the persisted permission FLOW state with the gate (Screen 4A):
//   - live OS status wins over stale flow state (revoked-in-Settings),
//   - resume re-checks live status and NEVER auto-fires the OS request,
//   - an explicit skip is persisted and not nagged,
//   - flow state is read through the gate's single lifecycle observer.
//
// Both the permission service and the flow store are injected fakes — no Hive,
// no OS.

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

/// Fake facade — drives live statuses and counts request() calls so a test can
/// assert the gate never auto-prompts.
class _FakeService extends PermissionsService {
  _FakeService(this._statuses);

  final Map<AppPermissionType, AppPermissionStatus> _statuses;
  int statusCalls = 0;
  final List<AppPermissionType> requested = [];

  void setStatus(AppPermissionType t, AppPermissionStatus s) => _statuses[t] = s;

  @override
  Future<AppPermissionStatus> status(AppPermissionType type) async {
    statusCalls++;
    return _statuses[type] ?? AppPermissionStatus.notRequested;
  }

  @override
  Future<AppPermissionStatus> request(AppPermissionType type) async {
    requested.add(type);
    final r = _statuses[type] ?? AppPermissionStatus.granted;
    _statuses[type] = r;
    return r;
  }
}

/// In-memory flow store — no Hive.
class _FakeFlowStore implements PermissionFlowStore {
  final Map<AppPermissionType, PermissionFlowState> _state = {};

  @override
  Future<PermissionFlowState> get(AppPermissionType type) async =>
      _state[type] ?? PermissionFlowState.initial;

  @override
  Future<void> markAsked(AppPermissionType type) async {
    _state[type] =
        (_state[type] ?? PermissionFlowState.initial).copyWith(hasBeenAsked: true);
  }

  @override
  Future<void> markSkipped(AppPermissionType type) async {
    _state[type] =
        (_state[type] ?? PermissionFlowState.initial).copyWith(userSkipped: true);
  }
}

const _camera = AppPermissionType.camera;
const _motion = AppPermissionType.motion;
const _photos = AppPermissionType.photos;
const _motionNag = 'Motion access improves AR tracking. You can continue without it.';

Future<(_FakeService, _FakeFlowStore)> _pump(
  WidgetTester tester,
  Map<AppPermissionType, AppPermissionStatus> initial, {
  _FakeFlowStore? store,
}) async {
  final service = _FakeService({...initial});
  final flow = store ?? _FakeFlowStore();
  // Router harness so the Continue CTA's goNamed() has a destination.
  final router = GoRouter(
    initialLocation: AppRoutes.permissions,
    routes: [
      GoRoute(
        path: AppRoutes.permissions,
        name: AppRouteNames.permissions,
        builder: (_, __) =>
            PermissionsScreen(service: service, flowStore: flow),
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
  return (service, flow);
}

ElevatedButton _continue(WidgetTester tester) =>
    tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Continue'));

void main() {
  testWidgets('live status wins over stale flow state (granted last run, now revoked)',
      (tester) async {
    // Flow store says camera was asked before (prior session granted it), but
    // the live check now reports it revoked in Settings.
    final store = _FakeFlowStore();
    await store.markAsked(_camera);

    await _pump(
      tester,
      {_camera: AppPermissionStatus.permanentlyDenied},
      store: store,
    );

    // Gate treats it as blocked (live wins) — Continue stays disabled.
    expect(_continue(tester).onPressed, isNull);
  });

  testWidgets('resume re-checks live status and never auto-requests',
      (tester) async {
    final (service, _) = await _pump(tester, {
      _camera: AppPermissionStatus.denied,
      _motion: AppPermissionStatus.denied,
      _photos: AppPermissionStatus.denied,
    });
    final statusCallsAfterLoad = service.statusCalls;

    // User grants camera in Settings while backgrounded.
    service.setStatus(_camera, AppPermissionStatus.granted);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    // Live re-check ran (more status calls) and upgraded the gate…
    expect(service.statusCalls, greaterThan(statusCallsAfterLoad));
    expect(_continue(tester).onPressed, isNotNull);
    // …but request() was NEVER fired automatically.
    expect(service.requested, isEmpty);
  });

  testWidgets('skipped Motion is persisted on Continue and not nagged afterwards',
      (tester) async {
    final store = _FakeFlowStore();
    final (_, flow) = await _pump(
      tester,
      {_camera: AppPermissionStatus.granted, _motion: AppPermissionStatus.denied},
      store: store,
    );

    // Motion denied + not yet skipped → the nag banner is shown.
    expect(find.text(_motionNag), findsOneWidget);

    // Proceeding past the gate marks Motion (ungranted, recommended) as skipped.
    await tester.tap(find.widgetWithText(ElevatedButton, 'Continue'));
    await tester.pumpAndSettle();
    expect((await flow.get(_motion)).userSkipped, isTrue);
  });

  testWidgets('a previously-skipped Motion shows no nag banner on load',
      (tester) async {
    final store = _FakeFlowStore();
    await store.markSkipped(_motion);

    await _pump(
      tester,
      {_camera: AppPermissionStatus.granted, _motion: AppPermissionStatus.denied},
      store: store,
    );

    // Respect the persisted skip — no nag even though Motion is still denied.
    expect(find.text(_motionNag), findsNothing);
  });

  testWidgets('requesting a permission persists hasBeenAsked', (tester) async {
    final store = _FakeFlowStore();
    // Motion + Photos granted so only the Camera card offers "Allow".
    await _pump(
      tester,
      {
        _camera: AppPermissionStatus.denied,
        _motion: AppPermissionStatus.granted,
        _photos: AppPermissionStatus.granted,
      },
      store: store,
    );

    await tester.tap(find.text('Allow')); // the lone Camera Allow
    await tester.pumpAndSettle();

    expect((await store.get(_camera)).hasBeenAsked, isTrue);
  });
}
