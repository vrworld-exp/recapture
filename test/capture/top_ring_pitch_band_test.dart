// test/capture/top_ring_pitch_band_test.dart
//
// Top Ring (+ generalized) pitch-band enforcement + tuned tilt indicator, on
// the 0–180° camera-tilt scale (0 = camera at the sky, 90 = horizon, 180 = at
// the ground; higher tilt = phone aimed further DOWN).
//
// Covers the wiring this feature adds on top of the already-parameterized gate
// (shouldCapture/isPitchInBand) and indicator (TiltMeterOverlay):
//   1. pitchBandIdForLevel — the SINGLE level→band-id source (A=mid, B=high=Top
//      Ring, C=low=Bottom Ring); the degrees live in config, not here.
//   2. tiltGaugeRangeForBand — the gauge auto-tunes/adapts to ANY band, framing
//      it with head/foot room.
//   3. TiltMeterOverlay(levelBandId:) — the indicator's below/in/above guidance
//      tracks the LEVEL's band, not a hardcoded one (tuned for Top Ring
//      [110,180), and a custom band proves the generalization). Below the band
//      (aimed too far up) → "Tilt down"; above it → "Tilt up".
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/analytics/capture_level_events.dart';
import 'package:recapture/application/capture/current_tilt_provider.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/tilt_target.dart';
import 'package:recapture/platform/imu_rotation_channel.dart';
import 'package:recapture/presentation/widgets/tilt_meter_overlay.dart';
import 'package:recapture/utils/analytics.dart';

/// Serves a fixed config synchronously (no network bootstrap timer).
class _StubConfig extends ConfigNotifier {
  _StubConfig(this._config);
  final CaptureConfig _config;
  @override
  CaptureConfig build() => _config;
}

