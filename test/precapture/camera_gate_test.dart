// test/precapture/camera_gate_test.dart
//
// Flow-level gating guarantee for Pre-Capture & Permissions:
//   Camera (required) denied  ⇒ held at the permissions gate; capture NOT reached.
//   Camera granted            ⇒ capture reachable (navigation fires once).
//   Motion / Photos (non-required) in any state ⇒ never block.
//   Camera permanentlyDenied  ⇒ blocked + "Settings" CTA, no in-app re-request.
//
// Hermetic: the PermissionService facade is MOCKED (no real OS / device /
// network). "Capture" downstream of the gate is the Level-A intro route
// (the gate's Continue → goNamed(levelAIntro)); a stub stands in for it so the
// test only proves *reachability*, not the capture experience.
//
// The gate's enforcement is its Continue-disabled logic (no separate route
// guard); the test asserts the end-to-end guarantee regardless of mechanism:
// camera denied ⇒ the capture route is never reached. A sabotage test proves
// that negative assertion is non-vacuous.

import 'dart:async';

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
import 'package:recapture/presentation/screens/capture/pre_capture_screen.dart';

// ── Mock seam: the permission facade ─────────────────────────────────────────
// Overrides every public method so platform routing / permission_handler / the
// native channel are never touched. Statuses are fully controllable per type.
class _FakeService extends PermissionsService {
  _FakeService(this._statuses);

  final Map<AppPermissionType, AppPermissionStatus> _statuses;

  /// Resolution returned by request() per type (defaults to granted).
  final Map<AppPermissionType, AppPermissionStatus> requestResults = {};

  /// Settings-launcher spy.
  int openSettingsCalls = 0;
  bool openSettingsResult = true;

  /// When set, openSettings() awaits this before resolving — lets a test hold
  /// the launch "in flight" so overlapping taps exercise the debounce guard
  /// (otherwise an instantly-resolving fake lets `_openingSettings` reset
  /// between awaited taps and the debounce can't be observed).
  Completer<bool>? holdOpenSettings;

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

  @override
  Future<bool> openSettings() async {
    openSettingsCalls++;
    if (holdOpenSettings != null) return holdOpenSettings!.future;
    return openSettingsResult;
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

/// Counts route pushes so "navigates exactly once" is provable. go_router's
/// `go()` fires didPush on the active observer (see pre_capture_screen_test).
class _PushSpy extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushes++;
}

const _camera = AppPermissionType.camera;
const _motion = AppPermissionType.motion;
const _photos = AppPermissionType.photos;
const _granted = AppPermissionStatus.granted;
const _denied = AppPermissionStatus.denied;
const _permDenied = AppPermissionStatus.permanentlyDenied;

const _captureMarker = 'LEVEL_A_INTRO'; // the stubbed capture destination

void main() {
  /// Builds a router whose `permissions` route hosts the real gate wired to
  /// [service], with a stub capture destination and (optionally) the real
  /// pre-capture checklist as the entry. Returns the push spy.
  ({GoRouter router, _PushSpy spy}) buildRouter(
    _FakeService service, {
    String initialLocation = AppRoutes.permissions,
    Widget Function(BuildContext, GoRouterState)? permissionsBuilder,
  }) {
    final spy = _PushSpy();
    final router = GoRouter(
      initialLocation: initialLocation,
      observers: [spy],
      routes: [
        GoRoute(
          path: AppRoutes.preCapture,
          name: AppRouteNames.preCapture,
          builder: (_, __) => const PreCaptureScreen(),
        ),
        GoRoute(
          path: AppRoutes.permissions,
          name: AppRouteNames.permissions,
          builder: permissionsBuilder ??
              (_, __) => PermissionsScreen(
                    service: service,
                    flowStore: _FakeFlowStore(),
                  ),
        ),
        GoRoute(
          path: AppRoutes.levelAIntro,
          name: AppRouteNames.levelAIntro,
          builder: (_, __) => const Scaffold(body: Text(_captureMarker)),
        ),
      ],
    );
    return (router: router, spy: spy);
  }

  /// Pumps the gate directly with the given live statuses. Returns the fake
  /// service + push spy for assertions.
  Future<({_FakeService service, _PushSpy spy})> pumpGate(
    WidgetTester tester,
    Map<AppPermissionType, AppPermissionStatus> statuses,
  ) async {
    final service = _FakeService({...statuses});
    final built = buildRouter(service);
    addTearDown(built.router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(theme: AppTheme.dark, routerConfig: built.router),
    );
    await tester.pumpAndSettle();
    return (service: service, spy: built.spy);
  }

  Future<void> resume(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
  }

  ElevatedButton continueButton(WidgetTester tester) => tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Continue'));

  Future<void> tapContinue(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(ElevatedButton, 'Continue'));
    await tester.pumpAndSettle();
  }

