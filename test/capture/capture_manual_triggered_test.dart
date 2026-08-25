// test/capture/capture_manual_triggered_test.dart
//
// Instrument-tests the wired `manual_capture_triggered` fire point: a shutter tap
// emits exactly one event at initiation, with the live readiness, the session
// context, and a coherent attempt_number that increments across taps. The test
// host has no usable sensors → the capture fails open, so this also exercises the
// was_blocked_override=true / actual-readiness recording path.
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
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/capture_settings.dart';
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
    Analytics.testSink = (n, p) => events.add((n, p));
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

  List<Map<String, Object?>> manualEvents() => events
      .where((e) => e.$1 == AnalyticsEvents.manualCaptureTriggered)
      .map((e) => e.$2)
      .toList();

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

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(scope(MaterialApp(
      home: CaptureScreen(
        levelLabel: 'A',
        levelName: 'Eye Ring',
        nextRoute: '/next',
        sessionBox: _FakeSessionBox(),
        autoCaptureStore: _FakeAutoCaptureStore(),
        captureSettingsStore: _FakeCaptureSettingsStore(),
      ),
    )));
    await tester.pump(); // post-frame start (session started)
  }

  Future<void> tapShutter(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('capture_shutter')));
    await tester.pump(); // resolve captureSingle
    await tester.pump(); // settle
  }

  testWidgets('a shutter tap emits one manual_capture_triggered with context',
      (tester) async {
    await pump(tester);
    await tapShutter(tester);

    final manual = manualEvents();
    expect(manual, hasLength(1));
    final p = manual.single;
    expect(p['level'], 'A');
    expect(p['attempt_number'], 1);
    expect(p['ring_index'], isNull); // not retaking, no live ring progress
    expect(p['in_band'], false);
    expect(p['stable'], false);
    expect(p['sensor_supported'], false); // inert sensors in the test host
    expect(p['was_blocked_override'], true); // fail-open capture
    expect(p['device_type'], 'android');
    expect((p['session_id'] as String).isNotEmpty, isTrue);

    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('attempt_number increments across taps (shared sequence)',
      (tester) async {
    await pump(tester);
    await tapShutter(tester);
    await tapShutter(tester);

    final attempts =
        manualEvents().map((p) => p['attempt_number']).toList();
    expect(attempts, [1, 2]);

    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox());
  });
}
