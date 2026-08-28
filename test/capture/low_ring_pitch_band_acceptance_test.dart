// test/capture/low_ring_pitch_band_acceptance_test.dart
//
// QA: Level C "Low Ring" PITCH-BAND gating is tuned correctly + emits the right
// guidance analytics. The production gate is `CapturePitchGuide.isInBand` against
// the level's resolved band (wired into the shutter + auto-capture); the tilt
// indicator emits the debounced out-of-band guidance event. TESTS ONLY — no
// production code is touched; a mis-tune surfaces as a failure here.
//
// ── CONVENTION RECONCILIATION (read this) ──────────────────────────────────────
// The brief frames Low Ring as an "upward tilt" pass and references a negative
// band (−30…−10). This codebase does NOT use a negative band: Level C resolves to
// `pitchBandIdForLevel(CaptureLevel.c) == 'low'`, and the bundled `low` band is
// [0, 40) on the 0–180° CAMERA-TILT scale (0 = camera at the sky, 90 = horizon,
// 180 = at the ground) — the lowest slice, reached by tilting the phone UP. The
// Level C product copy is "Lower the phone, tilt slightly up". These tests encode
// that production convention and the direction-lock below fails if the band is
// ever inverted to negative — the intended guardrail.
//
// Band membership contract (capture_pitch_guide.dart): minDegrees INCLUSIVE,
// maxDegrees EXCLUSIVE; NaN/Infinity → false (no throw). The brief's "inclusive
// both edges" assumption is asserted against ACTUAL behaviour (lower inclusive,
// upper exclusive), not imposed.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/analytics/capture_level_events.dart';
import 'package:recapture/application/capture/current_tilt_provider.dart';
import 'package:recapture/application/config/config_notifier.dart';
import 'package:recapture/domain/capture/pitch_band_resolution.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/capture_pitch_guide.dart';
import 'package:recapture/platform/imu_rotation_channel.dart';
import 'package:recapture/presentation/widgets/tilt_meter_overlay.dart';
import 'package:recapture/utils/analytics.dart';

class _StubConfig extends ConfigNotifier {
  _StubConfig(this._config);
  final CaptureConfig _config;
  @override
  CaptureConfig build() => _config;
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
  // The Low Ring band, resolved through the REAL production path: the single
  // level→band-id map + the band resolver over the live config. Reading from the
  // source of truth (not a hardcoded [0,40) duplicate) means the boundary tests
  // track an INTENTIONAL retune and fail on an UNINTENTIONAL one.
  const config = CaptureConfig.bundledDefault;
  final lowRingBandId = pitchBandIdForLevel(CaptureLevel.c);
  final lowRing = resolvePitchBand(bandId: lowRingBandId, config: config);

  // The Top Ring band, for ring-specific (not-one-global-band) assertions.
  final topRing = resolvePitchBand(
      bandId: pitchBandIdForLevel(CaptureLevel.b), config: config);

  const eps = 0.01;
  bool accepted(double pitch) => CapturePitchGuide.isInBand(lowRing, pitch);

  group('Low Ring band — identity + tuning is the low positive band', () {
    test('Level C resolves to the "low" band (single level→band source)', () {
      expect(lowRingBandId, 'low');
      expect(lowRing.id, 'low');
    });

    test('tuning tripwire: low band is exactly [0, 40)', () {
      // Explicit pin of the CURRENT tuning: an UNINTENDED edge nudge (even 1°)
      // fails here. A deliberate retune updates these two numbers on purpose.
      // Retuned 2026-07-21 from [0, 60) — `low` is now the NARROWEST band (40°).
      expect(lowRing.minDegrees, 0);
      expect(lowRing.maxDegrees, 40);
    });

    test('boundary: 39.999 is in `low`, 40.0 is not (exactly one band each)',
        () {
      expect(accepted(39.999), isTrue);
      expect(accepted(40.0), isFalse);
      expect(CapturePitchGuide.activeBand(config, 39.999)?.id, 'low');
      expect(CapturePitchGuide.activeBand(config, 40.0)?.id, 'mid');
    });

    test('band is a valid positive slice in the LOWER region (sign-flip guard)', () {
      expect(isValidPitchBand(lowRing), isTrue);
      expect(lowRing.minDegrees, greaterThanOrEqualTo(0),
          reason: 'a flip to a negative band must fail here');
      final center = (lowRing.minDegrees + lowRing.maxDegrees) / 2;
      expect(center, lessThan(90),
          reason: 'Low Ring is the lower slice, not the high/Top Ring band');
    });
  });

  group('Low Ring band — correct (slight-up) posture is accepted', () {
    test('nominal center pitch is accepted', () {
      final center = (lowRing.minDegrees + lowRing.maxDegrees) / 2;
      expect(accepted(center), isTrue);
    });

    test('a fixed representative Low-Ring tilt (30°) is accepted', () {
      // Hardcoded on purpose: the sign/region anchor. If the band is inverted to
      // negative or pushed up, 30° stops being accepted and THIS fails —
      // independent of the (then-moved) derived edges.
      expect(accepted(30), isTrue);
    });
  });

  group('Low Ring band — edge boundaries (inclusive min / exclusive max)', () {
    test('lower edge: exactly min is INSIDE (inclusive) → accepted', () {
      expect(accepted(lowRing.minDegrees), isTrue);
    });

    test('lower edge: just below min → rejected', () {
      expect(accepted(lowRing.minDegrees - eps), isFalse);
    });

    test('upper edge: just below max is INSIDE → accepted', () {
      expect(accepted(lowRing.maxDegrees - eps), isTrue);
    });

    test('upper edge: exactly max is OUTSIDE (exclusive) → rejected', () {
      expect(accepted(lowRing.maxDegrees), isFalse);
    });
  });

