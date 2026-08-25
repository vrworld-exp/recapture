// test/precapture/android_dont_ask_again_test.dart
//
// Android flow-level contract: in the permissions gate (Screen 4A) the
// permission CTA correctly distinguishes the two states that BOTH report
// `shouldShowRequestPermissionRationale == false` on Android:
//   • never-asked       → "Allow"    (re-promptable in-app)        ← NOT Settings
//   • "Don't ask again" → "Settings" (permanentlyDenied recovery)  ← NOT Allow
// and that tapping "Settings" routes to the launcher exactly once.
//
// LABEL NOTE: the real card (PermissionCard) renders the re-prompt action as
// "Allow" (the task's generic "Grant") and the recovery action as "Settings"
// (the task's "Open Settings"). VOCAB NOTE: there is no `notDetermined` enum;
// "never-asked" surfaces as `notRequested` (pre-check default) or, post-check
// on Android, as `denied` (re-promptable) — both render "Allow". Both are
// covered. The exhaustive per-status card matrix lives in
// test/widgets/permission_card_test.dart; THIS test asserts the mapping in the
// Android GATE flow and protects the never-asked-vs-permanently-denied split.
//
// The native side that actually PRODUCES `denied` vs `permanentlyDenied` (the
// requested-before flag + shouldShowRequestPermissionRationale, in
// PermissionManager.kt) cannot be exercised by a widget test — it is verified by
// the documented matrix in docs/qa/android-permission-detection-matrix.md.
//
// Hermetic: Android forced (Theme), facade + settings launcher mocked, no device.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/data/local/permission_flow_box.dart';
import 'package:recapture/domain/entities/permission_flow_state.dart';
import 'package:recapture/domain/entities/permission_item.dart';
import 'package:recapture/platform/permissions_service.dart';
import 'package:recapture/presentation/screens/capture/permissions_screen.dart';

const _camera = AppPermissionType.camera;
const _motion = AppPermissionType.motion;
const _photos = AppPermissionType.photos;
const _granted = AppPermissionStatus.granted;
const _denied = AppPermissionStatus.denied;
const _notRequested = AppPermissionStatus.notRequested;
const _permDenied = AppPermissionStatus.permanentlyDenied;
const _restricted = AppPermissionStatus.restricted;

class _SpyService extends PermissionsService {
  _SpyService(this._statuses);

  final Map<AppPermissionType, AppPermissionStatus> _statuses;

  int openSettingsCalls = 0;
  bool openSettingsResult = true;

  /// When set, openSettings() awaits this before resolving — lets a test hold the
  /// launch "in flight" so overlapping taps actually exercise the debounce.
  Completer<bool>? holdOpenSettings;

  void setStatus(AppPermissionType t, AppPermissionStatus s) => _statuses[t] = s;

  @override
  Future<AppPermissionStatus> status(AppPermissionType type) async =>
      _statuses[type] ?? AppPermissionStatus.notRequested;

