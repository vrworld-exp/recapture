// test/capture/capture_screen_retake_test.dart
//
// Verifies CaptureScreen's RETAKE mode (Review → Capture glue): a valid
// RetakeRequest primes the forced ring target (highlighted via
// retakeSessionProvider) and emits `retake_started`; an out-of-range index falls
// back to normal targeting with no crash and no event; an accepted retake emits
// `retake_completed`, clears the forced target, and returns to Review; backing out
// without capturing leaves state unchanged and returns to Review.
//
// The preview/capture/permission channels are mocked so the screen boots in a
// test host; Analytics.testSink captures emitted events.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/application/capture/current_tilt_provider.dart';
import 'package:recapture/application/capture/retake_session_provider.dart';
import 'package:recapture/application/capture/stability_provider.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/data/local/active_session_box.dart';
import 'package:recapture/data/local/auto_capture_box.dart';
import 'package:recapture/data/local/capture_settings_box.dart';
import 'package:recapture/domain/entities/active_session.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/capture_settings.dart';
import 'package:recapture/domain/entities/retake_request.dart';
import 'package:recapture/platform/imu_rotation_channel.dart';
import 'package:recapture/platform/stability_channel.dart';
import 'package:recapture/presentation/screens/capture/capture_screen.dart';
import 'package:recapture/utils/analytics.dart';
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

