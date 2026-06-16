// test/capture/permissions_screen_test.dart
//
// Tests for the Permissions Gate (Screen 4A), which already existed. They pin
// the behaviour the spec cares about, driving every status through a MOCKED
// PermissionsService so no real OS dialog is involved:
//   - per-status → action mapping on the card (Allow / Settings / granted-check)
//   - Continue gates on CAMERA ONLY (Motion/Photos never block)
//   - no OS request fires on load (only checkStatus)
//   - permanently-denied camera → Settings deep-link, Continue stays blocked
//   - statuses re-check on app resume (returning from Settings)
//   - Continue navigates exactly once, even on double-tap
//
// NOTE: this repo has no l10n (strings are inline) and ships no image assets
// (icons are IconData), matching the rest of the app.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/domain/entities/permission_item.dart';
import 'package:recapture/platform/permissions_service.dart';
import 'package:recapture/presentation/screens/capture/permissions_screen.dart';

// ── Mock service ──────────────────────────────────────────────────────────────

/// Drives statuses without the OS. Records calls so tests can assert that load
/// only CHECKS (never requests) and that double-taps don't double-prompt.
class _FakePermissionsService extends PermissionsService {
  _FakePermissionsService(this._statuses);

  final Map<AppPermissionType, AppPermissionStatus> _statuses;

  /// Result returned by [request] per type (defaults to granted).
  final Map<AppPermissionType, AppPermissionStatus> requestResult = {};

  int statusCalls = 0;
  final List<AppPermissionType> requested = [];
  int openSettingsCalls = 0;

  /// Controls whether [openSettings] reports success (Settings opened).
  bool settingsOpenResult = true;

  /// When set, [request] holds (after recording the attempt) until completed —
  /// lets a test keep one request in-flight while a second tap arrives.
  Completer<void>? gate;

  /// Same idea for [openSettings] — hold it open to test the debounce.
  Completer<void>? settingsGate;

  void setStatus(AppPermissionType t, AppPermissionStatus s) => _statuses[t] = s;

  @override
  Future<AppPermissionStatus> status(AppPermissionType type) async {
    statusCalls++;
    return _statuses[type] ?? AppPermissionStatus.notRequested;
  }

  @override
  Future<AppPermissionStatus> request(AppPermissionType type) async {
    requested.add(type);
    if (gate != null) await gate!.future;
    final r = requestResult[type] ?? AppPermissionStatus.granted;
    _statuses[type] = r;
    return r;
  }

  @override
  Future<bool> openSettings() async {
    openSettingsCalls++;
    if (settingsGate != null) await settingsGate!.future;
    return settingsOpenResult;
  }
}

class _PushSpy extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushes++;
}

// ── Harnesses ─────────────────────────────────────────────────────────────────

Future<_FakePermissionsService> _pumpScreen(
  WidgetTester tester,
  Map<AppPermissionType, AppPermissionStatus> initial,
) async {
  final fake = _FakePermissionsService({...initial});
  await tester.pumpWidget(
    MaterialApp(theme: AppTheme.dark, home: PermissionsScreen(service: fake)),
  );
  await tester.pumpAndSettle();
  return fake;
}

