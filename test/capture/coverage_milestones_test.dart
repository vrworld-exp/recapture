// test/capture/coverage_milestones_test.dart
//
// Pure coverage of the milestone math: percentage (incl. zero-segment guard),
// reached-at (>=), and newly-crossed (excluding already fired) including the
// multi-crossing + non-integer-boundary cases.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/capture/coverage_milestones.dart';

void main() {
  group('coveragePercent', () {
    test('computes filled/total * 100', () {
      expect(coveragePercent(3, 12), 25);
      expect(coveragePercent(6, 12), 50);
      expect(coveragePercent(12, 12), 100);
    });

    test('non-integer boundary: 8/30 = 26.7%', () {
      expect(coveragePercent(8, 30), closeTo(26.67, 0.01));
      expect(coveragePercent(7, 30), closeTo(23.33, 0.01));
    });

    test('zero segments → 0 (no division by zero)', () {
      expect(coveragePercent(0, 0), 0);
      expect(coveragePercent(5, 0), 0);
    });
  });

  group('milestonesReachedAt', () {
    test('none below 25', () => expect(milestonesReachedAt(24.9), isEmpty));
    test('25 at exactly 25', () => expect(milestonesReachedAt(25), [25]));
    test('cumulative', () {
      expect(milestonesReachedAt(50), [25, 50]);
      expect(milestonesReachedAt(99.9), [25, 50, 75]);
      expect(milestonesReachedAt(100), [25, 50, 75, 100]);
    });
  });

  group('newlyCrossedMilestones', () {
    test('excludes already-fired, ascending', () {
      expect(
        newlyCrossedMilestones(pct: 60, alreadyFired: {25}),
        [50],
      );
    });

    test('a single jump can cross several at once', () {
      expect(
        newlyCrossedMilestones(pct: 80, alreadyFired: {}),
        [25, 50, 75],
      );
    });

    test('nothing new when all reached are fired', () {
      expect(
        newlyCrossedMilestones(pct: 100, alreadyFired: {25, 50, 75, 100}),
        isEmpty,
      );
    });

    test('non-integer boundary: 26.7% crosses 25 (filled 8 of 30)', () {
      final pct = coveragePercent(8, 30);
      expect(newlyCrossedMilestones(pct: pct, alreadyFired: {}), [25]);
      // 7 of 30 = 23.3% → not yet.
      expect(
        newlyCrossedMilestones(pct: coveragePercent(7, 30), alreadyFired: {}),
        isEmpty,
      );
    });
  });
}
