// test/capture/top_ring_pitch_band_test.dart
//
// Top Ring (+ generalized) pitch-band enforcement + tuned tilt indicator.
//
// Covers the wiring this feature adds on top of the already-parameterized gate
// (shouldCapture/isPitchInBand) and indicator (TiltMeterOverlay):
//   1. pitchBandIdForLevel — the SINGLE level→band-id source (A=mid, B=high=Top
//      Ring, C=low=Bottom Ring); the degrees live in config, not here.
//   2. tiltGaugeRangeForBand — the gauge auto-tunes/adapts to ANY band (Top Ring,
//      Eye Ring, a negative Bottom Ring), framing it with head/foot room.
//   3. TiltMeterOverlay(levelBandId:) — the indicator's below/in/above guidance
//      tracks the LEVEL's band, not a hardcoded one (tuned for Top Ring [60,90),
//      and a negative band proves the generalization).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/analytics/capture_level_events.dart';
import 'package:recapture/application/capture/current_pitch_provider.dart';
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

SmoothedOrientation _at(double deg) {
  final rad = deg * math.pi / 180.0;
  return SmoothedOrientation(
    yaw: 0, pitch: rad, roll: 0, qx: 0, qy: 0, qz: 0, qw: 1, timestampNs: 0,
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

    test('Top Ring [60,90) frames to [30,120] (one span head/foot room)', () {
      final r = tiltGaugeRangeForBand(band(60, 90));
      expect(r.min, 30);
      expect(r.max, 120);
    });

    test('Eye Ring [30,60) frames to [0,90]', () {
      final r = tiltGaugeRangeForBand(band(30, 60));
      expect(r.min, 0);
      expect(r.max, 90);
    });

    test('a negative Bottom-Ring-style band [-60,-30) frames to [-90,0]', () {
      final r = tiltGaugeRangeForBand(band(-60, -30));
      expect(r.min, -90);
      expect(r.max, 0);
    });

    test('a very narrow band still gets the minMargin floor', () {
      final r = tiltGaugeRangeForBand(band(50, 54), minMargin: 15);
      expect(r.min, 35); // 50 - 15
      expect(r.max, 69); // 54 + 15
      expect(r.max - r.min, greaterThan(4));
    });
  });

  group('TiltMeterOverlay tunes its guidance to the level band', () {
    // Pumps a FRESH overlay and feeds a single pitch sample. A fresh mount seeds
    // the pitch EMA directly to that value (no smoothing lag), so the asserted
    // state is exactly the one [pitch] maps to under the band.
    Future<void> pumpPitch(
      WidgetTester tester, {
      required String bandId,
      required double pitch,
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
      source.add(_at(pitch));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }

    testWidgets('Top Ring (high [60,90)): 50 → tilt up', (tester) async {
      await pumpPitch(tester, bandId: 'high', pitch: 50); // below 60
      expect(find.text('Tilt up'), findsOneWidget);
    });

    testWidgets('Top Ring (high [60,90)): 75 → ready', (tester) async {
      await pumpPitch(tester, bandId: 'high', pitch: 75); // inside [60,90)
      expect(find.text('Hold steady'), findsOneWidget);
    });

    testWidgets('Top Ring (high [60,90)): 95 → tilt down', (tester) async {
      await pumpPitch(tester, bandId: 'high', pitch: 95); // above 90
      expect(find.text('Tilt down'), findsOneWidget);
    });

    testWidgets('50° is in-band for Eye Ring but out for Top Ring (band drives it)',
        (tester) async {
      // Same pitch, different level band → different guidance. Proves the
      // indicator reads the LEVEL band, not a hardcoded one.
      await pumpPitch(tester, bandId: 'mid', pitch: 50);
      expect(find.text('Hold steady'), findsOneWidget,
          reason: '50° is inside the Eye Ring [30,60)');
    });

    testWidgets('generalizes to a negative Bottom-Ring band [-60,-30): -10 → tilt down',
        (tester) async {
      const config = CaptureConfig(
        version: 1,
        pitchBands: [
          PitchBand(id: 'bottom', minDegrees: -60, maxDegrees: -30, segments: 8),
        ],
        thresholds: CaptureThresholds(
          minSharpness: 0.45, minCoveragePct: 80, maxTiltDeltaDeg: 12),
      );
      await pumpPitch(tester, bandId: 'bottom', pitch: -10, config: config);
      expect(find.text('Tilt down'), findsOneWidget); // above -30 → tilt down
    });

    testWidgets('generalizes to a negative Bottom-Ring band [-60,-30): -45 → ready',
        (tester) async {
      const config = CaptureConfig(
        version: 1,
        pitchBands: [
          PitchBand(id: 'bottom', minDegrees: -60, maxDegrees: -30, segments: 8),
        ],
        thresholds: CaptureThresholds(
          minSharpness: 0.45, minCoveragePct: 80, maxTiltDeltaDeg: 12),
      );
      await pumpPitch(tester, bandId: 'bottom', pitch: -45, config: config);
      expect(find.text('Hold steady'), findsOneWidget); // inside [-60,-30)
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
            captureConfigProvider.overrideWith(() => _StubConfig(CaptureConfig.bundledDefault)),
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

      source.add(_at(40)); // below the Top Ring band
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