class _StubConfigNotifier extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const previewChannel = MethodChannel(AppConfig.channelCameraPreview);
  const captureChannel = MethodChannel(AppConfig.channelCapture);
  const permissionsChannel = MethodChannel(AppConfig.channelPermissions);

  // Eye-ring segment count N from the bundled config (the test config source).
  final segments = CaptureConfig.bundledDefault.eyeRingSegments;

  late Map<String, dynamic>? captureResult;
  late List<(String, Map<String, Object?>)> events;

  setUp(() {
    captureResult = null;
    events = [];
    Analytics.testSink = (name, props) => events.add((name, props));

    messenger.setMockMethodCallHandler(previewChannel, (call) async {
      if (call.method == 'start') return <String, dynamic>{'status': 'running'};
      return null;
    });
    messenger.setMockMethodCallHandler(
        captureChannel, (call) async => captureResult);
    messenger.setMockMethodCallHandler(
        permissionsChannel, (call) async => 'granted');
  });

  tearDown(() {
    Analytics.testSink = null;
    messenger.setMockMethodCallHandler(previewChannel, null);
    messenger.setMockMethodCallHandler(captureChannel, null);
    messenger.setMockMethodCallHandler(permissionsChannel, null);
  });

  List<(String, Map<String, Object?>)> eventsNamed(String name) =>
      events.where((e) => e.$1 == name).toList();

  Widget scope(Widget child) => ProviderScope(
        overrides: [
          captureConfigProvider.overrideWith(() => _StubConfigNotifier()),
          orientationSourceProvider
              .overrideWithValue(const Stream<SmoothedOrientation>.empty()),
          stabilityEventSourceProvider
              .overrideWithValue(const Stream<StabilityEvent>.empty()),
        ],
        child: child,
      );

  CaptureScreen captureScreen(RetakeRequest? request) => CaptureScreen(
        levelLabel: 'A',
        levelName: 'Eye Ring',
        nextRoute: '/review',
        retakeRequest: request,
        sessionBox: _FakeSessionBox(),
        autoCaptureStore: _FakeAutoCaptureStore(),
        captureSettingsStore: _FakeCaptureSettingsStore(),
      );

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(CaptureScreen)));

  // ── Priming (no navigation) ────────────────────────────────────────────────

  testWidgets('a valid retake primes the forced target + emits retake_started',
      (tester) async {
    await tester.pumpWidget(
        scope(MaterialApp(home: captureScreen(
      const RetakeRequest(ringIndex: 2, replacingCaptureId: 'cap_2'),
    ))));
    await tester.pump(); // post-frame prime

    final started = eventsNamed(AnalyticsEvents.captureLevelRetake);
    expect(started, hasLength(1));
    expect(started.single.$2['ring_index'], 2);
    expect(started.single.$2['replacing_existing'], isTrue);
    expect(started.single.$2['return_mode'], 'review');

    // The forced target flowed into the override provider (drives the highlight).
    final session = containerOf(tester).read(retakeSessionProvider);
    expect(session?.ringIndex, 2);

    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an out-of-range retake index falls back to normal targeting',
      (tester) async {
    await tester.pumpWidget(
        scope(MaterialApp(home: captureScreen(
      RetakeRequest(ringIndex: segments + 100),
    ))));
    await tester.pump();

    expect(eventsNamed(AnalyticsEvents.captureLevelRetake), isEmpty,
        reason: 'invalid index must not enter retake mode');
    expect(containerOf(tester).read(retakeSessionProvider), isNull);

    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a missing-segment fill reports replacing_existing=false',
      (tester) async {
    await tester.pumpWidget(
        scope(MaterialApp(home: captureScreen(
      const RetakeRequest(ringIndex: 0), // no replacingCaptureId → fill
    ))));
    await tester.pump();

    final started = eventsNamed(AnalyticsEvents.captureLevelRetake).single;
    expect(started.$2['replacing_existing'], isFalse);

    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a normal entry (no request) does not enter retake mode',
      (tester) async {
    await tester.pumpWidget(scope(MaterialApp(home: captureScreen(null))));
    await tester.pump();

    expect(eventsNamed(AnalyticsEvents.captureLevelRetake), isEmpty);
    expect(containerOf(tester).read(retakeSessionProvider), isNull);

    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox());
  });

  // ── Completion + back-out (routed, so the screen can return to Review) ──────

  GoRouter buildRouter(RetakeRequest request) => GoRouter(
        initialLocation: '/review',
        routes: [
          GoRoute(
            path: '/review',
            builder: (_, __) => const Scaffold(
              body: Center(child: Text('REVIEW', key: Key('review_marker'))),
            ),
          ),
          GoRoute(
            path: '/capture',
            builder: (_, __) => captureScreen(request),
          ),
        ],
      );

  // Pushes onto the capture screen in retake mode (so context.pop returns to
  // Review) and lets the post-frame prime + preview start run.
  Future<void> pushCapture(WidgetTester tester, GoRouter router) async {
    await tester.pumpWidget(scope(MaterialApp.router(routerConfig: router)));
    await tester.pump();
    router.push('/capture');
    await tester.pump(); // build capture
    await tester.pump(); // post-frame prime + start
    await tester.pump(const Duration(milliseconds: 350)); // route transition
  }

  testWidgets('an accepted retake completes + returns to Review', (tester) async {
    captureResult = {'id': 'cap_new', 'path': '/tmp/cap_new.jpg', 'timestampNs': 1};
    final router = buildRouter(
        const RetakeRequest(ringIndex: 3, replacingCaptureId: 'cap_old'));
    await pushCapture(tester, router);

    final container =
        ProviderScope.containerOf(tester.element(find.byType(CaptureScreen)));
    expect(container.read(retakeSessionProvider)?.ringIndex, 3);

    await tester.tap(find.byKey(const ValueKey('capture_shutter')));
    await tester.pump(); // resolve captureSingle
    await tester.pump(); // handle completion (navigation)
    await tester.pump(const Duration(milliseconds: 350)); // pop transition

    expect(find.byKey(const Key('review_marker')), findsOneWidget,
        reason: 'single retake returns to Review');
    final completed = eventsNamed(AnalyticsEvents.retakeCompleted);
    expect(completed, hasLength(1));
    expect(completed.single.$2['ring_index'], 3);
    expect(completed.single.$2['new_verdict'], 'accepted');
    expect(container.read(retakeSessionProvider), isNull,
        reason: 'forced target cleared after completion');
  });

  testWidgets('backing out of retake leaves state unchanged + returns to Review',
      (tester) async {
    captureResult = null; // no capture taken
    final router = buildRouter(
        const RetakeRequest(ringIndex: 1, replacingCaptureId: 'cap_1'));
    await pushCapture(tester, router);

    final container =
        ProviderScope.containerOf(tester.element(find.byType(CaptureScreen)));
    expect(container.read(retakeSessionProvider)?.ringIndex, 1);

    // Top-bar back (X) funnels through the retake back-out path.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.byKey(const Key('review_marker')), findsOneWidget);
    expect(eventsNamed(AnalyticsEvents.retakeCompleted), isEmpty,
        reason: 'no capture → no completion');
    expect(container.read(retakeSessionProvider), isNull,
        reason: 'back-out clears the forced target');
  });
}
