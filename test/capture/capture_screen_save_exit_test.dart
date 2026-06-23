// test/capture/capture_screen_save_exit_test.dart
//
// Covers the parent (CaptureScreen) Save & Exit wiring:
//   - top-bar back with captured progress shows the modal (not a direct exit)
//   - choosing Keep Capturing stays on the screen
//   - choosing Save & Exit / Discard & Exit navigates out
//   - with no progress, top-bar back exits directly (no modal)
//
// A real GoRouter + native channel mocks boot the screen in a test host.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/application/capture/current_pitch_provider.dart';
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
import 'package:recapture/utils/constants.dart';

class _FakeSessionBox extends ActiveSessionBox {
  @override
  Future<ActiveSession?> read() async => null;
}

class _StubConfigNotifier extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault;
}

class _FakeAutoCaptureStore implements AutoCaptureStore {
  @override
  Future<bool?> getEnabled() async => false; // default OFF so no auto noise
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

  setUp(() {
    messenger.setMockMethodCallHandler(previewChannel, (call) async {
      if (call.method == 'start') {
        return <String, dynamic>{
          'textureId': 1,
          'previewWidth': 1080,
          'previewHeight': 1920,
          'rotationDegrees': 90,
        };
      }
      return null;
    });
    // captureSingle returns a real frame so the counter advances (progress).
    messenger.setMockMethodCallHandler(captureChannel, (call) async {
      if (call.method == 'captureSingle') {
        return <String, dynamic>{
          'id': 'f1',
          'path': '/tmp/f1.jpg',
          'timestampNs': 1,
        };
      }
      return null;
    });
    messenger.setMockMethodCallHandler(
        permissionsChannel, (call) async => 'granted');
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(previewChannel, null);
    messenger.setMockMethodCallHandler(captureChannel, null);
    messenger.setMockMethodCallHandler(permissionsChannel, null);
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    final router = GoRouter(
      initialLocation: '/capture',
      routes: [
        GoRoute(
          path: '/capture',
          builder: (_, __) => CaptureScreen(
            levelLabel: 'Level A',
            levelName: 'Eye Ring',
            nextRoute: '/next',
            sessionBox: _FakeSessionBox(),
            autoCaptureStore: _FakeAutoCaptureStore(),
            captureSettingsStore: _FakeCaptureSettingsStore(),
          ),
        ),
        GoRoute(
          path: AppRoutes.projects,
          builder: (_, __) => const Text('PROJECTS'),
        ),
        GoRoute(path: '/next', builder: (_, __) => const Text('NEXT')),
      ],
    );
    await tester.pumpWidget(
        _scoped(MaterialApp.router(routerConfig: router)));
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  /// Captures one photo so the session has unsaved progress.
  Future<void> captureOne(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('capture_shutter')));
    await tester.pumpAndSettle();
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('no progress → top-bar back exits directly (no modal)',
      (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(find.text('Save your progress?'), findsNothing);
    expect(find.text('PROJECTS'), findsOneWidget); // exited directly
    await teardown(tester);
  });

  testWidgets('with progress → top-bar back shows the modal with the count',
      (tester) async {
    await pumpScreen(tester);
    await captureOne(tester);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(find.text('Save your progress?'), findsOneWidget);
    expect(find.textContaining('1 photo'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('Keep Capturing stays on the capture screen', (tester) async {
    await pumpScreen(tester);
    await captureOne(tester);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Keep Capturing'));
    await tester.pumpAndSettle();

    expect(find.text('PROJECTS'), findsNothing); // stayed
    expect(find.byTooltip('Back'), findsOneWidget); // still on capture
    await teardown(tester);
  });

  testWidgets('Save & Exit navigates out', (tester) async {
    await pumpScreen(tester);
    await captureOne(tester);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save & Exit'));
    await tester.pumpAndSettle();

    expect(find.text('PROJECTS'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('Discard & Exit navigates out', (tester) async {
    await pumpScreen(tester);
    await captureOne(tester);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Discard & Exit'));
    await tester.pumpAndSettle();

    expect(find.text('PROJECTS'), findsOneWidget);
    await teardown(tester);
  });
}