  // ── Camera denied blocks capture (the core guarantee) ──────────────────────
  group('camera denied → capture unreachable', () {
    testWidgets('gate is shown, Continue disabled, capture NOT reached', (tester) async {
      final r = await pumpGate(tester, {
        _camera: _denied,
        _motion: _granted,
        _photos: _granted,
      });
      final before = r.spy.pushes;

      // Gate is on screen; the capture destination is not.
      expect(find.text('Enable permissions'), findsOneWidget);
      expect(find.text(_captureMarker), findsNothing);

      // Continue is disabled (gated on Camera).
      expect(continueButton(tester).onPressed, isNull);

      // Tapping the disabled CTA does nothing — capture still not reached.
      await tapContinue(tester);
      expect(find.text(_captureMarker), findsNothing);
      expect(r.spy.pushes - before, 0);
    });

    testWidgets('rapid repeated proceed attempts never leak through to capture',
        (tester) async {
      final r = await pumpGate(tester, {
        _camera: _denied,
        _motion: _granted,
        _photos: _granted,
      });
      final before = r.spy.pushes;

      for (var i = 0; i < 5; i++) {
        await tester.tap(find.widgetWithText(ElevatedButton, 'Continue'));
      }
      await tester.pumpAndSettle();

      expect(find.text(_captureMarker), findsNothing);
      expect(r.spy.pushes - before, 0);
    });
  });

  // ── Camera granted allows capture ──────────────────────────────────────────
  group('camera granted → capture reachable', () {
    testWidgets('Continue enabled; capture reached; navigation fires exactly once',
        (tester) async {
      final r = await pumpGate(tester, {
        _camera: _granted,
        _motion: _granted,
        _photos: _granted,
      });
      final before = r.spy.pushes;

      expect(continueButton(tester).onPressed, isNotNull);

      await tapContinue(tester);
      expect(find.text(_captureMarker), findsOneWidget);
      expect(r.spy.pushes - before, 1);
    });

    testWidgets('double-tap Continue still reaches capture exactly once', (tester) async {
      final r = await pumpGate(tester, {_camera: _granted});
      final before = r.spy.pushes;

      await tester.tap(find.widgetWithText(ElevatedButton, 'Continue'));
      await tester.tap(find.widgetWithText(ElevatedButton, 'Continue'));
      await tester.pumpAndSettle();

      expect(find.text(_captureMarker), findsOneWidget);
      expect(r.spy.pushes - before, 1);
    });
  });

  // ── Only Camera gates: Motion/Photos must not block ────────────────────────
  group('non-required permissions never block', () {
    testWidgets('camera granted + Motion denied + Photos denied → capture reachable',
        (tester) async {
      final r = await pumpGate(tester, {
        _camera: _granted,
        _motion: _denied,
        _photos: _denied,
      });
      final before = r.spy.pushes;

      // Continue is enabled despite Motion/Photos being denied.
      expect(continueButton(tester).onPressed, isNotNull);

      await tapContinue(tester);
      expect(find.text(_captureMarker), findsOneWidget);
      expect(r.spy.pushes - before, 1);
    });

    testWidgets('camera granted + Motion/Photos permanentlyDenied → still reachable',
        (tester) async {
      await pumpGate(tester, {
        _camera: _granted,
        _motion: _permDenied,
        _photos: _permDenied,
      });
      expect(continueButton(tester).onPressed, isNotNull);
      await tapContinue(tester);
      expect(find.text(_captureMarker), findsOneWidget);
    });
  });

