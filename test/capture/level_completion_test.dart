// test/capture/level_completion_test.dart
//
// Pure unit tests for the Level A completion gate: the AND of ratio-based coverage
// (≥ minCoveragePct, inclusive) and accepted-count (≥ minAcceptedCount, inclusive),
// per-criterion shortfall reporting, config validation/guards, and reading from
// the SegmentCoverage single-source-of-truth (honouring fillThreshold).
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/capture/level_completion.dart';
import 'package:recapture/domain/entities/segment_coverage.dart';

void main() {
  group('the AND gate', () {
    test('both criteria met → complete, no shortfalls', () {
      final r = evaluateLevelA(
        filledCount: 24,
        segmentCount: 30,
        acceptedCount: 24,
        minAcceptedCount: 24,
      ); // 24/30 = 0.80, 24 ≥ 24
      expect(r.isComplete, isTrue);
      expect(r.coverageMet, isTrue);
      expect(r.countMet, isTrue);
      expect(r.segmentsShort, 0);
      expect(r.photosShort, 0);
    });

    test('coverage short by one segment → incomplete, segmentsShort = 1', () {
      final r = evaluateLevelA(
        filledCount: 23,
        segmentCount: 30,
        acceptedCount: 24,
        minAcceptedCount: 24,
      );
      expect(r.isComplete, isFalse);
      expect(r.coverageMet, isFalse);
      expect(r.countMet, isTrue);
      expect(r.segmentsShort, 1);
      expect(r.photosShort, 0);
    });

    test('count short by one photo → incomplete, photosShort = 1', () {
      final r = evaluateLevelA(
        filledCount: 24,
        segmentCount: 30,
        acceptedCount: 23,
        minAcceptedCount: 24,
      );
      expect(r.isComplete, isFalse);
      expect(r.coverageMet, isTrue);
      expect(r.countMet, isFalse);
      expect(r.segmentsShort, 0);
      expect(r.photosShort, 1);
    });

    test('both short → incomplete, both shortfalls reported', () {
      final r = evaluateLevelA(
        filledCount: 20,
        segmentCount: 30,
        acceptedCount: 20,
        minAcceptedCount: 24,
      );
      expect(r.isComplete, isFalse);
      expect(r.segmentsShort, 4); // need 24
      expect(r.photosShort, 4);
    });
  });

  group('coverage is a ratio, not rounding (inclusive at threshold)', () {
    test('29/36 = 0.806 meets 80%; 28/36 = 0.777 does not', () {
      expect(
        evaluateLevelA(
                filledCount: 29,
                segmentCount: 36,
                acceptedCount: 100,
                minAcceptedCount: 0)
            .coverageMet,
        isTrue,
      );
      expect(
        evaluateLevelA(
                filledCount: 28,
                segmentCount: 36,
                acceptedCount: 100,
                minAcceptedCount: 0)
            .coverageMet,
        isFalse,
      );
    });

    test('exactly 80% is met (inclusive)', () {
      expect(
        evaluateLevelA(
                filledCount: 24,
                segmentCount: 30,
                acceptedCount: 0,
                minAcceptedCount: 0)
            .coverageMet,
        isTrue,
      );
    });

    test('small ring: 4/5 = 80% met, 3/5 not', () {
      expect(
        evaluateLevelA(
                filledCount: 4, segmentCount: 5, acceptedCount: 0, minAcceptedCount: 0)
            .coverageMet,
        isTrue,
      );
      expect(
        evaluateLevelA(
                filledCount: 3, segmentCount: 5, acceptedCount: 0, minAcceptedCount: 0)
            .coverageMet,
        isFalse,
      );
    });

    test('requiredSegments uses ceil and matches the gate at the boundary', () {
      // 36 segments @ 80% → ceil(28.8) = 29.
      final r = evaluateLevelA(
          filledCount: 28, segmentCount: 36, acceptedCount: 0, minAcceptedCount: 0);
      expect(r.requiredSegments, 29);
      expect(r.segmentsShort, 1);
      expect(r.coverageMet, isFalse);
    });
  });

  group('count criterion inclusivity', () {
    test('exactly the minimum is met; one short is not', () {
      expect(
        evaluateLevelA(
                filledCount: 100,
                segmentCount: 100,
                acceptedCount: 24,
                minAcceptedCount: 24)
            .countMet,
        isTrue,
      );
      expect(
        evaluateLevelA(
                filledCount: 100,
                segmentCount: 100,
                acceptedCount: 23,
                minAcceptedCount: 24)
            .countMet,
        isFalse,
      );
    });

    test('minAcceptedCount = 0 is always met', () {
      expect(
        evaluateLevelA(
                filledCount: 0, segmentCount: 30, acceptedCount: 0, minAcceptedCount: 0)
            .countMet,
        isTrue,
      );
    });
  });

  group('configurable threshold', () {
    test('a custom minCoveragePct changes the gate', () {
      final r = evaluateLevelA(
        filledCount: 18,
        segmentCount: 30,
        acceptedCount: 0,
        minAcceptedCount: 0,
        minCoveragePct: 60, // 18/30 = 60%
      );
      expect(r.coverageMet, isTrue);
      expect(r.minCoveragePct, 60);
    });
  });

  group('guards / invalid config', () {
    test('minCoveragePct > 100 or <= 0 or non-finite → default 80', () {
      for (final bad in [150.0, 0.0, -5.0, double.nan, double.infinity]) {
        final r = evaluateLevelA(
          filledCount: 24,
          segmentCount: 30,
          acceptedCount: 0,
          minAcceptedCount: 0,
          minCoveragePct: bad,
        );
        expect(r.minCoveragePct, kDefaultMinCoveragePct);
        expect(r.coverageMet, isTrue); // 24/30 = 80% under the default
      }
    });

    test('negative minAcceptedCount clamps to 0 (then met)', () {
      final r = evaluateLevelA(
        filledCount: 30,
        segmentCount: 30,
        acceptedCount: 0,
        minAcceptedCount: -5,
      );
      expect(r.minAcceptedCount, 0);
      expect(r.countMet, isTrue);
    });

    test('segmentCount == 0 → guarded, never complete, no divide-by-zero', () {
      final r = evaluateLevelA(
          filledCount: 0, segmentCount: 0, acceptedCount: 99, minAcceptedCount: 0);
      expect(r.coverageMet, isFalse);
      expect(r.isComplete, isFalse);
      expect(r.coverageRatio, 0.0);
      expect(r.requiredSegments, 0);
    });

    test('zero captures → incomplete, full shortfalls', () {
      final r = evaluateLevelA(
        filledCount: 0,
        segmentCount: 30,
        acceptedCount: 0,
        minAcceptedCount: 24,
      );
      expect(r.isComplete, isFalse);
      expect(r.segmentsShort, 24); // ceil(0.8*30)
      expect(r.photosShort, 24);
    });
  });

  group('reads from SegmentCoverage (single source of truth)', () {
    test('coverage comes from the state filledCount, not raw captures', () {
      // fillThreshold = 2: 30 raw captures but only some segments AT threshold.
      var cov = SegmentCoverage.initial(segmentCount: 30, fillThreshold: 2);
      // Fill 24 segments to threshold (2 captures each), leave 6 with one each.
      for (var i = 0; i < 24; i++) {
        cov = cov.recordCapture(i).recordCapture(i);
      }
      for (var i = 24; i < 30; i++) {
        cov = cov.recordCapture(i); // only 1 → NOT filled
      }
      expect(cov.filledCount, 24); // state's filled, honouring threshold

      final r = evaluateLevelAFromCoverage(
        cov,
        acceptedCount: 60, // many raw photos
        minAcceptedCount: 24,
      );
      expect(r.filledCount, 24);
      expect(r.segmentCount, 30);
      expect(r.coverageMet, isTrue); // 24/30 = 80% from filled, not 60 raw
      expect(r.isComplete, isTrue);
    });

    test('partially-filled segments below threshold do not count as coverage', () {
      var cov = SegmentCoverage.initial(segmentCount: 10, fillThreshold: 3);
      for (var i = 0; i < 10; i++) {
        cov = cov.recordCapture(i).recordCapture(i); // 2 of 3 each → none filled
      }
      expect(cov.filledCount, 0);
      final r = evaluateLevelAFromCoverage(cov,
          acceptedCount: 0, minAcceptedCount: 0);
      expect(r.coverageMet, isFalse);
      expect(r.segmentsShort, 8); // ceil(0.8*10)
    });
  });

  group('value equality', () {
    test('same inputs → equal results', () {
      final a = evaluateLevelA(
          filledCount: 24, segmentCount: 30, acceptedCount: 24, minAcceptedCount: 24);
      final b = evaluateLevelA(
          filledCount: 24, segmentCount: 30, acceptedCount: 24, minAcceptedCount: 24);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });
  });
}
