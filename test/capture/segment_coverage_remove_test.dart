// test/capture/segment_coverage_remove_test.dart
//
// Coverage for SegmentCoverage.removeCapture — the unfill counterpart to
// recordCapture used when a photo is deleted: it decrements (clamped at 0), can
// drop a segment below threshold so it becomes missing again, and ignores stale /
// out-of-range / already-empty indices.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/segment_coverage.dart';

void main() {
  group('removeCapture', () {
    test('decrements the fill count for the segment', () {
      final c = SegmentCoverage.of(segmentCount: 4, fillCounts: [2, 0, 0, 0]);
      final next = c.removeCapture(0);
      expect(next.fillCounts[0], 1);
    });

    test('a filled segment dropping to zero becomes missing again', () {
      final c = SegmentCoverage.of(segmentCount: 4, fillCounts: [1, 1, 0, 0]);
      expect(c.filled[0], isTrue);

      final next = c.removeCapture(0);
      expect(next.filled[0], isFalse);
      expect(next.missingSegments, contains(0));
      expect(next.filledCount, 1);
    });

    test('is clamped at 0 — an already-empty segment is unchanged', () {
      final c = SegmentCoverage.of(segmentCount: 4, fillCounts: [0, 0, 0, 0]);
      final next = c.removeCapture(0);
      expect(identical(next, c), isTrue);
      expect(next.fillCounts[0], 0);
    });

    test('an out-of-range index is unchanged', () {
      final c = SegmentCoverage.of(segmentCount: 4, fillCounts: [1, 0, 0, 0]);
      expect(identical(c.removeCapture(9), c), isTrue);
      expect(identical(c.removeCapture(-1), c), isTrue);
    });

    test('overfilled segment stays filled after one removal (threshold > 1)', () {
      final c = SegmentCoverage.of(
        segmentCount: 3,
        fillThreshold: 2,
        fillCounts: [3, 0, 0],
      );
      final next = c.removeCapture(0);
      expect(next.fillCounts[0], 2);
      expect(next.filled[0], isTrue, reason: 'still at threshold');
    });

    test('round-trips record→remove back to the original coverage', () {
      final base = SegmentCoverage.initial(segmentCount: 5);
      final after = base.recordCapture(2).removeCapture(2);
      expect(after, base);
    });
  });
}
