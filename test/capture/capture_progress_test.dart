// test/capture/capture_progress_test.dart
//
// Pure unit tests for the progress model: acceptedFraction / coverageFraction /
// isComplete across normal, zero-target, over-capture, and out-of-range inputs;
// the fromCoverage factory consistency with RingCoverage; and value equality.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/capture_progress.dart';
import 'package:recapture/domain/entities/ring_coverage.dart';

void main() {
  group('acceptedFraction', () {
    test('normal ratio', () {
      const p = CaptureProgress(accepted: 12, target: 36, coveragePct: 68);
      expect(p.acceptedFraction, closeTo(12 / 36, 1e-9));
    });

    test('zero target → 0 (no div-by-zero)', () {
      const p = CaptureProgress(accepted: 5, target: 0, coveragePct: 0);
      expect(p.acceptedFraction, 0.0);
    });

    test('negative target → 0', () {
      const p = CaptureProgress(accepted: 5, target: -3, coveragePct: 0);
      expect(p.acceptedFraction, 0.0);
    });

    test('over-capture clamps to 1', () {
      const p = CaptureProgress(accepted: 38, target: 36, coveragePct: 100);
      expect(p.acceptedFraction, 1.0);
    });
  });

  group('coverageFraction', () {
    test('normal percentage', () {
      const p = CaptureProgress(accepted: 0, target: 10, coveragePct: 68);
      expect(p.coverageFraction, closeTo(0.68, 1e-9));
    });

    test('above 100 clamps to 1', () {
      const p = CaptureProgress(accepted: 0, target: 10, coveragePct: 150);
      expect(p.coverageFraction, 1.0);
    });

    test('below 0 clamps to 0', () {
      const p = CaptureProgress(accepted: 0, target: 10, coveragePct: -5);
      expect(p.coverageFraction, 0.0);
    });
  });

  group('isComplete', () {
    test('true at/above threshold', () {
      const p = CaptureProgress(
          accepted: 0, target: 10, coveragePct: 80, completeAtPct: 80);
      expect(p.isComplete, isTrue);
    });

    test('false below threshold', () {
      const p = CaptureProgress(
          accepted: 0, target: 10, coveragePct: 79.9, completeAtPct: 80);
      expect(p.isComplete, isFalse);
    });

    test('zero target is never complete even at high coverage', () {
      const p = CaptureProgress(
          accepted: 0, target: 0, coveragePct: 100, completeAtPct: 80);
      expect(p.isComplete, isFalse);
    });
  });

  group('fromCoverage', () {
    test('mirrors RingCoverage accepted/target and count-progress coverage', () {
      const coverage = RingCoverage(
        segmentCount: 10,
        filledIndices: {0, 1, 2, 3, 4},
      );
      final p = CaptureProgress.fromCoverage(coverage, completeAtPct: 80);
      expect(p.accepted, 5);
      expect(p.target, 10);
      expect(p.coveragePct, closeTo(50, 1e-9)); // 5/10 * 100
      expect(p.completeAtPct, 80);
    });

    test('explicit coveragePct overrides the count-derived default', () {
      const coverage = RingCoverage(segmentCount: 10, filledIndices: {0, 1});
      final p = CaptureProgress.fromCoverage(coverage, coveragePct: 73);
      expect(p.accepted, 2);
      expect(p.coveragePct, 73);
    });

    test('out-of-range filled indices are ignored (matches ring map count)', () {
      const coverage = RingCoverage(
        segmentCount: 4,
        filledIndices: {0, 1, 99, -1},
      );
      final p = CaptureProgress.fromCoverage(coverage);
      expect(p.accepted, 2); // only 0 and 1 are in range
      expect(p.target, 4);
    });
  });

  group('equality', () {
    test('identical values are equal', () {
      const a = CaptureProgress(accepted: 1, target: 2, coveragePct: 3);
      const b = CaptureProgress(accepted: 1, target: 2, coveragePct: 3);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('differing values are not equal', () {
      const a = CaptureProgress(accepted: 1, target: 2, coveragePct: 3);
      const b = CaptureProgress(accepted: 1, target: 2, coveragePct: 4);
      expect(a, isNot(b));
    });
  });
}
