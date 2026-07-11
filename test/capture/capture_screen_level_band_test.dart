// test/capture/capture_screen_level_band_test.dart
//
// Proves the capture screen wires THIS level's pitch band (pitchBandIdForLevel)
// into the tilt indicator: the SAME smoothed pitch yields different guidance per
// level because each level targets a different band. 40° is inside Level A's Eye
// Ring [60,120) ("Hold steady") but below Level B's Top Ring [120,180) ("Tilt down").
// The shutter gate shares the same _levelBandId, so this also exercises the
// per-level enforcement wiring (the pure gate itself is covered exhaustively by
// auto_capture_pitch_band_test.dart).
import 'dart:async';
import 'dart:math' as math;

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
import 'package:recapture/presentation/widgets/tilt_meter_overlay.dart';
import 'package:recapture/platform/imu_rotation_channel.dart';
import 'package:recapture/platform/stability_channel.dart';
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

/// A SmoothedOrientation whose `cameraTiltDegrees` equals [tiltDeg]: a rotation
/// of (180° − tilt) about device X (see camera_tilt_test.dart).
SmoothedOrientation _at(double tiltDeg) {
  final theta = (180.0 - tiltDeg) * math.pi / 180.0;
  return SmoothedOrientation(
    yaw: 0,
    pitch: 0,
    roll: 0,
    qx: math.sin(theta / 2),
    qy: 0,
    qz: 0,
    qw: math.cos(theta / 2),
    timestampNs: 0,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const previewChannel = MethodChannel(AppConfig.channelCameraPreview);
  const captureChannel = MethodChannel(AppConfig.channelCapture);

  setUp(() {
    messenger.setMockMethodCallHandler(previewChannel, (call) async {
      if (call.method == 'start') return <String, dynamic>{'status': 'running'};
      return null;
    });
    messenger.setMockMethodCallHandler(captureChannel, (call) async => null);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(previewChannel, null);
    messenger.setMockMethodCallHandler(captureChannel, null);
  });

  Future<void> pumpMeter(
    WidgetTester tester, {
    required String levelLabel,
    required Stream<SmoothedOrientation> source,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          captureConfigProvider.overrideWith(() => _StubConfigNotifier()),
          orientationSourceProvider.overrideWithValue(source),
          stabilityEventSourceProvider
              .overrideWithValue(const Stream<StabilityEvent>.empty()),
        ],
        child: MaterialApp(
          home: CaptureScreen(
            levelLabel: levelLabel,
            levelName: 'Ring',
            nextRoute: '/next',
            sessionBox: _FakeSessionBox(),
            autoCaptureStore: _FakeAutoCaptureStore(),
            captureSettingsStore: _FakeCaptureSettingsStore(),
          ),
        ),
      ),
    );
    await tester.pump(); // post-frame start()
  }

  testWidgets('Level B targets the Top Ring band: 100° reads "Tilt down"',
      (tester) async {
    final source = StreamController<SmoothedOrientation>.broadcast();
    addTearDown(source.close);
    await pumpMeter(tester, levelLabel: 'B', source: source.stream);

    source.add(_at(100)); // below Top Ring [120,180) → aim further down
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // Scope to the tilt meter (the HUD has other "Hold steady" copy elsewhere).
    final meter = find.byType(TiltMeterOverlay);
    expect(find.descendant(of: meter, matching: find.text('Tilt down')),
        findsOneWidget);
    expect(find.descendant(of: meter, matching: find.text('Hold steady')),
        findsNothing);

    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'Level A targets the Eye Ring band: the same 100° reads "Hold steady"',
      (tester) async {
    final source = StreamController<SmoothedOrientation>.broadcast();
    addTearDown(source.close);
    await pumpMeter(tester, levelLabel: 'A', source: source.stream);

    source.add(_at(100)); // inside Eye Ring [60,120)
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final meter = find.byType(TiltMeterOverlay);
    expect(find.descendant(of: meter, matching: find.text('Hold steady')),
        findsOneWidget);
    expect(find.descendant(of: meter, matching: find.text('Tilt down')),
        findsNothing);

    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
  });
}
