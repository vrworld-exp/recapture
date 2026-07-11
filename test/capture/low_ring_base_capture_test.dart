// test/capture/low_ring_base_capture_test.dart
//
// QA: "Level C captures the base of the object WITHOUT cutting it off."
// TESTS ONLY — no production code is touched.
//
// ── WHAT THIS PROVES, AND WHAT IT DELIBERATELY DOES NOT ────────────────────────
// Base-cutoff handling in this app is INSTRUCTIONAL + GEOMETRIC, not vision-based:
// there is NO object/base detector and NO frame-rejection that says "the base is
// cut off" (see docs/qa/low-ring-pitch-cutoff-qa.md and the
// project memory "Cutoff Gating NOT Wired"). So a hermetic Dart test cannot prove
// pixels. What it CAN — and here does — prove are the two mechanisms designed to
// MAKE base capture happen, with sabotage checks that give them teeth:
//
//   1. BAND ENFORCEMENT through the real auto-capture decision (`shouldCapture`):
//      capture fires only at the in-band Low-Ring angle (the slight-up posture that
//      keeps the base in frame) and does NOT fire at a horizontal / Level-A angle
//      (which would cut the base off) — all other capture conditions held equal, so
//      ONLY the pitch-vs-band relationship decides. This exercises the production
//      gate the live shutter + auto-capture loop use (auto_capture_trigger.dart),
//      not a re-implemented predicate.
//
//   2. GUIDANCE that is LEVEL-C-SPECIFIC: the base-cutoff framing reminder
//      ("Keep the whole base in frame — don't cut off the bottom") is part of the
//      Level C instruction cycle and is ABSENT from Level A and Level B — so the
//      base-capture coaching is shown for the Low Ring and only the Low Ring.
//
// The pixel-level "base actually in frame" guarantee is NOT automated here (no
// detector / no framing-geometry fixture exists in the repo). It is the documented
// MANUAL QA acceptance step in docs/qa/low-ring-pitch-cutoff-qa.md ("frame the
// object so the base is fully visible … confirm full base, not cut off"). This file
// keeps that split explicit and does not pretend the content check is automated.
//
// ── CONVENTION RECONCILIATION (same as the sibling Low-Ring tests) ─────────────
// The brief frames Low Ring as an "upward tilt / NEGATIVE band". This codebase does
// NOT use a negative band: Level C resolves to `pitchBandIdForLevel(CaptureLevel.c)
// == 'low'`, the [0, 60) slice — the lowest of the 0–180° camera-tilt scale, reached
// by a slight upward tilt from level (copy: "Lower the phone, tilt slightly up").
// The assertions encode that production convention; the sabotage group fails if the
// band is ever mis-wired to the horizontal (Level A) band.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/analytics/capture_level_events.dart';
import 'package:recapture/domain/capture/auto_capture_trigger.dart';
import 'package:recapture/domain/capture/pitch_band_resolution.dart';
import 'package:recapture/domain/entities/capture_config.dart';
// Imported from the dependency-light constants file (NOT capture_screen.dart) so
// this hermetic test compiles independently of the full capture-screen widget
// graph. capture_screen.dart re-exports these same constants, so this is the same
// copy the live HUD renders.
import 'package:recapture/presentation/screens/capture/capture_instructions.dart'
    show
        kLevelCCaptureInstructions,
        kLevelBCaptureInstructions,
        kDefaultCaptureInstructions;

