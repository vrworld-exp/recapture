// test/capture/tilt_meter_overlay_test.dart
//
// Widget tests for the Level A tilt meter: it renders the "Tilt" gauge, shows
// the correct directional hint for in/above/below-band pitch (not inverted),
// throttle-emits `tilt_meter_out_of_band`, and degrades to a non-blocking
// fallback when the sensor is unsupported. Config resolves to the bundled
// default (mid band = [30,60)); the native pitch stream is injected.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/current_pitch_provider.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/platform/imu_rotation_channel.dart';
import 'package:recapture/presentation/widgets/tilt_meter_overlay.dart';
import 'package:recapture/utils/analytics.dart';

/// Serves the bundled default synchronously (no network bootstrap timer).
class _StubConfigNotifier extends ConfigNotifier {
  @override
  CaptureConfig build() => CaptureConfig.bundledDefault;
}

SmoothedOrientation _at(double deg) {
  final rad = deg * math.pi / 180.0;
  return SmoothedOrientation(
    yaw: 0,
    pitch: rad,
    roll: 0,
    qx: 0,
    qy: 0,
    qz: 0,
    qw: 1,
    timestampNs: 0,
  );
}

Future<void> _pumpMeter(
  WidgetTester tester,
  Stream<SmoothedOrientation> source, {
  bool reduceMotion = false,
  Duration outSustain = const Duration(seconds: 2),
  Duration outCooldown = const Duration(seconds: 3),
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        captureConfigProvider.overrideWith(() => _StubConfigNotifier()),
        orientationSourceProvider.overrideWithValue(source),
      ],
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: Scaffold(
            body: Stack(
              children: [
                TiltMeterOverlay(
                  outSustain: outSustain,
                  outCooldown: outCooldown,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  late List<({String name, Map<String, Object?> props})> events;

  setUp(() {
    events = [];
    Analytics.testSink = (name, props) => events.add((name: name, props: props));
  });

  tearDown(() {
    Analytics.testSink = null;
  });

  testWidgets('renders the Tilt gauge label', (tester) async {
    final source = StreamController<SmoothedOrientation>.broadcast();
    addTearDown(source.close);
    await _pumpMeter(tester, source.stream);
    expect(find.text('Tilt'), findsOneWidget);
  });

  testWidgets('in-band pitch shows "Hold steady"', (tester) async {
    final source = StreamController<SmoothedOrientation>.broadcast();
    addTearDown(source.close);
    await _pumpMeter(tester, source.stream);

    source.add(_at(45)); // mid band [30,60)
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Hold steady'), findsOneWidget);
  });

  testWidgets('above-band pitch shows "Tilt down" (not inverted)',
      (tester) async {
    final source = StreamController<SmoothedOrientation>.broadcast();
    addTearDown(source.close);
    await _pumpMeter(tester, source.stream);

    source.add(_at(80)); // above 60
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Tilt down'), findsOneWidget);
    expect(find.text('Tilt up'), findsNothing);
  });

  testWidgets('below-band pitch shows "Tilt up"', (tester) async {
    final source = StreamController<SmoothedOrientation>.broadcast();
    addTearDown(source.close);
    await _pumpMeter(tester, source.stream);

    source.add(_at(10)); // below 30
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Tilt up'), findsOneWidget);
  });

  testWidgets('unsupported sensor shows a non-blocking fallback',
      (tester) async {
    final source = StreamController<SmoothedOrientation>.broadcast();
    addTearDown(source.close);
    await _pumpMeter(tester, source.stream);

    source.addError(Exception('SENSOR_UNAVAILABLE'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Tilt guidance unavailable'), findsOneWidget);
    expect(find.text('Hold steady'), findsNothing);
  });

  testWidgets('sustained out-of-band emits a throttled analytics event',
      (tester) async {
    final source = StreamController<SmoothedOrientation>.broadcast();
    addTearDown(source.close);
    // Zero windows make the throttle fire on the first sustained out-of-band
    // sample (wall-clock does not advance under tester.pump in tests).
    await _pumpMeter(
      tester,
      source.stream,
      outSustain: Duration.zero,
      outCooldown: Duration.zero,
    );

    source.add(_at(80)); // above the band
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final outEvents =
        events.where((e) => e.name == AnalyticsEvents.tiltMeterOutOfBand);
    expect(outEvents, isNotEmpty);
    expect(outEvents.first.props['direction'], 'above');
    expect(outEvents.first.props['target_band_id'], 'mid');
  });

  testWidgets('reduce-motion still tracks the needle (no crash)',
      (tester) async {
    final source = StreamController<SmoothedOrientation>.broadcast();
    addTearDown(source.close);
    await _pumpMeter(tester, source.stream, reduceMotion: true);

    source.add(_at(45));
    await tester.pump(); // deliver stream sample → AsyncValue
    await tester.pump(); // rebuild after ref.listen setState
    expect(find.text('Hold steady'), findsOneWidget);
  });
}
