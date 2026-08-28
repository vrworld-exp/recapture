// test/capture/ring_coverage_test.dart
//
// Pure unit tests for the ring coverage model: per-segment state (filled wins
// over target), defensive handling of null / out-of-range target and filled
// indices (no crash, no NaN), progress/filledCount/isComplete, and value
// equality.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/ring_coverage.dart';

void main() {
  group('stateOf', () {
    const c = RingCoverage(
      segmentCount: 4,
      filledIndices: {0, 1},
      targetIndex: 2,
    );

    test('filled / target / missing classification', () {
      expect(c.stateOf(0), SegmentState.filled);
      expect(c.stateOf(1), SegmentState.filled);
      expect(c.stateOf(2), SegmentState.target);
      expect(c.stateOf(3), SegmentState.missing);
    });

    test('filled takes precedence over target', () {
      const cc = RingCoverage(
          segmentCount: 4, filledIndices: {2}, targetIndex: 2);
      expect(cc.stateOf(2), SegmentState.filled);
      expect(cc.effectiveTarget, isNull); // already filled → no highlight
    });

    test('out-of-range index → missing (no crash)', () {
      expect(c.stateOf(-1), SegmentState.missing);
      expect(c.stateOf(99), SegmentState.missing);
    });
  });

  group('defensive target / filled handling', () {
    test('null target → no target segment', () {
      const c = RingCoverage(segmentCount: 4, filledIndices: {0});
      expect(c.effectiveTarget, isNull);
      expect(c.stateOf(1), SegmentState.missing);
    });

    test('out-of-range target is ignored', () {
      const c = RingCoverage(segmentCount: 4, targetIndex: 9);
      expect(c.effectiveTarget, isNull);
      expect(List.generate(4, c.stateOf),
          everyElement(SegmentState.missing));
    });

    test('out-of-range filled indices do not inflate the count', () {
      const c = RingCoverage(
        segmentCount: 4,
        filledIndices: {0, 1, 7, -3},
      );
      expect(c.filledCount, 2); // only 0 and 1 are in range
    });
  });

  group('progress / completion', () {
    test('progress is filledCount / N', () {
      const c = RingCoverage(segmentCount: 4, filledIndices: {0, 1, 2});
      expect(c.progress, closeTo(0.75, 1e-9));
    });

    test('N = 0 → progress 0, not complete (no division by zero)', () {
      const c = RingCoverage(segmentCount: 0);
      expect(c.progress, 0);
      expect(c.isComplete, isFalse);
    });

    test('all filled → complete, progress 1.0', () {
      const c = RingCoverage(segmentCount: 3, filledIndices: {0, 1, 2});
      expect(c.isComplete, isTrue);
      expect(c.progress, 1.0);
    });
  });

  group('equality', () {
    test('equal by count + target + filled set', () {
      expect(
        const RingCoverage(segmentCount: 4, filledIndices: {0, 1}, targetIndex: 2),
        const RingCoverage(segmentCount: 4, filledIndices: {1, 0}, targetIndex: 2),
      );
    });

    test('differs when a field differs', () {
      expect(
        const RingCoverage(segmentCount: 4, filledIndices: {0}) ==
            const RingCoverage(segmentCount: 4, filledIndices: {0, 1}),
        isFalse,
      );
    });
  });
}