/// A SmoothedOrientation whose `cameraTiltDegrees` equals [tiltDeg]: a rotation
/// of (180° − tilt) about device X (see camera_tilt_test.dart).
SmoothedOrientation _atTilt(double tiltDeg) {
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
  group('pitchBandIdForLevel — single level→band source', () {
    test('A=mid (Eye Ring), B=high (Top Ring), C=low (Bottom Ring)', () {
      expect(pitchBandIdForLevel(CaptureLevel.a), 'mid');
      expect(pitchBandIdForLevel(CaptureLevel.b), 'high');
      expect(pitchBandIdForLevel(CaptureLevel.c), 'low');
    });
  });

  group('tiltGaugeRangeForBand — adaptive, per-band gauge framing', () {
    TiltTarget band(double min, double max) =>
        TiltTarget(minDegrees: min, maxDegrees: max, bandId: 'b');

    test('a [120,180) band frames to [60,240] (one span head/foot room)', () {
      final r = tiltGaugeRangeForBand(band(120, 180));
      expect(r.min, 60);
      expect(r.max, 240);
    });

    test('a [60,120) band frames to [0,180]', () {
      final r = tiltGaugeRangeForBand(band(60, 120));
      expect(r.min, 0);
      expect(r.max, 180);
    });

    test('a [0,60) band frames to [-60,120] (needle clamps at the ends)',
        () {
      final r = tiltGaugeRangeForBand(band(0, 60));
      expect(r.min, -60);
      expect(r.max, 120);
    });

    test('a very narrow band still gets the minMargin floor', () {
      final r = tiltGaugeRangeForBand(band(50, 54), minMargin: 15);
      expect(r.min, 35); // 50 - 15
      expect(r.max, 69); // 54 + 15
      expect(r.max - r.min, greaterThan(4));
    });
  });

  group('TiltMeterOverlay tunes its guidance to the level band', () {
    // Pumps a FRESH overlay and feeds a single tilt sample. A fresh mount seeds
    // the tilt EMA directly to that value (no smoothing lag), so the asserted
    // state is exactly the one [tilt] maps to under the band.
    Future<void> pumpTilt(
      WidgetTester tester, {
      required String bandId,
      required double tilt,
      CaptureConfig config = CaptureConfig.bundledDefault,
    }) async {
      final source = StreamController<SmoothedOrientation>.broadcast();
      addTearDown(source.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            captureConfigProvider.overrideWith(() => _StubConfig(config)),
            orientationSourceProvider.overrideWithValue(source.stream),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Stack(children: [TiltMeterOverlay(levelBandId: bandId)]),
            ),
          ),
        ),
      );
      await tester.pump();
      source.add(_atTilt(tilt));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }

    testWidgets('Top Ring (high [110,180)): 100 → tilt down (aim at the top)',
        (tester) async {
      await pumpTilt(tester, bandId: 'high', tilt: 100); // below 110
      expect(find.text('Tilt down'), findsOneWidget);
    });

    testWidgets('Top Ring (high [110,180)): 150 → ready', (tester) async {
      await pumpTilt(tester, bandId: 'high', tilt: 150); // inside [110,180)
      expect(find.text('Hold steady'), findsOneWidget);
    });

    testWidgets('Eye Ring (mid [40,110)): 130 → tilt up (aimed too far down)',
        (tester) async {
      await pumpTilt(tester, bandId: 'mid', tilt: 130); // above 110
      expect(find.text('Tilt up'), findsOneWidget);
    });

    testWidgets(
        '100° is in-band for Eye Ring but out for Top Ring (band drives it)',
        (tester) async {
      // Same tilt, different level band → different guidance. Proves the
      // indicator reads the LEVEL band, not a hardcoded one.
      await pumpTilt(tester, bandId: 'mid', tilt: 100);
      expect(find.text('Hold steady'), findsOneWidget,
          reason: '100° is inside the Eye Ring [40,110)');
    });

    testWidgets('generalizes to a custom server-style band [20,50): 70 → tilt up',
        (tester) async {
      const config = CaptureConfig(
        version: 1,
        pitchBands: [
          PitchBand(id: 'shelf', minDegrees: 20, maxDegrees: 50, segments: 8),
        ],
        thresholds: CaptureThresholds(
            minSharpness: 0.45, minCoveragePct: 80, maxTiltDeltaDeg: 12),
      );
      await pumpTilt(tester, bandId: 'shelf', tilt: 70, config: config);
      expect(find.text('Tilt up'), findsOneWidget); // above 50 → tilt up
    });

    testWidgets('generalizes to a custom server-style band [20,50): 35 → ready',
        (tester) async {
      const config = CaptureConfig(
        version: 1,
        pitchBands: [
          PitchBand(id: 'shelf', minDegrees: 20, maxDegrees: 50, segments: 8),
        ],
        thresholds: CaptureThresholds(
            minSharpness: 0.45, minCoveragePct: 80, maxTiltDeltaDeg: 12),
      );
      await pumpTilt(tester, bandId: 'shelf', tilt: 35, config: config);
      expect(find.text('Hold steady'), findsOneWidget); // inside [20,50)
    });

    testWidgets('out-of-band analytics carries the Top Ring band id',
        (tester) async {
      final events = <({String name, Map<String, Object?> props})>[];
      Analytics.testSink = (n, p) => events.add((name: n, props: p));
      addTearDown(() => Analytics.testSink = null);

      final source = StreamController<SmoothedOrientation>.broadcast();
      addTearDown(source.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            captureConfigProvider
                .overrideWith(() => _StubConfig(CaptureConfig.bundledDefault)),
            orientationSourceProvider.overrideWithValue(source.stream),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  TiltMeterOverlay(
                    levelBandId: 'high',
                    outSustain: Duration.zero,
                    outCooldown: Duration.zero,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      source.add(_atTilt(100)); // below the Top Ring band [110,180)
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final out =
          events.where((e) => e.name == AnalyticsEvents.tiltMeterOutOfBand);
      expect(out, isNotEmpty);
      expect(out.first.props['target_band_id'], 'high');
      expect(out.first.props['direction'], 'below');
    });
  });
}