  @override
  Future<AppPermissionStatus> request(AppPermissionType type) async => _granted;

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

// The CTA finders the whole suite asserts on (precise: TextButton label, so the
// camera-required footer banner's "…Enable it in Settings." sentence never
// matches the "Settings" button).
final _allowCta = find.widgetWithText(TextButton, 'Allow');
final _settingsCta = find.widgetWithText(TextButton, 'Settings');

void main() {
  Widget host(_SpyService service) => MaterialApp(
        // Force Android — what Theme.of(context).platform reports.
        theme: AppTheme.dark.copyWith(platform: TargetPlatform.android),
        home: PermissionsScreen(service: service, flowStore: _FakeFlowStore()),
      );

  Future<_SpyService> pumpGate(
    WidgetTester tester,
    Map<AppPermissionType, AppPermissionStatus> statuses,
  ) async {
    final service = _SpyService({...statuses});
    await tester.pumpWidget(host(service));
    await tester.pumpAndSettle();
    return service;
  }

  /// Drives ONE permission to [status] with the others granted (so any Allow /
  /// Settings CTA on screen belongs unambiguously to [target]).
  Future<_SpyService> pumpOnly(
    WidgetTester tester,
    AppPermissionType target,
    AppPermissionStatus status,
  ) =>
      pumpGate(tester, {
        for (final t in AppPermissionType.values) t: _granted,
        target: status,
      });

  Future<void> resume(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
  }

  // ── Status → CTA in the Android gate ───────────────────────────────────────
  group('status → CTA (Android gate)', () {
    testWidgets('permanentlyDenied → "Settings", never "Allow"', (tester) async {
      await pumpOnly(tester, _camera, _permDenied);
      expect(_settingsCta, findsOneWidget);
      expect(_allowCta, findsNothing);
    });

    testWidgets('never-asked (notRequested) → "Allow", never "Settings"',
        (tester) async {
      await pumpOnly(tester, _camera, _notRequested);
      expect(_allowCta, findsOneWidget);
      expect(_settingsCta, findsNothing);
    });

    testWidgets('denied (re-askable, Android never-asked surfaces here) → "Allow"',
        (tester) async {
      await pumpOnly(tester, _camera, _denied);
      expect(_allowCta, findsOneWidget);
      expect(_settingsCta, findsNothing);
    });

    testWidgets('restricted → "Settings" (recovery path)', (tester) async {
      await pumpOnly(tester, _camera, _restricted);
      expect(_settingsCta, findsOneWidget);
      expect(_allowCta, findsNothing);
    });

    testWidgets('granted → no Allow / Settings CTA (status chip only)',
        (tester) async {
      await pumpGate(tester, {
        _camera: _granted,
        _motion: _granted,
        _photos: _granted,
      });
      expect(_allowCta, findsNothing);
      expect(_settingsCta, findsNothing);
      expect(find.text('Granted'), findsWidgets);
    });
  });

  // ── The crux: never-asked vs permanently-denied render DIFFERENT CTAs ───────
  group('never-asked vs permanently-denied distinction', () {
    testWidgets('side-by-side (notRequested vs permanentlyDenied) → Allow vs Settings',
        (tester) async {
      // Both report shouldShowRationale==false on Android; the requested-before
      // flag is what separates them, and the gate must reflect that split.
      await pumpGate(tester, {
        _camera: _notRequested, // never asked → Allow
        _motion: _granted,
        _photos: _permDenied, // don't-ask-again → Settings
      });

      expect(_allowCta, findsOneWidget);
      expect(_settingsCta, findsOneWidget);
    });

    testWidgets('side-by-side (denied vs permanentlyDenied) → Allow vs Settings',
        (tester) async {
      // The post-check Android shape: re-promptable `denied` vs `permanentlyDenied`.
      await pumpGate(tester, {
        _camera: _denied, // re-promptable → Allow
        _motion: _granted,
        _photos: _permDenied, // → Settings
      });

      expect(_allowCta, findsOneWidget);
      expect(_settingsCta, findsOneWidget);
    });
  });

  // ── Settings routing ───────────────────────────────────────────────────────
  group('Settings CTA routing', () {
    testWidgets('tapping "Settings" invokes the launcher exactly once',
        (tester) async {
      final s = await pumpOnly(tester, _camera, _permDenied);

      await tester.tap(_settingsCta);
      await tester.pumpAndSettle();

      expect(s.openSettingsCalls, 1);
    });

    testWidgets('rapid double-tap on "Settings" launches once (debounced)',
        (tester) async {
      final s = await pumpOnly(tester, _camera, _permDenied);

      // Hold the launch in flight so the two taps genuinely overlap.
      s.holdOpenSettings = Completer<bool>();

      await tester.tap(_settingsCta);
      await tester.tap(_settingsCta);
      expect(s.openSettingsCalls, 1);

      s.holdOpenSettings!.complete(true);
      await tester.pumpAndSettle();
    });
  });

  // ── Resume after enabling in Settings ──────────────────────────────────────
  group('resume after Settings', () {
    testWidgets('grant in Settings + resume → CTA updates away from Settings',
        (tester) async {
      final s = await pumpOnly(tester, _camera, _permDenied);
      expect(_settingsCta, findsOneWidget);

      // User enables Camera in Settings; the gate's resume re-check observes it.
      s.setStatus(_camera, _granted);
      await resume(tester);

      expect(_settingsCta, findsNothing);
      expect(_allowCta, findsNothing);
      expect(find.text('Granted'), findsWidgets);
    });
  });

  // ── Sabotage (non-vacuity) — no production code is modified ─────────────────
  // The real gate builds PermissionCard internally; we can't inject a broken
  // card without editing production. Instead we render local mis-mapped stand-ins
  // and show the SAME CTA finders the core tests rely on yield the WRONG result —
  // proving those finders genuinely distinguish "Allow" from "Settings".
  group('sabotage proves the CTA assertions are non-vacuous', () {
    testWidgets('A: a card showing "Allow" for permanentlyDenied breaks the Settings assertion',
        (tester) async {
      await tester.pumpWidget(_sabotageHost(label: 'Allow'));
      await tester.pumpAndSettle();

      // The permanently-denied assertion is (Settings present, Allow absent).
      // Against this broken card it is inverted → that assertion WOULD fail.
      expect(_settingsCta, findsNothing);
      expect(_allowCta, findsOneWidget);
    });

    testWidgets('B: a card showing "Settings" for notRequested breaks the never-asked assertion',
        (tester) async {
      await tester.pumpWidget(_sabotageHost(label: 'Settings'));
      await tester.pumpAndSettle();

      // The never-asked assertion is (Allow present, Settings absent). Inverted
      // here → that assertion WOULD fail.
      expect(_allowCta, findsNothing);
      expect(_settingsCta, findsOneWidget);
    });
  });
}

/// A deliberately mis-mapped card stand-in that renders [label] as its CTA
/// regardless of the (implied) status — used only by the sabotage checks.
Widget _sabotageHost({required String label}) => MaterialApp(
      theme: AppTheme.dark.copyWith(platform: TargetPlatform.android),
      home: Scaffold(
        body: Center(
          child: TextButton(onPressed: () {}, child: Text(label)),
        ),
      ),
    );
