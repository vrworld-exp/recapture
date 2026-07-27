// test/capture/meshy_one_shot_per_segment_test.dart
//
// MESHY one-capture-per-ring-sixth, end to end on the REAL CaptureScreen: once a
// wedge holds an accepted shot the shutter refuses further shots at that yaw, so
// the user must physically turn; after all 6 the level completes and the flow
// moves on.
//
// What is pinned here:
//   - the blocked path (shutter readiness) AND the hard guard in _performCapture
//     (the one-frame-stale case) both refuse — no native capture, no counter
//     advance, no coverage change — and both surface the "turn" warning;
//   - a RETAKE deliberately re-shoots a filled wedge (never blocked);
//   - FAIL-OPEN: an unknown segment (no sensor sample) never blocks;
//   - completion runs off the EFFECTIVE (shape-mode) config: 6/6 completes, 5/6
//     does not — the raw remote config's 80% floor must not leak in and strand
//     the user on a Summary whose Upload gate demands 6.
//
// Sensors are inert (tilt/stability unsupported, so the readiness fails open),
// which leaves the already-captured rule as the ONLY thing gating the shutter
// here. The live segment is driven directly through currentRingSegmentProvider.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/application/capture/capture_shape_mode_provider.dart';
import 'package:recapture/application/capture/current_tilt_provider.dart';
import 'package:recapture/application/capture/ring_progress_provider.dart';
import 'package:recapture/application/capture/segment_coverage_provider.dart';
import 'package:recapture/application/capture/stability_provider.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/data/local/active_session_box.dart';
import 'package:recapture/data/local/auto_capture_box.dart';
import 'package:recapture/data/local/capture_settings_box.dart';
import 'package:recapture/domain/capture/capture_shape_mode.dart';
import 'package:recapture/domain/capture/segment_capture_decision.dart';
import 'package:recapture/domain/entities/active_session.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/capture_settings.dart';
import 'package:recapture/domain/entities/retake_request.dart';
import 'package:recapture/platform/imu_rotation_channel.dart';
import 'package:recapture/platform/stability_channel.dart';
import 'package:recapture/presentation/screens/capture/capture_screen.dart';
import 'package:recapture/utils/constants.dart';

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

/// The FULL flow's remote config (80% coverage floor, 16-segment eye ring). It is
/// deliberately the "wrong" config for Meshy: every Meshy behaviour below must
/// come from the shape-mode-aware effective config instead, so a regression that
/// reads this one shows up as a 5/6 completion or a 16-wedge ring.
class _StubConfigNotifier extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault;
}

class _MeshyShapeModeController extends CaptureShapeModeController {
  @override
  CaptureShapeMode build() => CaptureShapeMode.meshy;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const previewChannel = MethodChannel(AppConfig.channelCameraPreview);
  const captureChannel = MethodChannel(AppConfig.channelCapture);

  late List<String> captureCalls;
  late int frameSeq;

  /// Drives the live yaw-to-segment sample the gate reads. Broadcast so the
  /// provider can re-listen; values are emitted only after the first pump has
  /// attached it.
  late StreamController<RingSegmentSample> segments;

  setUp(() {
    captureCalls = [];
    frameSeq = 0;
    segments = StreamController<RingSegmentSample>.broadcast();

    messenger.setMockMethodCallHandler(previewChannel, (call) async {
      if (call.method == 'start') return <String, dynamic>{'status': 'running'};
      return null;
    });
    messenger.setMockMethodCallHandler(captureChannel, (call) async {
      captureCalls.add(call.method);
      frameSeq++;
      return <String, dynamic>{
        'id': 'cap_$frameSeq',
        'path': '/tmp/cap_$frameSeq.jpg',
        'timestampNs': frameSeq,
      };
    });
  });

  tearDown(() {
    segments.close();
    messenger.setMockMethodCallHandler(previewChannel, null);
    messenger.setMockMethodCallHandler(captureChannel, null);
  });

  int captures() => captureCalls.where((m) => m == 'captureSingle').length;

  /// Pumps the real capture screen in Meshy mode behind a router (so completion
  /// can navigate). [liveSegments] false leaves the segment UNKNOWN forever — the
  /// fail-open case.
  Future<void> pumpMeshyCapture(
    WidgetTester tester, {
    RetakeRequest? retake,
    bool liveSegments = true,
  }) async {
    final router = GoRouter(
      initialLocation: '/capture',
      routes: [
        GoRoute(
          path: '/capture',
          builder: (_, __) => CaptureScreen(
            levelLabel: 'A',
            levelName: 'Eye Ring',
            nextRoute: '/next',
            retakeRequest: retake,
            sessionBox: _FakeSessionBox(),
            autoCaptureStore: _FakeAutoCaptureStore(),
            captureSettingsStore: _FakeCaptureSettingsStore(),
          ),
        ),
        GoRoute(
          path: '/next',
          builder: (_, __) => const Scaffold(
            body: Center(child: Text('NEXT', key: Key('next_marker'))),
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          captureConfigProvider.overrideWith(() => _StubConfigNotifier()),
          captureShapeModeProvider
              .overrideWith(() => _MeshyShapeModeController()),
          orientationSourceProvider
              .overrideWithValue(const Stream<SmoothedOrientation>.empty()),
          stabilityEventSourceProvider
              .overrideWithValue(const Stream<StabilityEvent>.empty()),
          if (liveSegments)
            currentRingSegmentProvider.overrideWith((ref) => segments.stream),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump(); // post-frame: activate the ring, start the preview
  }

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(CaptureScreen)));

  /// Points the camera at ring segment [i] and lets the HUD settle.
  Future<void> aimAt(WidgetTester tester, int i) async {
    segments.add(RingSegmentSample(currentSegment: i, sensorSupported: true));
    await tester.pump();
  }

  /// One shutter tap, resolving the (mocked) native capture + the setState, then
  /// draining the 200ms post-shot flash. The flash is an OPAQUE full-screen
  /// overlay, so without that wait the next tap would land on it instead of the
  /// shutter and this suite would pass for the wrong reason.
  Future<void> tapShutter(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('capture_shutter')));
    await tester.pump(); // resolve captureSingle
    await tester.pump(); // apply setState
    await tester.pump(const Duration(milliseconds: 250)); // clear the flash
  }

