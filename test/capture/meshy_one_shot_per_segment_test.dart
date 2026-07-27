// test/capture/meshy_one_shot_per_segment_test.dart
//
// MESHY: exactly one capture per ring wedge, and a friction-free upload.
//
// PART 1 — the shutter refuses a wedge that already holds a shot and tells the
// user to turn; turning to an empty wedge re-arms it; the rule is Meshy-only
// (full mode still allows repeat shots in one wedge), fails OPEN on unknown or
// out-of-range segment state, is exempt during a retake, and the 5th distinct
// wedge auto-advances the flow exactly once.
//
// PART 2 — the Capture Summary in Meshy drops the incomplete-capture surfaces
// (Fix Issues, below-min notice, below-min confirm) so Upload starts on the
// first tap, while the offline block still stops it. Full mode is asserted
// UNCHANGED against the same shape.
//
// PART 3 — the summary provider resolves its coverage floor per MODE, so a
// remote retune of the global floor can't make this screen disagree with the
// gate that let the user reach it.
//
// HOW THE HARNESS DRIVES THE RING
//   • The live wedge comes from a broadcast StreamController overriding
//     [currentRingSegmentProvider] — the test turns the phone by emitting.
//   • Tilt + stability are pinned in-band/stable: Meshy's HARD tilt gate does
//     NOT fail open, so inert sensors would block the shutter for the wrong
//     reason and hide the rule under test.
//   • The mode is pinned by overriding [captureModeProvider] only —
//     `captureConfigProvider` is deliberately left as the plain bundled
//     FULL-mode config, so anything that reads the wrong provider (16 wedges
//     instead of 6) fails here instead of passing by luck.
//   • Every shutter tap is followed by a 250ms pump: the post-shot flash is an
//     opaque full-screen Container that would otherwise swallow the next tap.
//   • A visible SnackBar covers the bottom bar, so snack assertions come last.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/application/capture/capture_mode_provider.dart';
import 'package:recapture/application/capture/capture_summary_provider.dart';
import 'package:recapture/application/capture/current_tilt_provider.dart';
import 'package:recapture/application/capture/ledger/captured_photo_record.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry_provider.dart';
import 'package:recapture/application/capture/ring_progress_provider.dart';
import 'package:recapture/application/capture/segment_coverage_provider.dart';
import 'package:recapture/application/capture/stability_provider.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/application/connectivity/connectivity_providers.dart';
import 'package:recapture/data/local/active_session_box.dart';
import 'package:recapture/data/local/auto_capture_box.dart';
import 'package:recapture/data/local/capture_settings_box.dart';
import 'package:recapture/domain/capture/capture_mode.dart';
import 'package:recapture/domain/capture/segment_capture_decision.dart';
import 'package:recapture/domain/entities/active_session.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/capture_settings.dart';
import 'package:recapture/domain/entities/retake_request.dart';
import 'package:recapture/platform/connectivity_watcher.dart';
import 'package:recapture/platform/imu_rotation_channel.dart';
import 'package:recapture/platform/stability_channel.dart';
import 'package:recapture/presentation/screens/capture/capture_screen.dart';
import 'package:recapture/presentation/screens/capture/capture_summary_screen.dart';
import 'package:recapture/utils/analytics.dart';
import 'package:recapture/utils/constants.dart';

// ── stand-ins for the Hive-backed stores (no Hive host in this test) ──────────

class _FakeSessionBox extends ActiveSessionBox {
  @override
  Future<ActiveSession?> read() async => null;
}

class _FakeAutoCaptureStore implements AutoCaptureStore {
  @override
  Future<bool?> getEnabled() async => null;
  @override
  Future<void> setEnabled(bool enabled) async {}
}

class _FakeCaptureSettingsStore implements CaptureSettingsStore {
  @override
  Future<bool?> getSaveToGallery() async => null;
  @override
  Future<void> setSaveToGallery(bool enabled) async {}
  @override
  Future<QualityMode?> getQuality() async => null;
  @override
  Future<void> setQuality(QualityMode mode) async {}
}

/// The plain bundled (FULL-mode) config — deliberately NOT reshaped for Meshy.
/// The Meshy shape must come from the mode resolvers, not from a test fixture.
class _BundledConfig extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault;
}

/// Pins the capture mode for the widget under test.
class _ModeController extends CaptureModeController {
  _ModeController(this._mode);
  final CaptureMode _mode;
  @override
  CaptureMode build() => _mode;
}

