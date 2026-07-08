// test/capture/auto_capture_wiring_test.dart
//
// Instrument-tests the WIRED auto-capture fire loop on the capture screen: with
// AUTO ON, an in-band + stable orientation tick over an unfilled segment fires a
// native capture on its own (no shutter tap) — emitting `autocapture_triggered`,
// filling the segment, and advancing the HUD counter. Also pins the two key
// negative rules: a filled segment never re-fires (single-shot), and AUTO OFF
// evaluates without ever firing. This is the regression net for the bug where
// the AUTO pill toggled a preference that no fire loop consumed.
import 'dart:async';

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
  _FakeAutoCaptureStore({this.enabled});
  final bool? enabled;
  @override
  Future<bool?> getEnabled() async => enabled;
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

/// A smoothed-orientation sample with [pitchDeg]/[yawDeg] given in DEGREES
/// (SmoothedOrientation stores radians; pitchDegrees/yawDegrees derive back).
SmoothedOrientation _orientation({
  required double pitchDeg,
  double yawDeg = 0,
  int timestampNs = 0,
}) =>
    SmoothedOrientation(
      yaw: yawDeg * (3.141592653589793 / 180.0),
      pitch: pitchDeg * (3.141592653589793 / 180.0),
      roll: 0,
      qx: 0,
      qy: 0,
      qz: 0,
      qw: 1,
      timestampNs: timestampNs,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const previewChannel = MethodChannel(AppConfig.channelCameraPreview);
  const captureChannel = MethodChannel(AppConfig.channelCapture);

  late List<(String, Map<String, Object?>)> events;
  late int captureCalls;
  late StreamController<SmoothedOrientation> orientation;
  late StreamController<StabilityEvent> stability;

  setUp(() {
    events = [];
    captureCalls = 0;
    orientation = StreamController<SmoothedOrientation>.broadcast();
    stability = StreamController<StabilityEvent>.broadcast();
    Analytics.testSink = (n, p) => events.add((n, p));
    messenger.setMockMethodCallHandler(previewChannel, (call) async {
      if (call.method == 'start') return <String, dynamic>{'status': 'running'};
      return null;
    });
    messenger.setMockMethodCallHandler(captureChannel, (call) async {
      if (call.method == 'captureSingle') {
        captureCalls++;
        return <String, dynamic>{
          'id': 'auto_$captureCalls',
          'path': '/tmp/auto_$captureCalls.jpg',
          'timestampNs': captureCalls,
        };
      }
      return null;
    });
  });

  tearDown(() {
    Analytics.testSink = null;
    messenger.setMockMethodCallHandler(previewChannel, null);
    messenger.setMockMethodCallHandler(captureChannel, null);
    orientation.close();
    stability.close();
  });

  List<Map<String, Object?>> autoEvents() => events
      .where((e) => e.$1 == AnalyticsEvents.autocaptureTriggered)
      .map((e) => e.$2)
      .toList();

  Widget scope(Widget child) => ProviderScope(
        overrides: [
          captureConfigProvider.overrideWith(() => _StubConfigNotifier()),
          orientationSourceProvider.overrideWithValue(orientation.stream),
          stabilityEventSourceProvider.overrideWithValue(stability.stream),
        ],
        child: child,
      );

  Future<void> pumpScreen(WidgetTester tester, {bool? autoEnabled}) async {
    await tester.pumpWidget(scope(MaterialApp(
      home: CaptureScreen(
        levelLabel: 'A',
        levelName: 'Eye Ring',
        nextRoute: '/next',
        sessionBox: _FakeSessionBox(),
        autoCaptureStore: _FakeAutoCaptureStore(enabled: autoEnabled),
        captureSettingsStore: _FakeCaptureSettingsStore(),
      ),
    )));
    await tester.pump(); // post-frame: preview start + session started
    await tester.pump(); // preview 'start' resolves → running
  }

  /// Emits a debounced STABLE transition and a handful of in-band (Level A
  /// 'mid' = [30°, 60°)) orientation ticks at yaw 0 (→ segment 0). Multiple
  /// ticks because the first valid sample seeds the yaw baseline / segment
  /// provider before the pitch listener can read a known segment.
  Future<void> driveInBandStable(WidgetTester tester) async {
    stability.add(const StabilityStateEvent(
      stable: true,
      gyroMag: 0,
      linAccelMag: 0,
      timestampNs: 0,
    ));
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      orientation.add(_orientation(pitchDeg: 45, timestampNs: i));
      await tester.pump();
      await tester.pump(); // stream → provider → tick → fire resolves
    }
  }

  testWidgets(
      'AUTO ON: an in-band stable tick fires a capture on its own '
      '(autocapture_triggered + segment filled, single-shot)', (tester) async {
    await pumpScreen(tester, autoEnabled: true);
    await driveInBandStable(tester);

    // Exactly ONE fire: the fire-time segment filled, so every later tick over
    // the same heading fails the !isCurrentFilled condition.
    expect(captureCalls, 1);
    final auto = autoEvents();
    expect(auto, hasLength(1));
    final p = auto.single;
    expect(p['level'], 'A');
    expect(p['ring_index'], 0);
    expect(p['in_band'], true);
    expect(p['stable'], true);
    expect(p['sensor_supported'], true);
    expect((p['session_id'] as String).isNotEmpty, isTrue);

    // The HUD advanced: no manual event was ever emitted for it.
    expect(
      events.where((e) => e.$1 == AnalyticsEvents.manualCaptureTriggered),
      isEmpty,
    );

    // Cooldown passes but the segment stays filled → still no re-fire.
    await tester.pump(const Duration(milliseconds: 600));
    orientation.add(_orientation(pitchDeg: 45, timestampNs: 99));
    await tester.pump();
    await tester.pump();
    expect(captureCalls, 1);

    await tester.pump(const Duration(milliseconds: 350)); // drain flash timer
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('AUTO OFF: the same in-band stable ticks never fire',
      (tester) async {
    await pumpScreen(tester, autoEnabled: false);
    await driveInBandStable(tester);

    expect(captureCalls, 0);
    expect(autoEvents(), isEmpty);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('AUTO ON but out of band: never fires', (tester) async {
    await pumpScreen(tester, autoEnabled: true);
    stability.add(const StabilityStateEvent(
      stable: true,
      gyroMag: 0,
      linAccelMag: 0,
      timestampNs: 0,
    ));
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      // Below the 'mid' band's 30° floor — the user still needs to tilt up.
      orientation.add(_orientation(pitchDeg: 10, timestampNs: i));
      await tester.pump();
      await tester.pump();
    }

    expect(captureCalls, 0);
    expect(autoEvents(), isEmpty);

    await tester.pumpWidget(const SizedBox());
  });
}
