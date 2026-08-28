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

/// A smoothed-orientation sample whose camera TILT equals [tiltDeg] (0–180°
/// scale; encoded as a (180° − tilt) rotation about device X — see
/// camera_tilt_test.dart) with [yawDeg] in DEGREES.
SmoothedOrientation _orientation({
  required double tiltDeg,
  double yawDeg = 0,
  int timestampNs = 0,
}) {
  final theta = (180.0 - tiltDeg) * (3.141592653589793 / 180.0);
  return SmoothedOrientation(
    yaw: yawDeg * (3.141592653589793 / 180.0),
    pitch: 0,
    roll: 0,
    qx: math.sin(theta / 2),
    qy: 0,
    qz: 0,
    qw: math.cos(theta / 2),
    timestampNs: timestampNs,
  );
}

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

  /// Taps the bottom-bar play/pause icon. Capture enters PAUSED (the screen
  /// never starts capturing on its own), so every test that expects the auto
  /// loop to be able to fire must press play first.
  Future<void> tapPlayPause(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('capture_play_pause')));
    await tester.pump();
  }

  /// Emits a debounced STABLE transition and a handful of in-band (Level A
  /// 'mid' = [30°, 60°)) orientation ticks at yaw 0 (→ segment 0). Multiple
  /// ticks because the first valid sample seeds the yaw baseline / segment
  /// provider before the pitch listener can read a known segment.
  Future<void> driveInBandStable(WidgetTester tester, {double yawDeg = 0}) async {
    stability.add(const StabilityStateEvent(
      stable: true,
      gyroMag: 0,
      linAccelMag: 0,
      timestampNs: 0,
    ));
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      orientation.add(_orientation(tiltDeg: 90, yawDeg: yawDeg, timestampNs: i));
      await tester.pump();
      await tester.pump(); // stream → provider → tick → fire resolves
    }
  }

  testWidgets(
      'AUTO ON: an in-band stable tick fires a capture on its own '
      '(autocapture_triggered + segment filled, single-shot)', (tester) async {
    await pumpScreen(tester, autoEnabled: true);
    await tapPlayPause(tester); // capture starts paused — press play
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
    orientation.add(_orientation(tiltDeg: 90, timestampNs: 99));
    await tester.pump();
    await tester.pump();
    expect(captureCalls, 1);

    await tester.pump(const Duration(milliseconds: 350)); // drain flash timer
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('AUTO OFF: the same in-band stable ticks never fire',
      (tester) async {
    await pumpScreen(tester, autoEnabled: false);
    await tapPlayPause(tester); // playing — so AUTO OFF is the only gate here
    await driveInBandStable(tester);

    expect(captureCalls, 0);
    expect(autoEvents(), isEmpty);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'starts PAUSED: AUTO ON in-band stable ticks never fire until play is '
      'tapped, and pausing again stops the loop', (tester) async {
    await pumpScreen(tester, autoEnabled: true);

    // No play tap: entering the screen must never begin capturing on its own.
    await driveInBandStable(tester);
    expect(captureCalls, 0);
    expect(autoEvents(), isEmpty);

    // Play → the same conjunction now fires.
    await tapPlayPause(tester);
    await driveInBandStable(tester);
    expect(captureCalls, 1);

    // Let the 200ms post-shot flash clear (it covers the whole screen and
    // would swallow the tap), then pause and wait out the REAL 500ms cooldown
    // (it is wall-clock, not test-clock) so the pause gate is the only thing
    // that can explain the absence of a second fire.
    await tester.pump(const Duration(milliseconds: 250));
    await tapPlayPause(tester);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)));

    // A DIFFERENT (unfilled) segment past the cooldown still never fires.
    await driveInBandStable(tester, yawDeg: 180);
    expect(captureCalls, 1);
    expect(autoEvents(), hasLength(1));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('AUTO ON but out of band: never fires', (tester) async {
    await pumpScreen(tester, autoEnabled: true);
    await tapPlayPause(tester); // playing — so the band is the only gate here
    stability.add(const StabilityStateEvent(
      stable: true,
      gyroMag: 0,
      linAccelMag: 0,
      timestampNs: 0,
    ));
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      // Below the 'mid' band's 60° floor — the user still needs to tilt down.
      orientation.add(_orientation(tiltDeg: 10, timestampNs: i));
      await tester.pump();
      await tester.pump();
    }

    expect(captureCalls, 0);
    expect(autoEvents(), isEmpty);

    await tester.pumpWidget(const SizedBox());
  });
}
