// test/capture/capture_screen_shutter_test.dart
//
// Verifies the capture screen's shutter is wired to the NATIVE single-capture
// channel (com.mayasabhaxr.recapture/capture), not a UI-only stub: a tap calls
// `captureSingle`, and the bottom-right frame counter (photos taken this session
// over the live ring N — no more demo "+12/36" offset) advances ONLY when a real
// frame comes back (a null result — no bound session / busy / non-device test
// host — must not advance it). The counter is deliberately distinct from the
// ring badge's filled/N: with inert sensors the segment is unknown, so a real
// frame advances the photo count while coverage truthfully stays 0 — this test
// pins exactly that split. The preview channel is mocked so the screen boots in
// a test host.
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
import 'package:recapture/domain/entities/capture_settings.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/presentation/screens/capture/capture_screen.dart';
import 'package:recapture/platform/imu_rotation_channel.dart';
import 'package:recapture/platform/stability_channel.dart';
import 'package:recapture/utils/constants.dart';

/// ActiveSessionBox stand-in (Hive is not initialized in this test host).
class _FakeSessionBox extends ActiveSessionBox {
  @override
  Future<ActiveSession?> read() async => null;
}

/// AutoCaptureStore stand-in — no Hive in this test host.
class _FakeAutoCaptureStore implements AutoCaptureStore {
  @override
  Future<bool?> getEnabled() async => null;
  @override
  Future<void> setEnabled(bool enabled) async {}
}

/// CaptureSettingsStore stand-in — no Hive in this test host.
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

/// Serves the bundled config synchronously (no network bootstrap timer); the
/// TiltMeterOverlay reads captureConfigProvider for its target band.
class _StubConfigNotifier extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault;
}

/// Wraps the screen with the providers the TiltMeterOverlay depends on: a stub
/// config and inert sensor streams (no platform channels in the test host).
/// Inert sensors also mean the ring segment stays UNKNOWN and stability never
/// goes stable — so the auto-capture loop can never fire behind these taps.
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

  late List<String> captureCalls;
  // Set per-test: what the native captureSingle returns (a frame map, or null).
  late Map<String, dynamic>? captureResult;

  setUp(() {
    captureCalls = [];
    captureResult = null;

    // Preview: accept start (iOS-style status result), no-op stop/dispose.
    messenger.setMockMethodCallHandler(previewChannel, (call) async {
      if (call.method == 'start') return <String, dynamic>{'status': 'running'};
      return null;
    });
    messenger.setMockMethodCallHandler(captureChannel, (call) async {
      captureCalls.add(call.method);
      return captureResult;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(previewChannel, null);
    messenger.setMockMethodCallHandler(captureChannel, null);
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      _scoped(
        MaterialApp(
          home: CaptureScreen(
            levelLabel: 'Level A',
            levelName: 'Intro',
            nextRoute: '/next',
            sessionBox: _FakeSessionBox(),
            autoCaptureStore: _FakeAutoCaptureStore(),
            captureSettingsStore: _FakeCaptureSettingsStore(),
          ),
        ),
      ),
    );
    // Let the post-frame callback fire start() on the preview controller.
    await tester.pump();
  }

  // Unmounts the screen (disposing its periodic instruction timer + controller)
  // and lets the 200ms flash timer drain, so the test ends with no pending timers.
  Future<void> teardownScreen(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('shutter tap calls native captureSingle', (tester) async {
    captureResult = {'id': 'cap_0', 'path': '/tmp/cap_0.jpg', 'timestampNs': 1};
    await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('capture_shutter')));
    await tester.pump(); // resolve captureSingle future
    await tester.pump(); // apply setState

    expect(captureCalls, contains('captureSingle'));
    await teardownScreen(tester);
  });

  testWidgets('a successful capture advances the frame counter', (tester) async {
    captureResult = {'id': 'cap_0', 'path': '/tmp/cap_0.jpg', 'timestampNs': 1};
    await pumpScreen(tester);

    // Two 0/12 readouts pre-capture: the bottom-right photo counter AND the ring
    // badge's filled/N (bundled-default 'mid' band N = 10). Never the demo 12/36.
    expect(find.text('0/12'), findsNWidgets(2));
    expect(find.text('12/36'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('capture_shutter')));
    await tester.pump();
    await tester.pump();

    // The photo counter advanced; the ring badge stays 0/12 (inert sensors →
    // unknown segment → a real frame cannot claim coverage).
    expect(find.text('1/12'), findsOneWidget);
    expect(find.text('0/12'), findsOneWidget);
    await teardownScreen(tester);
  });

  testWidgets('a null capture (no frame) does NOT advance the counter',
      (tester) async {
    captureResult = null; // no bound session / busy / unsupported
    await pumpScreen(tester);

    expect(find.text('0/12'), findsNWidgets(2));

    await tester.tap(find.byKey(const ValueKey('capture_shutter')));
    await tester.pump();
    await tester.pump();

    expect(captureCalls, contains('captureSingle'));
    expect(find.text('0/12'), findsNWidgets(2),
        reason: 'counter must not advance');
    expect(find.text('1/12'), findsNothing);
    await teardownScreen(tester);
  });
}