  // ── Permanently-denied: blocked + Settings, no in-app re-request ───────────
  group('camera permanentlyDenied', () {
    testWidgets('capture blocked; "Settings" CTA shown; no "Allow"; Continue disabled',
        (tester) async {
      await pumpGate(tester, {
        _camera: _permDenied,
        _motion: _granted,
        _photos: _granted,
      });

      // The recovery path is Settings — never an in-app re-prompt.
      expect(find.widgetWithText(TextButton, 'Settings'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Allow'), findsNothing);
      expect(continueButton(tester).onPressed, isNull);
      expect(find.text(_captureMarker), findsNothing);
    });

    testWidgets('tapping "Settings" routes to the launcher exactly once (debounced)',
        (tester) async {
      final r = await pumpGate(tester, {
        _camera: _permDenied,
        _motion: _granted,
        _photos: _granted,
      });

      // Hold the launch in flight so the two taps genuinely overlap.
      r.service.holdOpenSettings = Completer<bool>();

      // Rapid double-tap must still launch Settings only once (debounced).
      await tester.tap(find.widgetWithText(TextButton, 'Settings'));
      await tester.tap(find.widgetWithText(TextButton, 'Settings'));
      expect(r.service.openSettingsCalls, 1);

      // Release the launch and settle.
      r.service.holdOpenSettings!.complete(true);
      await tester.pumpAndSettle();

      // Opening Settings does not itself reach capture.
      expect(find.text(_captureMarker), findsNothing);
    });

    testWidgets('enable in Settings then resume → capture becomes reachable',
        (tester) async {
      final r = await pumpGate(tester, {
        _camera: _permDenied,
        _motion: _granted,
        _photos: _granted,
      });
      expect(continueButton(tester).onPressed, isNull);

      // User flips Camera on in Settings; the resume re-check observes it live.
      r.service.setStatus(_camera, _granted);
      await resume(tester);

      expect(continueButton(tester).onPressed, isNotNull);
      await tapContinue(tester);
      expect(find.text(_captureMarker), findsOneWidget);
    });
  });

  // ── End-to-end: checklist (Screen 4) → gate → capture ──────────────────────
  group('full pre-capture flow', () {
    Future<({_FakeService service, _PushSpy spy})> pumpFromChecklist(
      WidgetTester tester,
      Map<AppPermissionType, AppPermissionStatus> statuses,
    ) async {
      final service = _FakeService({...statuses});
      final built = buildRouter(service, initialLocation: AppRoutes.preCapture);
      addTearDown(built.router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(theme: AppTheme.dark, routerConfig: built.router),
      );
      await tester.pumpAndSettle();
      return (service: service, spy: built.spy);
    }

    Future<void> acknowledgeAllAndStart(WidgetTester tester) async {
      final boxes = find.byType(Checkbox);
      for (var i = 0; i < boxes.evaluate().length; i++) {
        await tester.tap(boxes.at(i));
      }
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start Capture'));
      await tester.pumpAndSettle();
    }

    testWidgets('camera granted: checklist → gate → capture reachable end-to-end',
        (tester) async {
      await pumpFromChecklist(tester, {
        _camera: _granted,
        _motion: _granted,
        _photos: _granted,
      });

      await acknowledgeAllAndStart(tester); // → permissions gate
      expect(find.text('Enable permissions'), findsOneWidget);

      await tapContinue(tester); // → capture
      expect(find.text(_captureMarker), findsOneWidget);
    });

    testWidgets('camera denied: checklist → gate → held, capture unreachable',
        (tester) async {
      await pumpFromChecklist(tester, {
        _camera: _denied,
        _motion: _granted,
        _photos: _granted,
      });

      await acknowledgeAllAndStart(tester); // → permissions gate
      expect(find.text('Enable permissions'), findsOneWidget);
      expect(continueButton(tester).onPressed, isNull);

      await tapContinue(tester);
      expect(find.text(_captureMarker), findsNothing);
    });
  });

  // ── Non-vacuity / sabotage ────────────────────────────────────────────────
  // Production code is NOT modified. Instead we point the `permissions` route at
  // a deliberately-broken gate whose Continue is ALWAYS enabled, and show that
  // the SAME "capture not reached" assertion the real-gate test relies on would
  // FAIL against it (capture IS reached under camera denied). This proves the
  // negative assertion is a real check — it passes for the real gate only
  // because the gate genuinely blocks.
  testWidgets('SABOTAGE: an always-enabled gate reaches capture under camera denied',
      (tester) async {
    final service = _FakeService({_camera: _denied});
    final built = buildRouter(
      service,
      permissionsBuilder: (context, __) => Scaffold(
        appBar: AppBar(title: const Text('Enable permissions')),
        body: Center(
          child: ElevatedButton(
            // BUG: ignores camera status entirely.
            onPressed: () => context.goNamed(AppRouteNames.levelAIntro),
            child: const Text('Continue'),
          ),
        ),
      ),
    );
    addTearDown(built.router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(theme: AppTheme.dark, routerConfig: built.router),
    );
    await tester.pumpAndSettle();

    await tapContinue(tester);

    // The broken gate leaks through — exactly what the real-gate negative
    // assertion (findsNothing) catches. The detector is therefore non-vacuous.
    expect(find.text(_captureMarker), findsOneWidget);
  });
}