CapturedPhotoRecord _accepted(int seg, String path) => CapturedPhotoRecord(
      segmentIndex: seg,
      framePath: path,
      blurScore: 100,
      meanLuminance: 128,
      yawDegrees: 0,
      pitchDegrees: 0,
      sensorTimestampNs: seg * 1000 + 1,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const previewChannel = MethodChannel(AppConfig.channelCameraPreview);
  const captureChannel = MethodChannel(AppConfig.channelCapture);
  const permissionsChannel = MethodChannel(AppConfig.channelPermissions);

  late List<String> captureCalls;
  late StreamController<RingSegmentSample> ring;

  setUp(() {
    captureCalls = [];
    ring = StreamController<RingSegmentSample>.broadcast();

    messenger.setMockMethodCallHandler(previewChannel, (call) async {
      if (call.method == 'start') return <String, dynamic>{'status': 'running'};
      return null;
    });
    // A real frame per call, with a unique id/path so the ledger records are
    // distinct (the ring position is what the gate keys on, not the frame).
    messenger.setMockMethodCallHandler(captureChannel, (call) async {
      captureCalls.add(call.method);
      final n = captureCalls.length;
      return <String, dynamic>{
        'id': 'cap_$n',
        'path': '/tmp/cap_$n.jpg',
        'timestampNs': n,
      };
    });
    messenger.setMockMethodCallHandler(
        permissionsChannel, (call) async => 'granted');
  });

  tearDown(() {
    ring.close();
    messenger.setMockMethodCallHandler(previewChannel, null);
    messenger.setMockMethodCallHandler(captureChannel, null);
    messenger.setMockMethodCallHandler(permissionsChannel, null);
  });

  // ── Part 1: the capture screen ─────────────────────────────────────────────

  List<Override> captureOverrides(CaptureMode mode) => [
        // Plain full-mode config — the Meshy shape must be resolved from the mode.
        captureConfigProvider.overrideWith(_BundledConfig.new),
        captureModeProvider.overrideWith(() => _ModeController(mode)),
        // The live wedge, driven by the test.
        currentRingSegmentProvider.overrideWith((ref) => ring.stream),
        // In-band + stable: Meshy's hard tilt gate does not fail open, so these
        // must be satisfied for the already-captured rule to be the only gate.
        // 90° is inside both bands (full [40,110), Meshy [60,180)).
        currentTiltProvider.overrideWith(
          (ref) => Stream.value(
            const TiltSample(tiltDegrees: 90, sensorSupported: true),
          ),
        ),
        stabilityProvider.overrideWith(
          (ref) => Stream.value(
            const StabilitySample(
                stability: Stability.stable, sensorSupported: true),
          ),
        ),
        // Never touched (both consumers above are overridden) — pinned anyway so
        // a future consumer can't reach a real platform channel from a test.
        orientationSourceProvider
            .overrideWithValue(const Stream<SmoothedOrientation>.empty()),
        stabilityEventSourceProvider
            .overrideWithValue(const Stream<StabilityEvent>.empty()),
      ];

  CaptureScreen captureScreen({
    RetakeRequest? retake,
    String nextRoute = '/next',
  }) =>
      CaptureScreen(
        levelLabel: 'Level A',
        levelName: 'Eye Ring',
        nextRoute: nextRoute,
        retakeRequest: retake,
        sessionBox: _FakeSessionBox(),
        autoCaptureStore: _FakeAutoCaptureStore(),
        captureSettingsStore: _FakeCaptureSettingsStore(),
      );

  Future<void> pumpCapture(
    WidgetTester tester, {
    CaptureMode mode = CaptureMode.meshy,
    RetakeRequest? retake,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: captureOverrides(mode),
        child: MaterialApp(home: captureScreen(retake: retake)),
      ),
    );
    await tester.pump(); // post-frame: ring activation + camera start
  }

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(CaptureScreen)));

  /// Turns the phone to [segment] (null = the segment is unknown — sensors
  /// pending) and lets the stream + the rebuild land.
  Future<void> turnTo(WidgetTester tester, int? segment) async {
    ring.add(RingSegmentSample(currentSegment: segment, sensorSupported: true));
    await tester.pump(); // deliver the stream event
    await tester.pump(); // rebuild the gated shutter
  }

  /// Taps the shutter and drains the post-shot flash — an opaque full-screen
  /// Container for 200ms that SWALLOWS the next tap if it is still up.
  Future<void> tapShutter(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('capture_shutter')));
    await tester.pump(); // resolve captureSingle
    await tester.pump(); // apply setState
    await tester.pump(const Duration(milliseconds: 250)); // flash gone
  }

  /// Unmounts the screen so no timer outlives the test.
  Future<void> teardownScreen(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
  }

  Finder snack() => find.byKey(const Key('already_captured_snack'));

  group('Meshy — one capture per wedge', () {
    testWidgets('a second tap in the SAME wedge does not capture, and says why',
        (tester) async {
      await pumpCapture(tester);
      await turnTo(tester, 0);

      await tapShutter(tester);
      expect(captureCalls, hasLength(1));
      expect(containerOf(tester).read(segmentCoverageProvider).filled[0], isTrue);
      // The ring is the Meshy 6, resolved from the mode (not the 16 the plain
      // bundled config in this harness would give).
      expect(
          containerOf(tester).read(segmentCoverageProvider).segmentCount, 6);
      expect(snack(), findsNothing);

      // Same wedge, second tap: refused — the native capture is never called.
      await tapShutter(tester);
      expect(captureCalls, hasLength(1),
          reason: 'a filled wedge must not take a second shot');
      expect(containerOf(tester).read(segmentCoverageProvider).filledCount, 1);

      // …and the user is told what to do about it, in the decision's own copy.
      expect(snack(), findsOneWidget);
      expect(find.text(RejectAlreadyFilled.warningMessage), findsOneWidget);

      await teardownScreen(tester);
    });

    testWidgets('turning to an EMPTY wedge re-arms the shutter', (tester) async {
      await pumpCapture(tester);

      await turnTo(tester, 0);
      await tapShutter(tester);
      expect(captureCalls, hasLength(1));

      await turnTo(tester, 1);
      await tapShutter(tester);
      expect(captureCalls, hasLength(2));

      final coverage = containerOf(tester).read(segmentCoverageProvider);
      expect(coverage.filled[0], isTrue);
      expect(coverage.filled[1], isTrue);
      expect(coverage.filledCount, 2);
      expect(snack(), findsNothing, reason: 'nothing was refused');

      await teardownScreen(tester);
    });

    testWidgets('unknown or out-of-range segment FAILS OPEN (still captures)',
        (tester) async {
      await pumpCapture(tester);
      await turnTo(tester, 0);
      await tapShutter(tester);
      expect(captureCalls, hasLength(1));

      // Sensors pending → no attributable wedge. The shot is allowed (it just
      // cannot claim coverage); locking the shutter on unreadable state would
      // strand the user.
      await turnTo(tester, null);
      await tapShutter(tester);
      expect(captureCalls, hasLength(2));

      // A stale index outside the ring is equally unreadable → also allowed.
      await turnTo(tester, 99);
      await tapShutter(tester);
      expect(captureCalls, hasLength(3));

      // Neither shot invented coverage: only wedge 0 is filled.
      expect(containerOf(tester).read(segmentCoverageProvider).filledCount, 1);
      expect(snack(), findsNothing);

      await teardownScreen(tester);
    });

    testWidgets('a RETAKE may re-shoot a filled wedge', (tester) async {
      // returnToReviewAfter: false → resume mode, so the accepted retake stays
      // on this screen (no router needed).
      await pumpCapture(
        tester,
        retake: const RetakeRequest(
          ringIndex: 0,
          replacingCaptureId: 'cap_old',
          returnToReviewAfter: false,
        ),
      );
      // Wedge 0 already holds a shot — exactly the state a retake targets.
      containerOf(tester).read(segmentCoverageProvider.notifier).recordCapture(0);
      await tester.pump();
      await turnTo(tester, 0);

      await tapShutter(tester);

      expect(captureCalls, hasLength(1),
          reason: 'the retake is exempt from the one-shot rule');
      expect(snack(), findsNothing);

      await teardownScreen(tester);
    });
  });

  group('full mode is untouched', () {
    testWidgets('two consecutive taps in the same wedge BOTH capture',
        (tester) async {
      await pumpCapture(tester, mode: CaptureMode.full);
      await turnTo(tester, 0);

      await tapShutter(tester);
      await tapShutter(tester);

      expect(captureCalls, hasLength(2),
          reason: 'full mode expects repeat shots in a wedge');
      expect(snack(), findsNothing);
      // Full mode keeps its 16-wedge eye ring.
      expect(
          containerOf(tester).read(segmentCoverageProvider).segmentCount, 16);

      await teardownScreen(tester);
    });
  });

  group('completion → upload handoff', () {
    testWidgets('the 5th distinct wedge advances the flow exactly once',
        (tester) async {
      var completeBuilds = 0;
      final router = GoRouter(
        initialLocation: '/capture',
        routes: [
          GoRoute(path: '/capture', builder: (_, __) => captureScreen(
                nextRoute: '/complete',
              )),
          GoRoute(
            path: '/complete',
            builder: (_, __) {
              completeBuilds++;
              return const Scaffold(body: Text('LEVEL COMPLETE'));
            },
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: captureOverrides(CaptureMode.meshy),
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();

      // Four distinct wedges: 4/6 = 67% — short of Meshy's 80% floor.
      for (var i = 0; i < 4; i++) {
        await turnTo(tester, i);
        await tapShutter(tester);
      }
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(CaptureScreen), findsOneWidget);
      expect(completeBuilds, 0, reason: '4 of 6 does not finish the ring');

      // The fifth clears it (5/6 = 83% ≥ 80) → one navigation, 300ms later.
      await turnTo(tester, 4);
      await tapShutter(tester);
      // The 300ms hand-off, then the route transition — pumped in frames (a
      // single long pump jumps the clock but draws only one frame, which is not
      // enough for the transition animation to run out).
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.text('LEVEL COMPLETE'), findsOneWidget);
      expect(find.byType(CaptureScreen), findsNothing);
      expect(completeBuilds, 1, reason: 'navigated exactly once');
      expect(captureCalls, hasLength(5));
    });
  });

  // ── Part 2: the Capture Summary ────────────────────────────────────────────

  group('Meshy summary — friction-free upload', () {
    late List<({String name, Map<String, Object?> props})> events;
    late StreamController<AppConnectivityStatus> conn;

    setUp(() {
      events = [];
      Analytics.testSink =
          (name, props) => events.add((name: name, props: props));
      conn = StreamController<AppConnectivityStatus>.broadcast();
    });
    tearDown(() {
      Analytics.testSink = null;
      conn.close();
    });

    /// Coverage-COMPLETE but below a raised completion COUNT floor — the one
    /// shape that is upload-eligible AND "incomplete", i.e. exactly where full
    /// mode shows Fix Issues + the below-min notice + the confirm dialog.
    /// (A coverage shortfall trips the HARD gate instead, in both modes.)
    ConfigNotifier highCountFloor() => _HighCountFloorConfig();

    LevelCaptureLedgerRegistry registryWith(Map<String, int> perBand) {
      final reg = LevelCaptureLedgerRegistry();
      perBand.forEach((band, n) {
        for (var i = 0; i < n; i++) {
          reg.ledgerFor(band).recordAccepted(_accepted(i, '/$band/$i.jpg'));
        }
      });
      return reg;
    }

    Future<void> pumpSummary(
      WidgetTester tester, {
      required CaptureMode mode,
      required LevelCaptureLedgerRegistry registry,
    }) async {
      Widget stub(String l) => Scaffold(body: Text(l));
      final router = GoRouter(
        initialLocation: AppRoutes.captureSummary,
        routes: [
          GoRoute(
              path: AppRoutes.captureSummary,
              builder: (_, __) => const CaptureSummaryScreen()),
          GoRoute(
              path: AppRoutes.uploading, builder: (_, __) => stub('UPLOADING')),
          GoRoute(
              path: AppRoutes.projects, builder: (_, __) => stub('PROJECTS')),
          GoRoute(
              path: AppRoutes.levelACapture,
              builder: (_, __) => stub('CAPTURE A')),
          GoRoute(
              path: AppRoutes.levelAReview,
              builder: (_, __) => stub('REVIEW A')),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            levelCaptureLedgerRegistryProvider.overrideWithValue(registry),
            captureConfigProvider.overrideWith(highCountFloor),
            captureModeProvider.overrideWith(() => _ModeController(mode)),
            connectivityStatusProvider.overrideWith((ref) => conn.stream),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
    }

    testWidgets('no Fix Issues, no below-min notice, Upload goes straight up',
        (tester) async {
      // 5 of 6 wedges → coverage complete, count below the raised floor.
      await pumpSummary(
        tester,
        mode: CaptureMode.meshy,
        registry: registryWith({'mid': 5}),
      );

      expect(find.byKey(const Key('summary_fix_issues')), findsNothing);
      expect(find.byKey(const Key('below_min_notice')), findsNothing);
      // The hard gate is satisfied, so its notice is absent too (it is NOT
      // suppressed by mode — it simply has nothing to report here).
      expect(find.byKey(const Key('upload_gate_notice')), findsNothing);

      await tester.tap(find.byKey(const Key('summary_upload')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('below_min_dialog')), findsNothing);
      expect(find.text('UPLOADING'), findsOneWidget);
      expect(
        events.where((e) => e.name == AnalyticsEvents.uploadInitiated),
        hasLength(1),
      );
    });

    testWidgets('FULL mode, same shape → Fix Issues + notice + confirm',
        (tester) async {
      // The regression guard: 13 of 16 per ring is coverage-complete under the
      // bundled full shape, and the same raised count floor makes Level A
      // "incomplete" — full mode still offers every remedy.
      await pumpSummary(
        tester,
        mode: CaptureMode.full,
        registry: registryWith({'mid': 13, 'high': 13, 'low': 13}),
      );

      expect(find.byKey(const Key('summary_fix_issues')), findsOneWidget);
      expect(find.byKey(const Key('below_min_notice')), findsOneWidget);

      await tester.tap(find.byKey(const Key('summary_upload')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('below_min_dialog')), findsOneWidget);
    });

    testWidgets('offline still blocks the Meshy upload', (tester) async {
      await pumpSummary(
        tester,
        mode: CaptureMode.meshy,
        registry: registryWith({'mid': 5}),
      );

      conn.add(AppConnectivityStatus.offline);
      await tester.pump(); // deliver
      await tester.pump(); // listener → schedule debounce
      await tester.pump(const Duration(milliseconds: 450)); // fire debounce
      await tester.pump();

      expect(find.byKey(const Key('summary_offline_banner')), findsOneWidget);

      await tester.tap(find.byKey(const Key('summary_upload')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('summary_offline_snack')), findsOneWidget);
      expect(find.text('UPLOADING'), findsNothing);
      expect(
        events.where((e) => e.name == AnalyticsEvents.uploadInitiated),
        isEmpty,
      );
    });
  });

  // ── Part 3: the summary's coverage floor is per-MODE ───────────────────────

  group('summary provider — per-mode coverage floor', () {
    test('a raised GLOBAL floor does not make a 5-of-6 Meshy ring incomplete',
        () {
      final registry = LevelCaptureLedgerRegistry();
      for (var i = 0; i < 5; i++) {
        registry.ledgerFor('mid').recordAccepted(_accepted(i, '/mid/$i.jpg'));
      }
      final container = ProviderContainer(overrides: [
        levelCaptureLedgerRegistryProvider.overrideWithValue(registry),
        // A remote retune of the global floor to 100% — full mode's knob.
        captureConfigProvider.overrideWith(_GlobalFloor100Config.new),
        captureModeProvider
            .overrideWith(() => _ModeController(CaptureMode.meshy)),
      ]);
      addTearDown(container.dispose);

      final summaries = container.read(captureSummaryProvider);
      expect(summaries, hasLength(1)); // Meshy runs Level A alone
      final a = summaries.single;
      expect(a.completion.segmentCount, 6);
      expect(a.completion.filledCount, 5);
      // Meshy's own 80% floor applies — NOT the retuned global. Reading the raw
      // global here would report "Incomplete" for a capture the upload gate
      // (which resolves per mode) considers done.
      expect(a.completion.minCoveragePct, 80);
      expect(a.isComplete, isTrue);
    });

    test('full mode still follows the global floor', () {
      final registry = LevelCaptureLedgerRegistry();
      // 13 of 16 = 81% — complete at the default 80, short of a retuned 100.
      for (var i = 0; i < 13; i++) {
        registry.ledgerFor('mid').recordAccepted(_accepted(i, '/mid/$i.jpg'));
      }
      final container = ProviderContainer(overrides: [
        levelCaptureLedgerRegistryProvider.overrideWithValue(registry),
        captureConfigProvider.overrideWith(_GlobalFloor100Config.new),
        captureModeProvider
            .overrideWith(() => _ModeController(CaptureMode.full)),
      ]);
      addTearDown(container.dispose);

      final a = container.read(captureSummaryProvider).first;
      expect(a.completion.minCoveragePct, 100);
      expect(a.isComplete, isFalse);
    });
  });
}

/// Bundled shape + a raised completion COUNT floor for Level A (20 accepted
/// frames), so a coverage-complete level still reads "incomplete" — the only
/// state that is upload-ELIGIBLE and incomplete at once.
class _HighCountFloorConfig extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault.copyWith(
        completionThresholds: CompletionThresholds.fromMap(const {
          'A': {'minAcceptedFrames': 20},
        }),
      );
}

/// The global (full-mode) coverage floor retuned to 100% — the remote change
/// Part 3 guards against leaking into Meshy.
class _GlobalFloor100Config extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault.copyWith(
        thresholds: const CaptureThresholds(
          minSharpness: 0.45,
          minCoveragePct: 100,
          maxTiltDeltaDeg: 12,
        ),
      );
}
