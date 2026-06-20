// test/capture/placement_box_test.dart
//
// Pure unit tests for the normalized placement box: centred rect, ratio
// clamping (>1, negative, NaN), and containment.
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/placement_box.dart';

void main() {
  group('normalizedRect', () {
    test('default 0.7 box is centred at (0.5,0.5)', () {
      final r = const PlacementBox().normalizedRect;
      expect(r.left, closeTo(0.15, 1e-9));
      expect(r.top, closeTo(0.15, 1e-9));
      expect(r.right, closeTo(0.85, 1e-9));
      expect(r.bottom, closeTo(0.85, 1e-9));
      expect(r.center, const Offset(0.5, 0.5));
    });

    test('ratio > 1 is clamped so the box never exceeds the frame', () {
      final r = const PlacementBox(widthRatio: 1.5, heightRatio: 2).normalizedRect;
      expect(r.left, 0.0);
      expect(r.right, 1.0);
      expect(r.top, 0.0);
      expect(r.bottom, 1.0);
    });

    test('negative / zero / NaN ratios clamp to a small valid box', () {
      for (final bad in [-0.5, 0.0, double.nan]) {
        final r = PlacementBox(widthRatio: bad, heightRatio: bad).normalizedRect;
        expect(r.width, greaterThan(0));
        expect(r.width, lessThanOrEqualTo(1));
        expect(r.center, const Offset(0.5, 0.5));
      }
    });
  });

  group('containsNormalized', () {
    const box = PlacementBox(); // 0.15..0.85

    test('a rect fully inside is contained', () {
      expect(box.containsNormalized(const Rect.fromLTRB(0.4, 0.4, 0.6, 0.6)),
          isTrue);
    });

    test('a rect crossing an edge is not contained', () {
      expect(box.containsNormalized(const Rect.fromLTRB(0.1, 0.4, 0.6, 0.6)),
          isFalse);
    });

    test('a rect fully outside is not contained', () {
      expect(box.containsNormalized(const Rect.fromLTRB(0.9, 0.9, 0.95, 0.95)),
          isFalse);
    });
  });

  group('PlacementStatus', () {
    test('warning states are flagged; idle/good are not', () {
      expect(PlacementStatus.idle.isWarning, isFalse);
      expect(PlacementStatus.good.isWarning, isFalse);
      expect(PlacementStatus.tooClose.isWarning, isTrue);
      expect(PlacementStatus.tooFar.isWarning, isTrue);
      expect(PlacementStatus.offCenter.isWarning, isTrue);
    });
  });
}
