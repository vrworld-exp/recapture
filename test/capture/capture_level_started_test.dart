// test/capture/capture_level_started_test.dart
//
// Instrument-tests the `capture_level_started` fire point in the capture screen:
// it fires exactly once per session with the full canonical schema, does NOT
// refire on a rebuild, and is SUPPRESSED on a retake entry (which emits
// capture_level_retake instead, so the funnel never double-counts a retake as a
// fresh start).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/current_tilt_provider.dart';
import 'package:recapture/application/capture/stability_provider.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/data/local/active_session_box.dart';
import 'package:recapture/data/local/auto_capture_box.dart';
import 'package:recapture/data/local/capture_settings_box.dart';
import 'package:recapture/domain/entities/active_session.dart';
import 'package:recapture/domain/capture/capture_flow_variant.dart';
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

  late List<(String, Map<String, Object?>)> events;

  setUp(() {
    events = [];
    Analytics.testSink = (name, props) => events.add((name, props));
    messenger.setMockMethodCallHandler(previewChannel, (call) async {
      if (call.method == 'start') return <String, dynamic>{'status': 'running'};
      return null;
    });
    messenger.setMockMethodCallHandler(captureChannel, (call) async => null);
  });

  tearDown(() {
    Analytics.testSink = null;
    messenger.setMockMethodCallHandler(previewChannel, null);
    messenger.setMockMethodCallHandler(captureChannel, null);
  });

  List<(String, Map<String, Object?>)> named(String name) =>
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

  CaptureScreen screen({RetakeRequest? retake}) => CaptureScreen(
        levelLabel: 'A',
        levelName: 'Eye Ring',
        nextRoute: '/next',
        retakeRequest: retake,
        sessionBox: _FakeSessionBox(),
        autoCaptureStore: _FakeAutoCaptureStore(),
        captureSettingsStore: _FakeCaptureSettingsStore(),
      );

  testWidgets('fires capture_level_started once with the canonical schema',
      (tester) async {
    await tester.pumpWidget(scope(MaterialApp(home: screen())));
    await tester.pump(); // post-frame start

    final started = named(AnalyticsEvents.captureLevelStarted);
    expect(started, hasLength(1));
    final props = started.single.$2;
    expect(props['level'], 'A');
    expect(props['capture_mode'], 'guided'); // auto-capture defaults ON
    // The level's effective count: config × flow variant (default with_bottom)
    // × Level A's 'mid' band — the same resolver the live flow uses.
    expect(
      props['target_segments'],
      effectiveSegmentsFor(
        CaptureConfig.bundledDefault,
        CaptureFlowVariant.withBottom,
        'mid',
      ),
    );
    expect(props['sensor_supported'], false); // sensors inert in the test host
    expect(props['device_type'], 'android');
    expect(props['project_id'], ''); // fake session → no project id, never null
    expect((props['session_id'] as String).isNotEmpty, isTrue);

    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('does not refire capture_level_started on a rebuild',
      (tester) async {
    await tester.pumpWidget(scope(MaterialApp(home: screen())));
    await tester.pump();
    expect(named(AnalyticsEvents.captureLevelStarted), hasLength(1));

    // Re-pump the same tree → the screen's State persists (didUpdateWidget), so
    // the once-per-session guard must hold and not refire.
    await tester.pumpWidget(scope(MaterialApp(home: screen())));
    await tester.pump();

    expect(named(AnalyticsEvents.captureLevelStarted), hasLength(1),
        reason: 'started is once-per-session, not per rebuild');

    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a retake entry suppresses started and emits retake instead',
      (tester) async {
    await tester.pumpWidget(scope(MaterialApp(
        home: screen(
            retake: const RetakeRequest(
                ringIndex: 1, replacingCaptureId: 'cap_1')))));
    await tester.pump();

    expect(named(AnalyticsEvents.captureLevelStarted), isEmpty,
        reason: 'retake entry is not a fresh start');
    expect(named(AnalyticsEvents.captureLevelRetake), hasLength(1));

    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox());
  });
}
