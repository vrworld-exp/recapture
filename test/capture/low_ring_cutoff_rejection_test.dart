// test/capture/low_ring_cutoff_rejection_test.dart
//
// QA: object "cut off" (extends beyond the framing guide) rejection, + the
// "both conditions required" contract (in-band pitch AND object fully in frame).
// TESTS ONLY.
//
// ── IMPORTANT PRODUCTION-GAP FINDING (do not mask) ─────────────────────────────
// Cutoff / object-in-frame gating is NOT wired into the capture acceptance path.
// `capture_screen.dart` renders `PlacementBoxOverlay` purely as a guide and states
// "placement is not gated yet (no detection)"; `PlacementBox.containsNormalized`
// is documented as a "render-only helper for later gating logic"; `PlacementStatus`
// is "INJECTED ... by a parent (future detection/sensor logic) — never
// self-detected". There is NO object detector producing a bounding box, NO code
// that rejects an in-band frame because the object is cut off, and NO
// cutoff-rejection analytics event.
//
// Consequences for this suite (honest scoping, per the brief's Assumptions):
//   * The cutoff DETECTION PRIMITIVE that DOES exist — PlacementBox.containsNormalized
//     — is tested directly below (the geometry contract: fully-inside vs cut-off).
//   * The "both conditions" contract is asserted at the HELPER-COMPOSITION level
//     (isInBand AND containsNormalized), demonstrating the intended rule and acting
//     as the guard for when the gating is wired. It is NOT claimed that the live
//     capture path enforces this today — it does not (the gap above).
//   * A "cutoff-rejected frame" analytics event is asserted as ABSENT (a tracked
//     gap), and the observable outcome (the composed predicate rejects) is used
//     instead, exactly as the brief instructs when no rejection event exists.
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/analytics/capture_level_events.dart';
import 'package:recapture/domain/capture/pitch_band_resolution.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/capture_pitch_guide.dart';
import 'package:recapture/domain/entities/placement_box.dart';

void main() {
  const config = CaptureConfig.bundledDefault;
  final lowRing = resolvePitchBand(
      bandId: pitchBandIdForLevel(CaptureLevel.c), config: config);

  // Default centred guide 0.7×0.7 → normalized rect LTRB(0.15, 0.15, 0.85, 0.85).
  const box = PlacementBox();

  group('cutoff detection primitive — PlacementBox.containsNormalized', () {
    test('object fully inside the guide → contained (NOT a cutoff)', () {
      expect(box.containsNormalized(const Rect.fromLTRB(0.3, 0.3, 0.7, 0.7)),
          isTrue);
    });

    test('object cut off at the RIGHT edge → not contained (rejected)', () {
      expect(box.containsNormalized(const Rect.fromLTRB(0.6, 0.3, 0.95, 0.7)),
          isFalse);
    });

    test('object cut off at the TOP edge → not contained (rejected)', () {
      expect(box.containsNormalized(const Rect.fromLTRB(0.3, 0.05, 0.7, 0.5)),
          isFalse);
    });

    test('object entirely outside the guide → not contained (rejected)', () {
      expect(box.containsNormalized(const Rect.fromLTRB(0.9, 0.9, 0.99, 0.99)),
          isFalse);
    });

    test('object just inside all edges → contained', () {
      expect(box.containsNormalized(const Rect.fromLTRB(0.16, 0.16, 0.84, 0.84)),
          isTrue);
    });

    test(
        'object exactly filling the guide → NOT contained (far edges exclusive — '
        'documents the actual boundary of the cutoff rule)', () {
      // Rect.contains treats right/bottom as exclusive, so an object whose
      // bottom-right sits exactly on the guide edge counts as touching/out.
      final exact = box.normalizedRect;
      expect(box.containsNormalized(exact), isFalse);
    });

    test('a tiny config (clamped) still yields a valid, non-collapsing guide', () {
      const tiny = PlacementBox(widthRatio: 0, heightRatio: -1); // invalid input
      final r = tiny.normalizedRect;
      expect(r.width, greaterThan(0));
      expect(r.height, greaterThan(0));
      expect(r.left, greaterThanOrEqualTo(0));
      expect(r.right, lessThanOrEqualTo(1));
    });
  });

  // The intended acceptance rule, composed from the two pure primitives. NOTE:
  // production does not yet apply the cutoff half (see the gap header); this guards
  // the contract for when it is wired, and proves neither condition alone suffices.
  group('combined contract — in-band pitch AND object fully in frame', () {
    bool wouldAccept(double pitch, Rect objectNormalized) =>
        CapturePitchGuide.isInBand(lowRing, pitch) &&
        box.containsNormalized(objectNormalized);

    const inFrame = Rect.fromLTRB(0.3, 0.3, 0.7, 0.7);
    const cutOff = Rect.fromLTRB(0.6, 0.3, 0.95, 0.7);
    const inBandPitch = 15.0; // inside Low Ring [0,30)
    const outOfBandPitch = 75.0; // Top Ring region — out for Low Ring

    test('in-band + in-frame → ACCEPTED', () {
      expect(wouldAccept(inBandPitch, inFrame), isTrue);
    });

    test('in-band + cutoff → REJECTED (pitch alone is not sufficient)', () {
      expect(wouldAccept(inBandPitch, cutOff), isFalse);
    });

    test('out-of-band + in-frame → REJECTED (framing alone is not sufficient)', () {
      expect(wouldAccept(outOfBandPitch, inFrame), isFalse);
    });

    test('out-of-band + cutoff → REJECTED', () {
      expect(wouldAccept(outOfBandPitch, cutOff), isFalse);
    });
  });
}