  /// Unmounts the screen and drains the flash / snack timers.
  Future<void> teardownScreen(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets("the ring is 6 wedges in Meshy, not the remote config's 16",
      (tester) async {
    await pumpMeshyCapture(tester);
    expect(containerOf(tester).read(segmentCoverageProvider).segmentCount, 6);
    expect(find.text('0/6'), findsNWidgets(2)); // photo counter + ring badge
    await teardownScreen(tester);
  });

  testWidgets('one shot per wedge: turning captures, re-aiming at a filled '
      'wedge is refused', (tester) async {
    await pumpMeshyCapture(tester);

    // Wedge 2 — captures and fills.
    await aimAt(tester, 2);
    await tapShutter(tester);
    expect(captures(), 1);
    expect(containerOf(tester).read(segmentCoverageProvider).filled[2], isTrue);
    expect(find.text('1/6'), findsNWidgets(2)); // photo counter + ring badge

    // Turn to an unfilled wedge — the shutter works again.
    await aimAt(tester, 3);
    await tapShutter(tester);
    expect(captures(), 2);
    expect(containerOf(tester).read(segmentCoverageProvider).filled[3], isTrue);
    expect(find.text('2/6'), findsNWidgets(2));

    // Back to wedge 2 — blocked. No native call, no counter advance, no extra
    // fill; the "turn to the next section" warning is surfaced.
    await aimAt(tester, 2);
    await tapShutter(tester);
    expect(captures(), 2, reason: 'no second native capture at a filled wedge');
    expect(find.text('3/6'), findsNothing);
    expect(find.text('2/6'), findsNWidgets(2));
    expect(containerOf(tester).read(segmentCoverageProvider).fillCounts[2], 1);
    expect(find.byKey(const Key('already_captured_snack')), findsOneWidget);
    expect(find.text(RejectAlreadyFilled.warningMessage), findsOneWidget);

    await teardownScreen(tester);
  });

  testWidgets('the hard guard catches a ONE-FRAME-STALE readiness',
      (tester) async {
    await pumpMeshyCapture(tester);
    await aimAt(tester, 1);

    // Fill wedge 1 WITHOUT pumping: the shutter widget still holds the previous
    // (unblocked) readiness, exactly the stale-frame race the guard exists for.
    containerOf(tester).read(segmentCoverageProvider.notifier).recordCapture(1);
    await tester.tap(find.byKey(const ValueKey('capture_shutter')));
    await tester.pump();
    await tester.pump();

    expect(captures(), 0, reason: 'the guard refuses before the native call');
    expect(find.text('0/6'), findsOneWidget); // photo counter never advanced
    expect(containerOf(tester).read(segmentCoverageProvider).fillCounts[1], 1);
    expect(find.byKey(const Key('already_captured_snack')), findsOneWidget);

    await teardownScreen(tester);
  });

  testWidgets('a RETAKE re-shoots a filled wedge (never blocked)',
      (tester) async {
    // Retake mode keeps the in-progress ring, so a pre-filled wedge survives.
    await pumpMeshyCapture(
      tester,
      retake: const RetakeRequest(ringIndex: 2, replacingCaptureId: 'cap_old'),
    );
    containerOf(tester).read(segmentCoverageProvider.notifier).recordCapture(2);
    await aimAt(tester, 2);

    await tapShutter(tester);

    expect(captures(), 1,
        reason: 'a retake deliberately re-shoots a filled wedge');
    expect(find.byKey(const Key('already_captured_snack')), findsNothing);

    await teardownScreen(tester);
  });

  testWidgets('FAIL-OPEN: an unknown segment never blocks the shutter',
      (tester) async {
    // No sensor sample at all (no usable gyro) — the segment stays unknown, so
    // neither the readiness nor the guard may refuse.
    await pumpMeshyCapture(tester, liveSegments: false);

    await tapShutter(tester);
    await tapShutter(tester);

    expect(captures(), 2);
    expect(find.byKey(const Key('already_captured_snack')), findsNothing);
    // Coverage stays truthful: an unknown segment can't claim a wedge.
    expect(containerOf(tester).read(segmentCoverageProvider).filledCount, 0);

    await teardownScreen(tester);
  });

  testWidgets('completes at 6/6 — and NOT at 5/6 (effective 100% floor)',
      (tester) async {
    await pumpMeshyCapture(tester);

    // Five of six wedges. Under the full flow's 80% floor this would already be
    // "complete" (ceil(0.8 * 6) = 5) — the bug that stranded users at the Summary.
    for (var i = 0; i < 5; i++) {
      await aimAt(tester, i);
      await tapShutter(tester);
    }
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(CaptureScreen), findsOneWidget);
    expect(find.byKey(const Key('next_marker')), findsNothing,
        reason: '5/6 must not complete a Meshy session');

    // The sixth wedge completes it.
    await aimAt(tester, 5);
    await tapShutter(tester);
    await tester.pump(const Duration(milliseconds: 400)); // completion delay
    await tester.pump(const Duration(milliseconds: 350)); // route transition

    expect(find.byKey(const Key('next_marker')), findsOneWidget);
  });
}
