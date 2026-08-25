// test/precapture/ios_motion_prompt_test.dart
//
// iOS contract: the Motion permission prompt is triggered ONLY by an explicit
// user action — never on app launch, gate load, rebuild/rotation, or the
// app-resume re-check.
//
// ARCHITECTURE NOTE (divergence from the generic iOS implicit-prompt spec):
// In THIS product Motion is PERMISSION-FREE on both platforms (raw IMU — there
// is NO `CMMotionActivityManager`; see _routingTable: motion → permissionFree).
// So `status(motion)` / `request(motion)` resolve to `granted` WITHOUT touching
// any backend and CANNOT pop an OS prompt at all. The task's "prompt-triggering
// CMMotion query" therefore does not exist here. Following the task's own
// guidance ("if the implementation differs, mock the actual prompt-triggering
// call / report rather than hack"), this test asserts the contract at the real
// seam, the `PermissionService` facade:
//   • check(motion)   = `status(motion)`  — the non-prompting status read.
//   • prompt-trigger  = `request(motion)` — the ONLY path that, on a real OS,
//     could ever issue a prompt. The gate must invoke it ONLY on a user tap.
// Plus a STRUCTURAL proof that on iOS `request(motion)` can never reach any
// prompting backend — the strongest form of "a check never routes to a query"
// (here, neither check NOR request can).
//
// Hermetic: iOS forced, all seams mocked, no device / real Core Motion.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/data/local/permission_flow_box.dart';
import 'package:recapture/domain/entities/permission_flow_state.dart';
import 'package:recapture/domain/entities/permission_item.dart';
import 'package:recapture/platform/permissions/android_permission_channel.dart';
import 'package:recapture/platform/permissions_service.dart';
import 'package:recapture/presentation/screens/capture/permissions_screen.dart';

const _camera = AppPermissionType.camera;
const _motion = AppPermissionType.motion;
const _photos = AppPermissionType.photos;
const _granted = AppPermissionStatus.granted;
const _denied = AppPermissionStatus.denied;

// ── Facade spy: distinguishes the non-prompting check from the prompt-trigger ─
// status(type)  → "check"          (non-prompting; runs on load/resume)
// request(type) → "prompt-trigger" (the only call that may prompt; user-action)
class _SpyService extends PermissionsService {
  _SpyService(this._statuses);

  final Map<AppPermissionType, AppPermissionStatus> _statuses;
  final Map<AppPermissionType, AppPermissionStatus> requestResults = {};

  final List<AppPermissionType> checkCalls = [];
  final List<AppPermissionType> requestCalls = [];

  /// When set, request() records the call then awaits this before resolving —
  /// lets a test hold the "prompt" in flight so overlapping taps actually
  /// exercise the gate's in-flight guard.
  Completer<void>? holdRequest;

  int checkCount(AppPermissionType t) => checkCalls.where((e) => e == t).length;
  int requestCount(AppPermissionType t) =>
      requestCalls.where((e) => e == t).length;

  void setStatus(AppPermissionType t, AppPermissionStatus s) => _statuses[t] = s;

  @override
  Future<AppPermissionStatus> status(AppPermissionType type) async {
    checkCalls.add(type);
    return _statuses[type] ?? AppPermissionStatus.notRequested;
  }

