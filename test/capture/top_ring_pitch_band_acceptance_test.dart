// test/capture/top_ring_pitch_band_acceptance_test.dart
//
// QA: the Top Ring pitch band is TUNED CORRECTLY so the intended capture pose is
// accepted and others are rejected. This is the band-MEMBERSHIP/acceptance guard
// (the production gate is `CapturePitchGuide.isInBand` against the level's resolved
// band) — distinct from top_ring_pitch_band_test.dart, which covers the tilt
// indicator/gauge wiring.
//
// TESTS ONLY — no production code is touched. If the Top Ring band is ever
// mis-tuned (flipped sign, recentered on level, or an edge moved), the relevant
// assertion here FAILS and surfaces it; this file does NOT "fix" the band.
//
// CONFIRMED SIGN CONVENTION (read from the source of truth, NOT the brief's
// external "down = negative" mental model): in this codebase the Top Ring is the
// HIGH POSITIVE band. `pitchBandIdForLevel(CaptureLevel.b) == 'high'`, and the
// bundled `high` band is [60, 90) — the upper slice of the [0, 90] capture range
// the bands tile. So the "above the subject" Top Ring pass is encoded as a high
// positive pitch band, reached by raising pitch toward 60–90 (the indicator's
// "Tilt up" guidance). The acceptance assertions below are written so that
// flipping this to a negative band, or recentering it on level (0°), fails.
//
// Band membership contract (capture_pitch_guide.dart): minDegrees INCLUSIVE,
// maxDegrees EXCLUSIVE; NaN/Infinity → false (no throw).
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/analytics/capture_level_events.dart';
import 'package:recapture/domain/capture/pitch_band_resolution.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/capture_pitch_guide.dart';

