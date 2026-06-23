// test/capture/capture_screen_lifecycle_test.dart
//
// Verifies CaptureScreen's app-lifecycle handling (the Dart half of camera-preview
// backgrounding survival): it observes AppLifecycleState and drives the native
// camera_preview session — STOP on background (inactive/hidden/paused/detached) and
// START on foreground (resumed) — so the preview is released while backgrounded and
// rebound on return. The iOS native AVCaptureSession suspend/resume is the platform
// half (see CameraPreviewManager + camera_preview_controller_test's suspended cycle).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/current_pitch_provider.dart';
import 'package:recapture/application/capture/stability_provider.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/data/local/active_session_box.dart';
import 'package:recapture/data/local/auto_capture_box.dart';
import 'package:recapture/data/local/capture_settings_box.dart';
import 'package:recapture/domain/entities/active_session.dart';
import 'package:recapture/domain/entities/capture_settings.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/platform/imu_rotation_channel.dart';
import 'package:recapture/platform/stability_channel.dart';
import 'package:recapture/presentation/screens/capture/capture_screen.dart';
import 'package:recapture/utils/constants.dart';

/// ActiveSessionBox stand-in (Hive is not initialized in this test host).
class _FakeSessionBox extends ActiveSessionBox {
  @override
  Future<ActiveSession?> read() async => null;
}

/// Serves the bundled config synchronously (no network bootstrap timer).
class _StubConfigNotifier extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault;
}

/// AutoCaptureStore stand-in — no Hive in this test host.
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

/// Wraps the screen with the providers the TiltMeterOverlay depends on.
Widget _scoped(Widget child) => ProviderScope(
      overrides: [
        captureConfigProvider.overrideWith(() => _StubConfigNotifier()),
        orientationSourceProvider
            .overrideWithValue(const Stream<SmoothedOrientation>.empty()),
        stabilityEventSourceProvider
            .overrideWithValue(const Stream<StabilityEvent>.empty()),
      ],
      child: child,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const previewChannel = MethodChannel(AppConfig.channelCameraPreview);
  const captureChannel = MethodChannel(AppConfig.channelCapture);
  const permissionsChannel = MethodChannel(AppConfig.channelPermissions);

  late List<String> calls;

  setUp(() {
    calls = [];
    // Preview: record method names; iOS-style running result for start.
    messenger.setMockMethodCallHandler(previewChannel, (call) async {
      calls.add(call.method);
      if (call.method == 'start') return <String, dynamic>{'status': 'running'};
      return null;
    });
    // Capture channel exists (screen constructs CaptureChannel) — not used here.
    messenger.setMockMethodCallHandler(captureChannel, (call) async => null);
    // Resume re-checks camera permission via the native permissions channel;
    // grant it so the resume path restarts the preview (revocation is covered
    // separately in capture_screen_camera_test.dart).
    messenger.setMockMethodCallHandler(permissionsChannel, (call) async => 'granted');
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(previewChannel, null);
    messenger.setMockMethodCallHandler(captureChannel, null);
    messenger.setMockMethodCallHandler(permissionsChannel, null);
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      _scoped(
        MaterialApp(
          home: CaptureScreen(
            levelLabel: 'A',
            levelName: 'Eye Ring',
            nextRoute: '/next',
            sessionBox: _FakeSessionBox(),
            autoCaptureStore: _FakeAutoCaptureStore(),
            captureSettingsStore: _FakeCaptureSettingsStore(),
          ),
        ),
      ),
    );
    // The post-frame callback fires the initial start(); flush the channel call.
    await tester.pump();
    await tester.pump();
  }

  // Drives a lifecycle transition through the binding (which notifies CaptureScreen's
  // WidgetsBindingObserver), then flushes the async channel invocation.
  Future<void> sendLifecycle(WidgetTester tester, AppLifecycleState state) async {
    tester.binding.handleAppLifecycleStateChanged(state);
    // Extra pump: resume awaits an async camera-permission re-check before start.
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  // Unmounts the screen (disposing its periodic timer + controller) so the test ends
  // with no pending timers.
  Future<void> teardownScreen(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('initial mount starts the native preview', (tester) async {
    await pumpScreen(tester);
    expect(calls, contains('start'));
    await teardownScreen(tester);
  });

  testWidgets('backgrounding (inactive) stops the native preview', (tester) async {
    await pumpScreen(tester);
    calls.clear();

    await sendLifecycle(tester, AppLifecycleState.inactive);

    expect(calls, contains('stop'));
    expect(calls, isNot(contains('start')),
        reason: 'must not re-start while backgrounding');
    await teardownScreen(tester);
  });

  testWidgets('foregrounding (resumed) restarts the native preview',
      (tester) async {
    await pumpScreen(tester);
    await sendLifecycle(tester, AppLifecycleState.inactive); // background first
    calls.clear();

    await sendLifecycle(tester, AppLifecycleState.resumed);

    expect(calls, contains('start'));
    await teardownScreen(tester);
  });

  testWidgets('all background states (inactive/hidden/paused) stop, never start',
      (tester) async {
    await pumpScreen(tester);
    calls.clear();

    // Valid adjacent downward transitions: resumed → inactive → hidden → paused.
    await sendLifecycle(tester, AppLifecycleState.inactive);
    await sendLifecycle(tester, AppLifecycleState.hidden);
    await sendLifecycle(tester, AppLifecycleState.paused);

    expect(calls.where((m) => m == 'stop').length, greaterThanOrEqualTo(1));
    expect(calls, isNot(contains('start')));
    await teardownScreen(tester);
  });

  testWidgets('a full background→foreground cycle ends started', (tester) async {
    await pumpScreen(tester);
    calls.clear();

    // Down to paused, then back up to resumed (all adjacent-valid transitions).
    await sendLifecycle(tester, AppLifecycleState.inactive);
    await sendLifecycle(tester, AppLifecycleState.hidden);
    await sendLifecycle(tester, AppLifecycleState.paused);
    await sendLifecycle(tester, AppLifecycleState.hidden);
    await sendLifecycle(tester, AppLifecycleState.inactive);
    await sendLifecycle(tester, AppLifecycleState.resumed);

    // The resumed transition is the last lifecycle event → start is the last call.
    expect(calls.last, 'start');
    await teardownScreen(tester);
  });
}