  group('Low Ring band — wrong posture is rejected (direction lock)', () {
    test('a downward/negative pose (mirror of the band) is rejected', () {
      // The mirror across 0°. With the band on the positive side this is out; if
      // someone flips the band sign to negative, the mirror becomes accepted and
      // this fails (paired with the 15° accept) — the upward-tilt direction lock.
      final center = (lowRing.minDegrees + lowRing.maxDegrees) / 2;
      expect(accepted(-center), isFalse);
      expect(accepted(-30), isFalse);
    });

    test('a high-tilt (Top Ring) pose is rejected for the Low Ring', () {
      expect(accepted(150), isFalse);
    });

    test('a pitch just above the band region is rejected', () {
      expect(accepted(lowRing.maxDegrees + 20), isFalse);
    });
  });

  group('Low Ring band — degenerate inputs do not throw', () {
    test('NaN → not accepted, no throw', () {
      expect(accepted(double.nan), isFalse);
    });

    test('±Infinity → not accepted, no throw', () {
      expect(accepted(double.infinity), isFalse);
      expect(accepted(double.negativeInfinity), isFalse);
    });

    test('out-of-range magnitudes (beyond the 0–180 scale) → not accepted, '
        'no throw', () {
      expect(accepted(999), isFalse);
      expect(accepted(-999), isFalse);
      expect(accepted(180), isFalse);
    });
  });

  group('Low Ring band is ring-specific (not one collapsed global band)', () {
    test('the Low Ring and Top Ring bands differ', () {
      expect(
        lowRing.minDegrees != topRing.minDegrees ||
            lowRing.maxDegrees != topRing.maxDegrees,
        isTrue,
      );
    });

    test('a Low-Ring pose is NOT a Top-Ring pose and vice-versa', () {
      expect(CapturePitchGuide.isInBand(lowRing, 30), isTrue);
      expect(CapturePitchGuide.isInBand(topRing, 30), isFalse);
      expect(CapturePitchGuide.isInBand(topRing, 150), isTrue);
      expect(accepted(150), isFalse);
    });
  });

  // ── Guidance analytics (the real, wired event) ───────────────────────────────
  // The brief's `guided_capture_pitch_out_of_band` does not exist; the production
  // out-of-band guidance event is `tilt_meter_out_of_band`, emitted by the tilt
  // indicator, DEBOUNCED by outSustain + outCooldown, carrying direction +
  // target_band_id (+ level/pitch from the active session). Driven here through a
  // fake orientation stream — no real sensor.
  group('out-of-band guidance analytics (tilt_meter_out_of_band, Low Ring)', () {
    Future<void> pumpOverlay(
      WidgetTester tester, {
      required Duration outCooldown,
      required List<double> pitches,
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
              body: Stack(
                children: [
                  TiltMeterOverlay(
                    levelBandId: 'low',
                    level: 'C',
                    outSustain: Duration.zero,
                    outCooldown: outCooldown,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      for (final p in pitches) {
        source.add(_at(p));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    testWidgets('emits once with level=C, the low band id, and a direction',
        (tester) async {
      final events = <({String name, Map<String, Object?> props})>[];
      Analytics.testSink = (n, p) => events.add((name: n, props: p));
      addTearDown(() => Analytics.testSink = null);

      // 90° is above the Low Ring [0,40) → sustained out-of-band → one emission.
      await pumpOverlay(tester,
          outCooldown: const Duration(seconds: 3), pitches: [90]);

      final out =
          events.where((e) => e.name == AnalyticsEvents.tiltMeterOutOfBand);
      expect(out, hasLength(1));
      expect(out.first.props['target_band_id'], 'low');
      expect(out.first.props['level'], 'C');
      expect(out.first.props['direction'], 'above'); // above [0,40)
      expect(out.first.props['pitch'], closeTo(90.0, 0.001));
    });

    testWidgets('is DEBOUNCED — oscillation near the edge does not emit per tick',
        (tester) async {
      final events = <({String name, Map<String, Object?> props})>[];
      Analytics.testSink = (n, p) => events.add((name: n, props: p));
      addTearDown(() => Analytics.testSink = null);

      // Several out-of-band samples within the cooldown window → ONE event only.
      await pumpOverlay(
        tester,
        outCooldown: const Duration(seconds: 3),
        pitches: [90, 91, 92, 90, 93],
      );

      final out =
          events.where((e) => e.name == AnalyticsEvents.tiltMeterOutOfBand);
      expect(out, hasLength(1), reason: 'cooldown debounces repeats');
    });

    testWidgets('an in-band (slight-up) pose emits NO out-of-band event',
        (tester) async {
      final events = <({String name, Map<String, Object?> props})>[];
      Analytics.testSink = (n, p) => events.add((name: n, props: p));
      addTearDown(() => Analytics.testSink = null);

      // 30° is inside [0,40) → in-band → no guidance event.
      await pumpOverlay(tester,
          outCooldown: Duration.zero, pitches: [30, 30, 30]);

      expect(
        events.where((e) => e.name == AnalyticsEvents.tiltMeterOutOfBand),
        isEmpty,
      );
    });
  });
}
