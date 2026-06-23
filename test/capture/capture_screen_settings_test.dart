// test/capture/capture_screen_settings_test.dart
//
// Covers the Settings sheet wiring at the parent (CaptureScreen):
//   - the top-bar Settings icon opens the sheet with persisted values
//   - changing a setting persists via the injected store + emits analytics
//   - auto-capture routes through the SAME store as the pill (shared source)
//   - save-to-gallery ON with permission DENIED reverts to OFF (live in-sheet)
//
// A real GoRouter + the native channel mocks boot the screen in a test host.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
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
import 'package:recapture/utils/analytics.dart';
import 'package:recapture/utils/constants.dart';

class _FakeSessionBox extends ActiveSessionBox {
  @override
  Future<ActiveSession?> read() async => null;
}

class _StubConfigNotifier extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault;
}

/// Records auto-capture writes (the pill's store — shared source).
class _SpyAutoCaptureStore implements AutoCaptureStore {
  final List<bool> writes = [];
  bool? initial;
  _SpyAutoCaptureStore({this.initial});
  @override
  Future<bool?> getEnabled() async => initial;
  @override
  Future<void> setEnabled(bool enabled) async => writes.add(enabled);
}

/// Records save-to-gallery + quality writes and serves preset initial values.
class _SpyCaptureSettingsStore implements CaptureSettingsStore {
  final List<bool> saveWrites = [];
  final List<QualityMode> qualityWrites = [];
  bool? initialSave;
  QualityMode? initialQuality;
  _SpyCaptureSettingsStore({this.initialSave, this.initialQuality});
  @override
  Future<bool?> getSaveToGallery() async => initialSave;
  @override
  Future<void> setSaveToGallery(bool enabled) async => saveWrites.add(enabled);
  @override
  Future<QualityMode?> getQuality() async => initialQuality;
  @override
  Future<void> setQuality(QualityMode mode) async => qualityWrites.add(mode);
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

  late List<({String name, Map<String, Object?> props})> events;
  late String permissionStatus;

  setUp(() {
    events = [];
    Analytics.testSink = (name, props) => events.add((name: name, props: props));
    permissionStatus = 'granted';
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

  Future<void> pumpScreen(
    WidgetTester tester, {
    required AutoCaptureStore autoStore,
    required CaptureSettingsStore settingsStore,
  }) async {
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
            autoCaptureStore: autoStore,
            captureSettingsStore: settingsStore,
          ),
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

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('opens with persisted values', (tester) async {
    await pumpScreen(
      tester,
      autoStore: _SpyAutoCaptureStore(initial: true),
      settingsStore: _SpyCaptureSettingsStore(
        initialSave: true,
        initialQuality: QualityMode.high,
      ),
    );
    await openSettings(tester);

    expect(find.text('Capture settings'), findsOneWidget);
    final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
    expect(switches[0].value, isTrue); // auto-capture (initial true)
    expect(switches[1].value, isTrue); // save-to-gallery (persisted true)

    await teardown(tester);
  });

  testWidgets('auto-capture toggle persists via the shared store',
      (tester) async {
    final autoStore = _SpyAutoCaptureStore(initial: true);
    await pumpScreen(
      tester,
      autoStore: autoStore,
      settingsStore: _SpyCaptureSettingsStore(),
    );
    await openSettings(tester);

    await tester.tap(find.byType(Switch).first); // auto-capture off
    await tester.pumpAndSettle();

    // Persisted through the SAME store the pill uses.
    expect(autoStore.writes.last, isFalse);
    expect(
      events.where((e) => e.name == AnalyticsEvents.captureSettingChanged),
      isNotEmpty,
    );

    await teardown(tester);
  });

  testWidgets('quality change persists', (tester) async {
    final settingsStore = _SpyCaptureSettingsStore();
    await pumpScreen(
      tester,
      autoStore: _SpyAutoCaptureStore(initial: true),
      settingsStore: settingsStore,
    );
    await openSettings(tester);

    await tester.tap(find.text('High'));
    await tester.pumpAndSettle();

    expect(settingsStore.qualityWrites.last, QualityMode.high);

    await teardown(tester);
  });

  testWidgets('save-to-gallery ON denied → reverts to OFF', (tester) async {
    permissionStatus = 'denied';
    final settingsStore = _SpyCaptureSettingsStore(initialSave: false);
    await pumpScreen(
      tester,
      autoStore: _SpyAutoCaptureStore(initial: true),
      settingsStore: settingsStore,
    );
    await openSettings(tester);

    await tester.tap(find.byType(Switch).at(1)); // save-to-gallery ON
    await tester.pumpAndSettle();

    // Reverted: the switch shows OFF and the last persisted value is false.
    final saveSwitch =
        tester.widgetList<Switch>(find.byType(Switch)).elementAt(1);
    expect(saveSwitch.value, isFalse);
    expect(settingsStore.saveWrites.last, isFalse);

    await teardown(tester);
  });
}