void main() {
  const config = CaptureConfig.bundledDefault;

  // Resolved through the REAL production path (single level→band-id map + the band
  // resolver over the live config), NOT a hardcoded [0,30) duplicate — so these
  // tests track an INTENTIONAL retune and fail on an UNINTENTIONAL one.
  final lowRing = resolvePitchBand(
      bandId: pitchBandIdForLevel(CaptureLevel.c), config: config);
  // Level A's band (Eye Ring 'mid' [60,120)) is the "horizontal" posture that would
  // cut the base off — the wrong band for the Low Ring.
  final eyeRing = resolvePitchBand(
      bandId: pitchBandIdForLevel(CaptureLevel.a), config: config);

  // The base-capturing angle (well inside the Low Ring [0,60)) and a horizontal /
  // Level-A angle (inside [60,120), outside Low Ring) that clips the base.
  const baseAnglePitch = 30.0; // slight-up posture (low band centre) → base in frame
  const horizontalPitch = 90.0; // Eye-Ring/horizontal → base cut off
  const eps = 0.01;

  // The base-cutoff framing reminder copy — the Level-C-specific coaching under test.
  const baseFramingReminder =
      "Keep the whole base in frame — don't cut off the bottom";

  // Drive the REAL auto-capture decision with every gate satisfied EXCEPT pitch, so
  // a fire/no-fire difference is attributable ONLY to the pitch-vs-band relationship
  // (the geometric safeguard). No sensors, no camera, no timers — `now`/`lastCapture`
  // are plain values, deterministic and repeatable.
  bool fires(PitchBand band, double pitch) => shouldCapture(
        currentTilt: pitch,
        pitchBand: band,
        isStable: true,
        isCurrentFilled: false,
        lastCaptureAt: null,
        now: DateTime.utc(2026, 6, 27),
        isCapturing: false,
      );

  group('Level C identity — the base-capture band is the low positive slice', () {
    test('Level C resolves to the "low" band (single source of truth)', () {
      expect(pitchBandIdForLevel(CaptureLevel.c), 'low');
      expect(lowRing.id, 'low');
    });

    test('low band is the lower slice (sign-flip / region guard)', () {
      expect(isValidPitchBand(lowRing), isTrue);
      expect(lowRing.minDegrees, greaterThanOrEqualTo(0),
          reason: 'a flip to a negative band must fail here');
      final center = (lowRing.minDegrees + lowRing.maxDegrees) / 2;
      expect(center, lessThan(45),
          reason: 'Low Ring is the lower (base) slice, not the horizontal band');
    });
  });

  group('AUTOMATABLE 1 — auto-capture fires at the base angle, not horizontal', () {
    test('in-band base angle (slight-up posture) → capture FIRES', () {
      expect(fires(lowRing, baseAnglePitch), isTrue);
    });

    test('band centre (the ideal base posture) → capture FIRES', () {
      final center = (lowRing.minDegrees + lowRing.maxDegrees) / 2;
      expect(fires(lowRing, center), isTrue);
    });

    test('horizontal / Level-A angle (would cut off the base) → NO capture', () {
      // 90° is a valid Eye-Ring posture but OUT of the Low Ring band: the base
      // would be clipped, so the auto-capture decision must refuse to fire.
      expect(fires(lowRing, horizontalPitch), isFalse);
    });

    test('a downward mirror pose is also rejected (direction lock)', () {
      expect(fires(lowRing, -baseAnglePitch), isFalse);
    });

    test('band membership is the ONLY differentiator here (gate is necessary)', () {
      // Identical, fully-ready capture conditions; the sole change is the pitch.
      // The flip from fire→no-fire is therefore the band gate doing its job.
      expect(fires(lowRing, baseAnglePitch), isTrue);
      expect(fires(lowRing, horizontalPitch), isFalse);
    });
  });

  group('AUTOMATABLE 1 — band edges (inclusive min / exclusive max)', () {
    test('exactly min → in-band → FIRES (inclusive lower edge)', () {
      expect(fires(lowRing, lowRing.minDegrees), isTrue);
    });

    test('just below min → NO capture', () {
      expect(fires(lowRing, lowRing.minDegrees - eps), isFalse);
    });

    test('just below max → in-band → FIRES', () {
      expect(fires(lowRing, lowRing.maxDegrees - eps), isTrue);
    });

    test('exactly max → out-of-band → NO capture (exclusive upper edge)', () {
      expect(fires(lowRing, lowRing.maxDegrees), isFalse);
    });
  });

  group('AUTOMATABLE 1 — degenerate pitch never fires (no throw)', () {
    test('NaN / ±Infinity → NO capture', () {
      expect(fires(lowRing, double.nan), isFalse);
      expect(fires(lowRing, double.infinity), isFalse);
      expect(fires(lowRing, double.negativeInfinity), isFalse);
    });
  });

  group('SABOTAGE — mis-wiring Level C to the horizontal band flips the safeguard',
      () {
    // If Level C were ever wired to Level A's horizontal band, capture would fire at
    // the base-CUTTING angle and refuse at the base-SHOWING angle — the exact
    // failure this whole feature exists to prevent. Running the same flow against the
    // wrong band makes that inversion observable, proving the band choice (not luck)
    // is what gates base capture.
    test('with the WRONG (horizontal) band, the base angle would NOT fire', () {
      expect(fires(eyeRing, baseAnglePitch), isFalse,
          reason: 'the base posture is out of the horizontal band');
    });

    test('with the WRONG (horizontal) band, the base-cutting angle WOULD fire', () {
      expect(fires(eyeRing, horizontalPitch), isTrue,
          reason: 'horizontal capture (base clipped) is exactly what we must avoid');
    });

    test('the REAL Low Ring band gives the opposite (correct) outcome', () {
      // The two bands disagree on both angles — i.e. the safeguard has teeth: pick
      // the wrong band and base capture breaks.
      expect(fires(lowRing, baseAnglePitch), isTrue);
      expect(fires(lowRing, horizontalPitch), isFalse);
      expect(
        lowRing.minDegrees != eyeRing.minDegrees ||
            lowRing.maxDegrees != eyeRing.maxDegrees,
        isTrue,
        reason: 'Low Ring and Eye Ring must be distinct bands',
      );
    });
  });

  group('AUTOMATABLE 2 — base-cutoff guidance is shown for Level C only', () {
    test('Level C cycle INCLUDES the base-cutoff framing reminder', () {
      expect(kLevelCCaptureInstructions, contains(baseFramingReminder),
          reason: 'removing this reminder must fail the test (sabotage check)');
    });

    test('Level C lead cue is the base-capture cue', () {
      expect(kLevelCCaptureInstructions.first, 'Tilt up to show the base');
    });

    test('Level A (default) does NOT show the base-cutoff reminder or cue', () {
      expect(kDefaultCaptureInstructions, isNot(contains(baseFramingReminder)));
      expect(kDefaultCaptureInstructions,
          isNot(contains('Tilt up to show the base')));
    });

    test('Level B does NOT show the base-cutoff reminder or cue', () {
      expect(kLevelBCaptureInstructions, isNot(contains(baseFramingReminder)));
      expect(kLevelBCaptureInstructions,
          isNot(contains('Tilt up to show the base')));
    });

    test('the base reminder is UNIQUE to Level C across the three cycles', () {
      final inA = kDefaultCaptureInstructions.contains(baseFramingReminder);
      final inB = kLevelBCaptureInstructions.contains(baseFramingReminder);
      final inC = kLevelCCaptureInstructions.contains(baseFramingReminder);
      expect([inA, inB, inC], [false, false, true]);
    });
  });

  group('EDGE — remote-config retune of the Low Ring band still gates to in-band',
      () {
    // A retuned `low` band (here a runtime override, the highest-precedence source)
    // must keep the SAME safeguard: capture follows the new in-band window and still
    // refuses the now-out-of-band angle. The mechanism adapts; it does not lapse.
    final retuned = resolvePitchBand(
      bandId: 'low',
      config: config,
      overrides: const {
        'low': PitchBand(id: 'low', minDegrees: 0, maxDegrees: 20, segments: 12),
      },
    );

    test('band adapts to the override window', () {
      expect(retuned.maxDegrees, 20);
    });

    test('fires inside the retuned window, refuses outside it', () {
      expect(fires(retuned, 10), isTrue); // inside [0,20)
      expect(fires(retuned, 25), isFalse); // was in the full low band, now out → refused
    });
  });

  // ── MANUAL / FIXTURE CONTENT CHECK (NOT automated here) ──────────────────────
  // The pixel-level "base is fully in frame, not cut off" guarantee has no detector
  // or framing-geometry fixture in this repo, so it cannot be asserted hermetically.
  // It is the documented manual QA acceptance step:
  //   docs/qa/low-ring-pitch-cutoff-qa.md → "Manual QA checklist (physical device
  //   only)" → perform a real Low Ring capture of a representative object on a
  //   surface and confirm the captured photos show the FULL base (not clipped, not
  //   occluded by the supporting surface).
  // If/when an object-base detector + capture-time framing gate land, extend
  // AUTOMATABLE 1 to AND `CapturePitchGuide.isInBand` with the base-in-frame
  // predicate and add a `reason: cutoff` rejection-event assertion (see the sibling
  // low_ring_cutoff_rejection_test.dart, which pins the geometry primitive today).
  test('MANUAL acceptance step is documented (placeholder marker, always passes)',
      () {
    // Intentionally trivial: this test exists to make the manual/automated split
    // visible in the suite output and to anchor the doc reference above. It asserts
    // nothing about pixels — that is the device-only check.
    expect(true, isTrue);
  });
}