  @override
  Future<AppPermissionStatus> request(AppPermissionType type) async {
    requestCalls.add(type);
    if (holdRequest != null) await holdRequest!.future;
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

// ── Fake facade backends (for the structural proof) — match the facade test ──
class _SpyAndroid extends AndroidPermissionChannel {
  _SpyAndroid() : super();
  int checkCalls = 0;
  int requestCalls = 0;
  @override
  Future<String> check(String permission) async {
    checkCalls++;
    return AndroidPermissionStatus.granted;
  }

  @override
  Future<String> request(String permission) async {
    requestCalls++;
    return AndroidPermissionStatus.granted;
  }
}

class _SpyHandler extends PermissionHandlerBackend {
  int statusCalls = 0;
  int requestCalls = 0;
  @override
  Future<ph.PermissionStatus> status(ph.Permission permission) async {
    statusCalls++;
    return ph.PermissionStatus.granted;
  }

  @override
  Future<ph.PermissionStatus> request(ph.Permission permission) async {
    requestCalls++;
    return ph.PermissionStatus.granted;
  }
}

void main() {
  // iOS is forced where it MATTERS: the facade routing (structural test passes
  // `platformOverride: iOS`) and the gate's Theme platform (`copyWith(platform:
  // iOS)` below). The gate's prompt logic never branches on `defaultTargetPlatform`
  // (only its analytics `device_type` string does), so the global foundation
  // override is intentionally avoided — the test framework forbids leaving it set
  // past the test body, and it would change nothing about the motion seam here.

  // The gate references go_router only inside callbacks we never tap here, so a
  // plain MaterialApp host is enough (and lets us force rebuilds cheaply).
  Widget host(_SpyService service, PermissionFlowStore flow) => MaterialApp(
        theme: AppTheme.dark.copyWith(platform: TargetPlatform.iOS),
        home: PermissionsScreen(service: service, flowStore: flow),
      );

  Future<_SpyService> pumpGate(
    WidgetTester tester,
    Map<AppPermissionType, AppPermissionStatus> statuses, {
    PermissionFlowStore? flow,
  }) async {
    final service = _SpyService({...statuses});
    await tester.pumpWidget(host(service, flow ?? _FakeFlowStore()));
    await tester.pumpAndSettle();
    return service;
  }

  Future<void> resume(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
  }

  // ── Structural proof: iOS request(motion) can never reach a prompting backend
  group('facade structural contract (iOS motion is permission-free)', () {
    test('status(motion) AND request(motion) touch NO backend → cannot prompt',
        () async {
      final android = _SpyAndroid();
      final handler = _SpyHandler();
      final svc = PermissionsService(
        android: android,
        handler: handler,
        platformOverride: TargetPlatform.iOS,
      );

      expect(await svc.status(_motion), _granted);
      expect(await svc.request(_motion), _granted); // the "prompt-trigger" path

      // Neither the plugin nor the native channel was invoked for motion: there
      // is no query, so no CMMotion prompt can fire — on load OR on request.
      expect(handler.statusCalls, 0);
      expect(handler.requestCalls, 0);
      expect(android.checkCalls, 0);
      expect(android.requestCalls, 0);
    });

    test('positive control: camera on iOS DOES route to the handler (spy works)',
        () async {
      final android = _SpyAndroid();
      final handler = _SpyHandler();
      final svc = PermissionsService(
        android: android,
        handler: handler,
        platformOverride: TargetPlatform.iOS,
      );

      await svc.status(_camera);
      await svc.request(_camera);
      // Proves the zero-for-motion above is meaningful, not a dead spy.
      expect(handler.statusCalls, 1);
      expect(handler.requestCalls, 1);
    });
  });

  // ── Gate: no prompt-trigger without a user action ──────────────────────────
  group('gate issues NO prompt-trigger on load / rebuild / resume', () {
    testWidgets('first build (launch/load): request(motion) zero; check may run',
        (tester) async {
      final s = await pumpGate(tester, {
        _camera: _granted,
        _motion: _denied, // a real, non-granted status to read
        _photos: _granted,
      });

      expect(s.requestCount(_motion), 0, reason: 'no prompt on load');
      // The non-prompting check is allowed (and expected) on load.
      expect(s.checkCount(_motion), greaterThanOrEqualTo(1));
    });

    testWidgets('rebuild / rotation preserves State and fires no prompt-trigger',
        (tester) async {
      final flow = _FakeFlowStore();
      final s = await pumpGate(tester, {
        _camera: _granted,
        _motion: _denied,
        _photos: _granted,
      }, flow: flow);

      final checksAfterLoad = s.checkCount(_motion);

      // Re-pump a fresh widget tree at the same position → element reused, State
      // preserved (initState does NOT refire), build runs again (a rebuild).
      await tester.pumpWidget(host(s, flow));
      await tester.pumpAndSettle();
      await tester.pumpWidget(host(s, flow)); // a second rebuild for good measure
      await tester.pumpAndSettle();

      // State preserved → no re-init → no extra checks, and never a prompt.
      expect(s.checkCount(_motion), checksAfterLoad,
          reason: 'rebuild must not re-run initState');
      expect(s.requestCount(_motion), 0);
    });

    testWidgets('app-resume re-check uses check only; no prompt-trigger',
        (tester) async {
      final s = await pumpGate(tester, {
        _camera: _granted,
        _motion: _denied,
        _photos: _granted,
      });
      final checksBefore = s.checkCount(_motion);

      await resume(tester);

      // Resume re-checks live status (check increased)…
      expect(s.checkCount(_motion), greaterThan(checksBefore));
      // …but never issues the prompt-trigger.
      expect(s.requestCount(_motion), 0);
    });

    testWidgets('repeated rebuilds + resumes keep the prompt-trigger at zero',
        (tester) async {
      final flow = _FakeFlowStore();
      final s = await pumpGate(tester, {
        _camera: _granted,
        _motion: _denied,
        _photos: _granted,
      }, flow: flow);

      for (var i = 0; i < 3; i++) {
        await tester.pumpWidget(host(s, flow));
        await tester.pumpAndSettle();
        await resume(tester);
      }

      expect(s.requestCount(_motion), 0);
    });

    testWidgets('motion already granted on load: no prompt-trigger, no crash, no Allow',
        (tester) async {
      final s = await pumpGate(tester, {
        _camera: _granted,
        _motion: _granted, // already decided (also how `unavailable` maps)
        _photos: _granted,
      });

      expect(tester.takeException(), isNull);
      expect(s.requestCount(_motion), 0);
      // Granted motion shows a status chip, never an "Allow" action.
      expect(find.text('Granted'), findsWidgets);
      expect(find.text('Allow'), findsNothing);
    });
  });

  // ── Gate: the prompt-trigger fires ONLY on the user's action ───────────────
  group('gate issues the prompt-trigger only on user action', () {
    testWidgets('tapping Motion "Allow" issues exactly one request(motion)',
        (tester) async {
      // camera+photos granted so the lone "Allow" belongs to Motion.
      final s = await pumpGate(tester, {
        _camera: _granted,
        _motion: _denied,
        _photos: _granted,
      });
      expect(s.requestCount(_motion), 0); // nothing before the tap

      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();

      expect(s.requestCount(_motion), 1, reason: 'one prompt-trigger per tap');
      // No other permission was prompt-triggered.
      expect(s.requestCount(_camera), 0);
      expect(s.requestCount(_photos), 0);
    });

    testWidgets('rapid double-tap on Motion "Allow" still triggers once',
        (tester) async {
      final s = await pumpGate(tester, {
        _camera: _granted,
        _motion: _denied,
        _photos: _granted,
      });

      // Hold the first "prompt" in flight so the two taps genuinely overlap;
      // otherwise an instantly-resolving request clears the in-flight guard
      // between awaited taps and the guard can't be observed.
      s.holdRequest = Completer<void>();

      await tester.tap(find.text('Allow'));
      await tester.tap(find.text('Allow')); // in-flight guard collapses this
      expect(s.requestCount(_motion), 1);

      s.holdRequest!.complete();
      await tester.pumpAndSettle();
      expect(s.requestCount(_motion), 1);
    });
  });

  // ── Sabotage (non-vacuity) — no production code is modified ─────────────────
  group('sabotage proves the assertions are non-vacuous', () {
    // A: a gate that prompt-triggers in initState must make "no prompt on load"
    // FAIL (request count becomes > 0 with no user action).
    testWidgets('A: request(motion) in initState → load-prompt detector catches it',
        (tester) async {
      final s = _SpyService({_motion: _denied});
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark.copyWith(platform: TargetPlatform.iOS),
        home: _BrokenInitStateGate(service: s),
      ));
      await tester.pumpAndSettle();

      // The real-gate assertion is `expect(requestCount(motion), 0)`; here it is
      // 1, so that assertion WOULD fail — the detector is real.
      expect(s.requestCount(_motion), 1);
    });

    // B: a "check" that routes through the prompt-trigger must make
    // "check doesn't prompt" FAIL (request count > 0 on a check-only load).
    testWidgets('B: check(motion) routing to request → check-prompts detector catches it',
        (tester) async {
      final s = _LeakyCheckService({
        _camera: _granted,
        _motion: _denied,
        _photos: _granted,
      });
      await tester.pumpWidget(host(s, _FakeFlowStore()));
      await tester.pumpAndSettle();

      // Load performed only checks (no tap), yet the leaky check pumped the
      // prompt-trigger — exactly what the zero-request assertion would catch.
      expect(s.requestCount(_motion), greaterThan(0));
    });
  });
}

/// Sabotage A stand-in: a gate that wrongly prompt-triggers on load.
class _BrokenInitStateGate extends StatefulWidget {
  const _BrokenInitStateGate({required this.service});
  final _SpyService service;
  @override
  State<_BrokenInitStateGate> createState() => _BrokenInitStateGateState();
}

class _BrokenInitStateGateState extends State<_BrokenInitStateGate> {
  @override
  void initState() {
    super.initState();
    widget.service.request(_motion); // BUG: prompts with no user action
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox());
}

/// Sabotage B stand-in: a facade whose non-prompting check wrongly routes
/// through the prompt-triggering request path.
class _LeakyCheckService extends _SpyService {
  _LeakyCheckService(super.statuses);
  @override
  Future<AppPermissionStatus> status(AppPermissionType type) {
    if (type == _motion) return request(type); // BUG: check issues a query
    return super.status(type);
  }
}