void main() {
  // The Top Ring band, resolved through the REAL production path: the single
  // level→band-id map + the band resolver over the live config. Reading from the
  // source of truth (not a hardcoded [60,90) duplicate) means the boundary tests
  // track an INTENTIONAL config change and fail on an UNINTENTIONAL one.
  const config = CaptureConfig.bundledDefault;
  final topRingBandId = pitchBandIdForLevel(CaptureLevel.b);
  final topRing = resolvePitchBand(bandId: topRingBandId, config: config);

  // The lower ring (Level C) band, for the ring-specific (not-one-global-band)
  // assertions.
  final lowerRingBandId = pitchBandIdForLevel(CaptureLevel.c);
  final lowerRing = resolvePitchBand(bandId: lowerRingBandId, config: config);

  // Unambiguous boundary nudge — small enough to sit strictly on one side of an
  // edge, large enough to be exact in IEEE-754 at these magnitudes.
  const eps = 0.01;

  bool accepted(double pitch) => CapturePitchGuide.isInBand(topRing, pitch);

  group('Top Ring band — identity + tuning is the high positive band', () {
    test('Level B resolves to the "high" band (single level→band source)', () {
      expect(topRingBandId, 'high');
      expect(topRing.id, 'high');
    });

    test('band is a valid, non-empty positive slice (sign-flip/recenter guard)', () {
      expect(isValidPitchBand(topRing), isTrue);
      expect(topRing.minDegrees, greaterThanOrEqualTo(0),
          reason: 'a flip to a negative band must fail here');
      expect(topRing.maxDegrees, greaterThan(topRing.minDegrees));
      // The accepted orientation is the UPPER part of the [0,90] capture range —
      // not level and not the low ring. Recentering on 0° would drop this.
      final center = (topRing.minDegrees + topRing.maxDegrees) / 2;
      expect(center, greaterThan(45),
          reason: 'Top Ring must center on the high (upward-pitch) orientation');
    });
  });

  group('Top Ring band — tuning tripwire (catches any edge drift)', () {
    // Intentional, explicit pin of the CURRENT tuning. Unlike the source-derived
    // boundary tests below (which verify inclusive/exclusive SEMANTICS and follow
    // a deliberate retune), this asserts the exact edges so an UNINTENDED nudge —
    // even by 1° — fails here. A deliberate retune updates these two numbers on
    // purpose; that conscious edit is the point of the tripwire.
    test('high band is exactly [60, 90)', () {
      expect(topRing.minDegrees, 60);
      expect(topRing.maxDegrees, 90);
    });
  });

  group('Top Ring band — downward-tilt pose is accepted', () {
    test('nominal center pitch is accepted', () {
      final center = (topRing.minDegrees + topRing.maxDegrees) / 2;
      expect(accepted(center), isTrue);
    });

    test('a fixed representative Top-Ring pitch (75°) is accepted', () {
      // Hardcoded on purpose: this is the sign/region anchor. If the band is
      // flipped negative or recentered on level, 75° stops being accepted and
      // THIS fails — independent of the (then-moved) derived edges.
      expect(accepted(75), isTrue);
    });
  });

  group('Top Ring band — edge boundaries (inclusive min / exclusive max)', () {
    test('lower edge: exactly min is INSIDE (inclusive) → accepted', () {
      expect(accepted(topRing.minDegrees), isTrue);
    });

    test('lower edge: just below min → rejected', () {
      expect(accepted(topRing.minDegrees - eps), isFalse);
    });

    test('upper edge: just below max is INSIDE → accepted', () {
      expect(accepted(topRing.maxDegrees - eps), isTrue);
    });

    test('upper edge: exactly max is OUTSIDE (exclusive) → rejected', () {
      expect(accepted(topRing.maxDegrees), isFalse);
    });
  });

  group('Top Ring band — out-of-band poses are rejected (sign guard)', () {
    test('level pose (0°) is rejected for the Top Ring', () {
      expect(accepted(0), isFalse);
    });

    test('upward/opposite-sign pose (mirror of the band) is rejected', () {
      // The mirror of the nominal center across 0°. With the band on the high
      // positive side this is clearly out; if someone flips the band's sign, the
      // mirror would become accepted and this fails (paired with the 75° accept).
      final center = (topRing.minDegrees + topRing.maxDegrees) / 2;
      expect(accepted(-center), isFalse);
      expect(accepted(-75), isFalse);
    });

    test('a pitch well below the band (Eye/level region) is rejected', () {
      expect(accepted(topRing.minDegrees - 30), isFalse);
    });
  });

  group('Top Ring band — degenerate inputs do not throw', () {
    test('NaN → not accepted, no throw', () {
      expect(accepted(double.nan), isFalse);
    });

    test('±Infinity → not accepted, no throw', () {
      expect(accepted(double.infinity), isFalse);
      expect(accepted(double.negativeInfinity), isFalse);
    });

    test('out-of-range magnitudes (beyond ±90/±180) → not accepted, no throw', () {
      expect(accepted(999), isFalse);
      expect(accepted(-999), isFalse);
      expect(accepted(180), isFalse);
    });

    // NOTE: the production seam (CapturePitchGuide.isInBand) takes a non-nullable
    // double — a broken sensor read surfaces as NaN (covered above), never a Dart
    // null — so there is no null case to assert at this layer.
  });

  group('Top Ring band is ring-specific (not one collapsed global band)', () {
    test('the Top Ring and lower (Level C) bands differ', () {
      expect(lowerRingBandId, 'low');
      expect(
        topRing.minDegrees != lowerRing.minDegrees ||
            topRing.maxDegrees != lowerRing.maxDegrees,
        isTrue,
        reason: 'Top Ring and lower ring must not share one band',
      );
    });

    test('the same downward-tilt pose accepted by Top Ring is NOT a lower-ring pose',
        () {
      const topPose = 75.0;
      expect(CapturePitchGuide.isInBand(topRing, topPose), isTrue);
      expect(CapturePitchGuide.isInBand(lowerRing, topPose), isFalse);
    });

    test('a lower-ring pose is rejected by the Top Ring', () {
      final lowerCenter = (lowerRing.minDegrees + lowerRing.maxDegrees) / 2;
      expect(CapturePitchGuide.isInBand(lowerRing, lowerCenter), isTrue);
      expect(accepted(lowerCenter), isFalse);
    });
  });
}
