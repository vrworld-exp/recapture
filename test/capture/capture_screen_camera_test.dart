// test/capture/capture_screen_camera_test.dart
//
// Covers CaptureScreen's camera analytics + runtime permission handling:
//   - reaching `running` emits level_a_camera_opened (once)
//   - a native init failure emits level_a_camera_error with a mapped reason
//   - camera permission revoked while backgrounded → on resume, route to the
//     permissions gate and emit level_a_camera_error(permission_revoked)
//
// A real GoRouter is used so context.go(...) resolves; permission status is
// driven through the native permissions channel mock.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/application/capture/current_tilt_provider.dart';
import 'package:recapture/application/capture/stability_provider.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/data/local/active_session_box.dart';
import 'package:recapture/data/local/auto_capture_box.dart';
import 'package:recapture/data/local/capture_settings_box.dart';
import 'package:recapture/domain/entities/capture_settings.dart';
import 'package:recapture/domain/entities/active_session.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/platform/imu_rotation_channel.dart';
import 'package:recapture/platform/stability_channel.dart';
import 'package:recapture/presentation/screens/capture/capture_screen.dart';
import 'package:recapture/utils/analytics.dart';
import 'package:recapture/utils/constants.dart';

/// ActiveSessionBox that returns a fixed session without touching Hive (Hive is
/// not initialized in this widget-test host).
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

  late List<({String name, Map<String, Object?> props})> events;
  // Per-test config.
  late Object? Function(MethodCall) previewStart; // returns map OR throws
  late String permissionStatus;

  setUp(() {
    events = [];
    Analytics.testSink = (name, props) => events.add((name: name, props: props));
    previewStart = (_) => <String, dynamic>{
          'textureId': 1,
          'previewWidth': 1080,
          'previewHeight': 1920,
          'rotationDegrees': 90,
        };
    permissionStatus = 'granted';

    messenger.setMockMethodCallHandler(previewChannel, (call) async {
      if (call.method == 'start') return previewStart(call);
      return null;
    });
    messenger.setMockMethodCallHandler(captureChannel, (call) async => null);
    messenger.setMockMethodCallHandler(
        permissionsChannel, (call) async => permissionStatus);
  });

  tearDown(() {
    Analytics.testSink = null;
    messenger.setMockMethodCallHandler(previewChannel, null);
    messenger.setMockMethodCallHandler(captureChannel, null);
    messenger.setMockMethodCallHandler(permissionsChannel, null);
  });

  GoRouter buildRouter() => GoRouter(
        initialLocation: '/capture',
        routes: [
          GoRoute(
            path: '/capture',
            builder: (_, __) => CaptureScreen(
              levelLabel: 'A',
              levelName: 'Eye Ring',
              nextRoute: '/next',
              sessionBox: _FakeSessionBox(),
              autoCaptureStore: _FakeAutoCaptureStore(),
              captureSettingsStore: _FakeCaptureSettingsStore(),
            ),
          ),
          GoRoute(
            path: AppRoutes.permissions,
            builder: (_, __) => const Text('GATE'),
          ),
          GoRoute(
            path: AppRoutes.projects,
            builder: (_, __) => const Text('PROJECTS'),
          ),
          GoRoute(path: '/next', builder: (_, __) => const Text('NEXT')),
        ],
      );

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
        _scoped(MaterialApp.router(routerConfig: buildRouter())));
    await tester.pump(); // postframe start()
    await tester.pump(); // resolve start channel result
    await tester.pump();
  }

  Future<void> teardownScreen(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
  }

  List<({String name, Map<String, Object?> props})> named(String n) =>
      events.where((e) => e.name == n).toList();

  testWidgets('reaching running emits level_a_camera_opened once',
      (tester) async {
    await pumpScreen(tester);

    final opened = named(AnalyticsEvents.levelACameraOpened);
    expect(opened, hasLength(1));
    expect(opened.first.props['resolution_preset'], '1080x1920');
    expect(opened.first.props['device_type'], isNotNull);

    await teardownScreen(tester);
  });

  testWidgets('a native init failure emits level_a_camera_error(no_camera)',
      (tester) async {
    previewStart = (_) => throw PlatformException(code: 'NO_CAMERA');
    await pumpScreen(tester);

    final errs = named(AnalyticsEvents.levelACameraError);
    expect(errs, hasLength(1));
    expect(errs.first.props['reason'], 'no_camera');
    expect(named(AnalyticsEvents.levelACameraOpened), isEmpty);

    await teardownScreen(tester);
  });

  testWidgets(
      'permission revoked on resume routes to the gate and emits error',
      (tester) async {
    await pumpScreen(tester); // mounts granted, preview running

    permissionStatus = 'denied'; // revoked while backgrounded
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(); // await permission re-check
    await tester.pump();
    await tester.pump(); // navigation

    expect(find.text('GATE'), findsOneWidget);
    final errs = named(AnalyticsEvents.levelACameraError);
    expect(errs.where((e) => e.props['reason'] == 'permission_revoked'),
        hasLength(1));

    // Screen unmounted by navigation; nothing to tear down.
  });
}
