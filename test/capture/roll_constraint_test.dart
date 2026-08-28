// test/capture/roll_constraint_test.dart
//
// The pure roll-constraint hysteresis rule: raise at >15°, clear below 12°, hold
// in between; symmetric on |roll|; null/NaN/Infinity hold the prior state (no
// false warning). No Flutter/native.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/capture/roll_constraint.dart';

void main() {
  group('thresholds', () {
    test('named constants are the spec values (15 raise / 12 release)', () {
      expect(RollConstraint.raiseThresholdDeg, 15.0);
      expect(RollConstraint.releaseThresholdDeg, 12.0);
    });
  });

  group('raise / clear', () {
    test('inactive stays inactive within tolerance', () {
      expect(RollConstraint.nextActive(active: false, rollDegrees: 0), isFalse);
      expect(RollConstraint.nextActive(active: false, rollDegrees: 14.9), isFalse);
    });

    test('inactive → active once |roll| exceeds 15°', () {
      expect(RollConstraint.nextActive(active: false, rollDegrees: 15.1), isTrue);
      expect(RollConstraint.nextActive(active: false, rollDegrees: 40), isTrue);
    });

    test('active → inactive once |roll| drops below 12°', () {
      expect(RollConstraint.nextActive(active: true, rollDegrees: 11.9), isFalse);
      expect(RollConstraint.nextActive(active: true, rollDegrees: 0), isFalse);
    });
  });

  group('hysteresis band [12, 15] holds the prior state', () {
    test('rising through the band stays inactive until past 15', () {
      // wobble up from 12→15 while inactive → no raise yet
      expect(RollConstraint.nextActive(active: false, rollDegrees: 13), isFalse);
      expect(RollConstraint.nextActive(active: false, rollDegrees: 15), isFalse);
    });

    test('falling through the band stays active until below 12', () {
      // wobble down from 15→12 while active → stays raised
      expect(RollConstraint.nextActive(active: true, rollDegrees: 14), isTrue);
      expect(RollConstraint.nextActive(active: true, rollDegrees: 12), isTrue);
    });

    test('no flicker oscillating around 15 (boundary wobble)', () {
      var active = false;
      for (final roll in [14.0, 15.5, 14.5, 15.2, 13.0, 12.5]) {
        active = RollConstraint.nextActive(active: active, rollDegrees: roll);
      }
      // raised at 15.5, never dropped below 12 → still active
      expect(active, isTrue);
    });
  });

  group('symmetry on |roll|', () {
    test('left and right tilt past 15° both raise', () {
      expect(RollConstraint.nextActive(active: false, rollDegrees: 20), isTrue);
      expect(RollConstraint.nextActive(active: false, rollDegrees: -20), isTrue);
    });

    test('sign crossing while out of tolerance stays active (no clear)', () {
      var active = RollConstraint.nextActive(active: false, rollDegrees: 16);
      expect(active, isTrue);
      active = RollConstraint.nextActive(active: active, rollDegrees: -16);
      expect(active, isTrue); // still one continuous excursion
    });
  });

  group('invalid / unavailable data holds prior state', () {
    test('null roll holds', () {
      expect(RollConstraint.nextActive(active: false, rollDegrees: null), isFalse);
      expect(RollConstraint.nextActive(active: true, rollDegrees: null), isTrue);
    });

    test('NaN / Infinity hold', () {
      expect(RollConstraint.nextActive(active: false, rollDegrees: double.nan),
          isFalse);
      expect(
          RollConstraint.nextActive(
              active: true, rollDegrees: double.infinity),
          isTrue);
      expect(
          RollConstraint.nextActive(
              active: true, rollDegrees: double.negativeInfinity),
          isTrue);
    });
  });
}
