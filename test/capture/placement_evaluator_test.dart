// test/capture/placement_evaluator_test.dart
//
// Unit-tests the pure placement decision: rule priority (idle > tooClose >
// tooFar > offCenter > good), the relative-distance fill thresholds, per-axis
// centering tolerance, good-state hysteresis (strict entry, forgiving hold),
// and tolerance sanitization. Pure Dart — no widgets, no channels.
import 'dart:ui' show Offset, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/capture/placement_evaluator.dart';
import 'package:recapture/domain/entities/placement_box.dart';

/// A centred object rect covering [fill] fraction of the DEFAULT guide's area
/// (guide = 0.7x0.7 centred → area 0.49), optionally offset from centre.
Rect _centredObject({double fill = 0.5, double dx = 0, double dy = 0}) {
  const guideW = 0.7, guideH = 0.7;
  // Square-ish object with area = fill * guideArea, keeping the guide's aspect.
  final w = guideW * _sqrt(fill);
  final h = guideH * _sqrt(fill);
  return Rect.fromCenter(center: Offset(0.5 + dx, 0.5 + dy), width: w, height: h);
}

double _sqrt(double v) {
  // Newton's method — avoids importing dart:math for one call site.
  if (v <= 0) return 0;
  var x = v;
  for (var i = 0; i < 24; i++) {
    x = (x + v / x) / 2;
  }
  return x;
}

PlacementStatus _eval(
  Rect? object, {
  double confidence = 1,
  PlacementStatus previous = PlacementStatus.idle,
  PlacementTolerances tolerances = const PlacementTolerances(),
}) =>
    evaluatePlacement(
      PlacementDetection(objectNormalized: object, confidence: confidence),
      previous: previous,
      tolerances: tolerances,
    );

void main() {
  group('idle (no usable detection)', () {
    test('null object → idle', () {
      expect(_eval(null), PlacementStatus.idle);
      expect(evaluatePlacement(PlacementDetection.none), PlacementStatus.idle);
    });

    test('low confidence → idle, never a warning', () {
      expect(_eval(_centredObject(), confidence: 0.1), PlacementStatus.idle);
    });

    test('NaN confidence → idle', () {
      expect(
        _eval(_centredObject(), confidence: double.nan),
        PlacementStatus.idle,
      );
    });

    test('degenerate boxes (zero-area, NaN, inverted) → idle', () {
      expect(_eval(Rect.zero), PlacementStatus.idle);
      expect(
        _eval(const Rect.fromLTRB(0.2, 0.2, double.nan, 0.8)),
        PlacementStatus.idle,
      );
      expect(
        _eval(const Rect.fromLTRB(0.8, 0.8, 0.2, 0.2)), // inverted
        PlacementStatus.idle,
      );
    });
  });

  group('distance (relative fill ratio)', () {
    test('centred object at comfortable fill → good', () {
      expect(_eval(_centredObject(fill: 0.5)), PlacementStatus.good);
    });

    test('object dominating the guide → tooClose', () {
      expect(_eval(_centredObject(fill: 0.95)), PlacementStatus.tooClose);
    });

    test('object larger than the guide (fill > 1) → tooClose', () {
      expect(
        _eval(const Rect.fromLTRB(0.05, 0.05, 0.95, 0.95)),
        PlacementStatus.tooClose,
      );
    });

    test('tiny distant object → tooFar', () {
      expect(_eval(_centredObject(fill: 0.05)), PlacementStatus.tooFar);
    });

    test('distance outranks centering: tiny AND off-centre → tooFar first', () {
      expect(
        _eval(_centredObject(fill: 0.05, dx: 0.2)),
        PlacementStatus.tooFar,
      );
    });

    test('boundary: fill just above minFillRatio is not tooFar', () {
      // 0.21 sits above the 0.20 floor even after the helper's sqrt→square
      // float round-trip (exactly 0.20 would be float-luck, not a contract).
      expect(_eval(_centredObject(fill: 0.21)), PlacementStatus.good);
      expect(_eval(_centredObject(fill: 0.19)), PlacementStatus.tooFar);
    });
  });

  group('centering', () {
    test('good fill but pushed right beyond tolerance → offCenter', () {
      // Guide half-width 0.35, tolerance 35% → 0.1225 allowed; 0.2 exceeds it.
      expect(
        _eval(_centredObject(fill: 0.5, dx: 0.2)),
        PlacementStatus.offCenter,
      );
    });

    test('vertical offset alone also trips offCenter (per-axis check)', () {
      expect(
        _eval(_centredObject(fill: 0.5, dy: 0.2)),
        PlacementStatus.offCenter,
      );
    });

    test('small offset within tolerance stays good', () {
      expect(
        _eval(_centredObject(fill: 0.5, dx: 0.1)),
        PlacementStatus.good,
      );
    });
  });

  group('hysteresis (strict entry, forgiving hold)', () {
    test('borderline offset: rejected on entry, held when already good', () {
      // Allowed entry offset = 0.35/2 * 0.35 = 0.1225; with +15% hold = 0.1409.
      final borderline = _centredObject(fill: 0.5, dx: 0.13);
      expect(
        _eval(borderline, previous: PlacementStatus.idle),
        PlacementStatus.offCenter,
        reason: 'entry to good must be strict',
      );
      expect(
        _eval(borderline, previous: PlacementStatus.good),
        PlacementStatus.good,
        reason: 'already-good holds through jitter inside the Schmitt band',
      );
    });

    test('borderline fill holds good but does not admit from cold', () {
      // maxFill 0.85; hold widens to 0.9775. fill 0.9 is inside the band.
      final nearlyTooClose = _centredObject(fill: 0.9);
      expect(
        _eval(nearlyTooClose, previous: PlacementStatus.idle),
        PlacementStatus.tooClose,
      );
      expect(
        _eval(nearlyTooClose, previous: PlacementStatus.good),
        PlacementStatus.good,
      );
    });

    test('a gross violation escapes the hold band', () {
      expect(
        _eval(_centredObject(fill: 0.5, dx: 0.3), previous: PlacementStatus.good),
        PlacementStatus.offCenter,
      );
    });

    test('non-good previous states get NO widening', () {
      final borderline = _centredObject(fill: 0.5, dx: 0.13);
      expect(
        _eval(borderline, previous: PlacementStatus.tooFar),
        PlacementStatus.offCenter,
      );
    });
  });

  group('tolerance sanitization', () {
    test('NaN/negative values fall back to defaults', () {
      final t = const PlacementTolerances(
        minFillRatio: double.nan,
        maxFillRatio: -1,
        centerToleranceFrac: 2, // > max 1
        hysteresisFrac: -0.5,
        minConfidence: double.nan,
      ).sanitized();
      expect(t.minFillRatio, 0.20);
      expect(t.maxFillRatio, 0.85);
      expect(t.centerToleranceFrac, 0.35);
      expect(t.hysteresisFrac, 0.15);
      expect(t.minConfidence, 0.35);
    });

    test('inverted fill range is repaired by swapping', () {
      final t = const PlacementTolerances(minFillRatio: 0.9, maxFillRatio: 0.1)
          .sanitized();
      expect(t.minFillRatio, 0.1);
      expect(t.maxFillRatio, 0.9);
    });

    test('a broken tolerance input still yields a sane decision', () {
      expect(
        evaluatePlacement(
          PlacementDetection(objectNormalized: _centredObject(fill: 0.5)),
          tolerances: const PlacementTolerances(
            minFillRatio: double.nan,
            maxFillRatio: double.nan,
          ),
        ),
        PlacementStatus.good,
      );
    });
  });
}