Future<(_FakePermissionsService, _PushSpy)> _pumpRouter(
  WidgetTester tester,
  Map<AppPermissionType, AppPermissionStatus> initial,
) async {
  final fake = _FakePermissionsService({...initial});
  final spy = _PushSpy();
  final router = GoRouter(
    initialLocation: AppRoutes.permissions,
    observers: [spy],
    routes: [
      GoRoute(
        path: AppRoutes.permissions,
        name: AppRouteNames.permissions,
        builder: (_, __) => PermissionsScreen(service: fake),
      ),
      GoRoute(
        path: AppRoutes.levelAIntro,
        name: AppRouteNames.levelAIntro,
        builder: (_, __) => const Scaffold(body: Text('LEVEL_A_INTRO')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(MaterialApp.router(theme: AppTheme.dark, routerConfig: router));
  await tester.pumpAndSettle();
  return (fake, spy);
}

ElevatedButton _continue(WidgetTester tester) =>
    tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Continue'));

const _camera = AppPermissionType.camera;
const _motion = AppPermissionType.motion;
const _photos = AppPermissionType.photos;

void main() {
  // ── Screen: gating + no auto-prompt ────────────────────────────────────────
  group('gating (Camera only)', () {
    testWidgets('first entry (all not-determined): Continue disabled, no OS request fires',
        (tester) async {
      final fake = await _pumpScreen(tester, {});

      expect(_continue(tester).onPressed, isNull); // blocked: camera not granted
      expect(fake.requested, isEmpty); // NOTHING requested on load
      expect(fake.statusCalls, greaterThanOrEqualTo(3)); // only checked
      expect(find.text('Allow'), findsNWidgets(3)); // every card offers Allow
    });

    testWidgets('Camera granted, Motion + Photos denied → Continue ENABLED', (tester) async {
      await _pumpScreen(tester, {
        _camera: AppPermissionStatus.granted,
        _motion: AppPermissionStatus.denied,
        _photos: AppPermissionStatus.denied,
      });
      expect(_continue(tester).onPressed, isNotNull);
    });

    testWidgets('Camera denied → Continue disabled regardless of Motion/Photos granted',
        (tester) async {
      await _pumpScreen(tester, {
        _camera: AppPermissionStatus.denied,
        _motion: AppPermissionStatus.granted,
        _photos: AppPermissionStatus.granted,
      });
      expect(_continue(tester).onPressed, isNull);
    });
  });

  // ── Screen: requesting ─────────────────────────────────────────────────────
  group('requesting Camera', () {
    testWidgets('tapping Allow requests once and, on grant, enables Continue',
        (tester) async {
      final fake = await _pumpScreen(tester, {
        _camera: AppPermissionStatus.notRequested,
        _motion: AppPermissionStatus.granted, // so only Camera shows "Allow"
        _photos: AppPermissionStatus.granted,
      });
      fake.requestResult[_camera] = AppPermissionStatus.granted;

      await tester.tap(find.text('Allow')); // the lone Camera Allow
      await tester.pumpAndSettle();

      expect(fake.requested, [_camera]);
      expect(_continue(tester).onPressed, isNotNull);
    });

    testWidgets('rapid double-tap on Allow does not double-prompt', (tester) async {
      final fake = await _pumpScreen(tester, {
        _camera: AppPermissionStatus.notRequested,
        _motion: AppPermissionStatus.granted,
        _photos: AppPermissionStatus.granted,
      });
      fake.requestResult[_camera] = AppPermissionStatus.granted;
      final gate = Completer<void>();
      fake.gate = gate; // hold the first request open so the second tap races it

      await tester.tap(find.text('Allow'));
      await tester.tap(find.text('Allow')); // second tap while the first is in-flight
      expect(fake.requested, [_camera]); // exactly one prompt — guard held

      gate.complete();
      await tester.pumpAndSettle();
      expect(fake.requested, [_camera]); // still one after it resolves
    });
  });

  // ── Screen: permanently denied → Settings ──────────────────────────────────
  group('Camera permanently denied', () {
    testWidgets('Continue stays disabled; Camera offers Settings → openSettings',
        (tester) async {
      final fake = await _pumpScreen(tester, {
        _camera: AppPermissionStatus.permanentlyDenied,
        _motion: AppPermissionStatus.granted,
        _photos: AppPermissionStatus.granted,
      });

      expect(_continue(tester).onPressed, isNull);
      expect(find.text('Settings'), findsOneWidget); // only the camera card

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(fake.openSettingsCalls, 1);
      expect(fake.requested, isEmpty); // no in-app request offered/used
    });
  });

  // ── Open Settings deep link (success / failure / debounce) ─────────────────
  group('Open Settings deep link', () {
    testWidgets('success: opens once, no fallback, no permission re-request',
        (tester) async {
      final fake = await _pumpScreen(tester, {_camera: AppPermissionStatus.permanentlyDenied});

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      expect(fake.openSettingsCalls, 1);
      expect(find.byType(AlertDialog), findsNothing); // opened fine → no fallback
      expect(fake.requested, isEmpty); // never re-requests a permanently-denied perm
      // The task awaits only "did Settings open", never a permission result — the
      // gate is unchanged until the resume re-check runs.
      expect(_continue(tester).onPressed, isNull);
    });

    testWidgets('failure: shows the localized manual-instructions fallback',
        (tester) async {
      final fake = await _pumpScreen(tester, {_camera: AppPermissionStatus.permanentlyDenied});
      fake.settingsOpenResult = false; // Settings could not be launched

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget); // not a silent failure
      expect(find.text("Can't open Settings"), findsOneWidget);
      expect(find.textContaining('enable the'), findsOneWidget); // manual steps
      expect(find.text('OK'), findsOneWidget);
    });

    testWidgets('debounce: rapid double-tap opens Settings once', (tester) async {
      final fake = await _pumpScreen(tester, {_camera: AppPermissionStatus.permanentlyDenied});
      final gate = Completer<void>();
      fake.settingsGate = gate; // hold the first open in-flight

      await tester.tap(find.text('Settings'));
      await tester.tap(find.text('Settings')); // second tap while first is pending
      expect(fake.openSettingsCalls, 1);

      gate.complete();
      await tester.pumpAndSettle();
      expect(fake.openSettingsCalls, 1);
    });
  });

  // ── Screen: resume re-check ────────────────────────────────────────────────
  group('resume re-check', () {
    testWidgets('granting Camera in Settings then returning enables Continue',
        (tester) async {
      final fake = await _pumpScreen(tester, {_camera: AppPermissionStatus.denied});
      expect(_continue(tester).onPressed, isNull);

      // User flips it in OS Settings while the app is backgrounded.
      fake.setStatus(_camera, AppPermissionStatus.granted);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(_continue(tester).onPressed, isNotNull); // gate updated on resume
    });
  });

  // ── Screen: navigation ─────────────────────────────────────────────────────
  group('Continue navigation', () {
    testWidgets('navigates to Level A intro exactly once, even on double-tap',
        (tester) async {
      final (_, spy) = await _pumpRouter(tester, {_camera: AppPermissionStatus.granted});
      final before = spy.pushes;

      await tester.tap(find.text('Continue'));
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('LEVEL_A_INTRO'), findsOneWidget);
      expect(spy.pushes - before, 1);
    });

    testWidgets('disabled Continue does not navigate', (tester) async {
      final (_, spy) = await _pumpRouter(tester, {_camera: AppPermissionStatus.denied});
      final before = spy.pushes;

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(spy.pushes - before, 0);
      expect(find.text('LEVEL_A_INTRO'), findsNothing);
    });
  });

  // ── Resilience ─────────────────────────────────────────────────────────────
  testWidgets('no overflow under a large text scale', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
        child: PermissionsScreen(service: _FakePermissionsService(const {})),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
