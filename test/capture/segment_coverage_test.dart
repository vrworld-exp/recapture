// test/capture/segment_coverage_test.dart
//
// Pure unit tests for the eye-ring segment-fill state model: derivation of
// filled / missingSegments / currentTarget from fillCounts + position + config,
// the nearest-missing target policy (wraparound-aware, forward-tie), fill
// threshold semantics, transforms (recordCapture / updatePosition / reset /
// reconfigure), edge/guard cases, and consistency with the ring engine's math.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/capture/ring_coverage_engine.dart';
import 'package:recapture/domain/entities/ring_coverage.dart';
import 'package:recapture/domain/entities/segment_coverage.dart';

void main() {
  group('derivation: filled / missing / progress', () {
    test('record captures in 0,3,6 of 12 → filled there, rest missing', () {
      var s = SegmentCoverage.initial(segmentCount: 12);
      s = s.recordCapture(0).recordCapture(3).recordCapture(6);

      expect(s.filled[0], isTrue);
      expect(s.filled[3], isTrue);
      expect(s.filled[6], isTrue);
      expect(s.filledCount, 3);
      expect(s.missingSegments,
          [1, 2, 4, 5, 7, 8, 9, 10, 11]); // all but 0,3,6, ascending
      expect(s.progress, closeTo(3 / 12, 1e-9));
      expect(s.isComplete, isFalse);
    });

    test('empty ring → nothing filled, all missing', () {
      final s = SegmentCoverage.initial(segmentCount: 8);
      expect(s.filledCount, 0);
      expect(s.missingSegments, [0, 1, 2, 3, 4, 5, 6, 7]);
      expect(s.progress, 0);
      expect(s.isComplete, isFalse);
    });
  });

  group('currentTarget: nearest-missing (wraparound-aware)', () {
    test('position near segment 11, only 0 missing → target 0 across the wrap',
        () {
      // Fill everything except segment 0, sit at 11. Distance 11→0 is 1 (wrap),
      // not 11 the long way; target must be 0.
      var s = SegmentCoverage.initial(segmentCount: 12);
      for (var i = 1; i < 12; i++) {
        s = s.recordCapture(i);
      }
      s = s.updatePosition(11);
      expect(s.missingSegments, [0]);
      expect(s.currentTarget, 0);
    });

    test('target is the closest gap, not the lowest index', () {
      // Missing: 2 and 9. From position 8, nearest is 9 (dist 1) over 2 (dist 6).
      var s = SegmentCoverage.initial(segmentCount: 12);
      for (var i = 0; i < 12; i++) {
        if (i != 2 && i != 9) s = s.recordCapture(i);
      }
      s = s.updatePosition(8);
      expect(s.missingSegments, [2, 9]);
      expect(s.currentTarget, 9);
    });

    test('equidistant missing on both sides → forward tie wins', () {
      // segmentCount 4, only 0 filled → missing {1,2,3}. From 0, segments 1
      // (fwd, dist 1) and 3 (bwd, dist 1) are equidistant → forward (1).
      var s = SegmentCoverage.initial(segmentCount: 4);
      s = s.recordCapture(0).updatePosition(0);
      expect(s.missingSegments, [1, 2, 3]);
      expect(s.currentTarget, 1);
    });

    test('matches the ring engine for the same missing set + origin', () {
      // Engine and model must agree on "nearest". Cover 0 and 6 in a 12-ring;
      // ask both for the nearest gap from position 3.
      final engine = RingCoverageEngine()..start(0, 12);
      engine.markCovered(0);
      engine.markCovered(6);

      var s = SegmentCoverage.initial(segmentCount: 12)
          .recordCapture(0)
          .recordCapture(6)
          .updatePosition(3);

      expect(s.currentTarget, engine.nearestUncovered(from: 3));
    });
  });

  group('target advances as gaps fill', () {
    test('filling the current target moves it to the next nearest', () {
      // 4-ring, fill 0, sit at 0 → target 1. Fill 1 → target advances to 2
      // (dist 2 fwd) vs 3 (dist 1 bwd)... 3 is nearer, so target becomes 3.
      var s = SegmentCoverage.initial(segmentCount: 4);
      s = s.recordCapture(0).updatePosition(0);
      expect(s.currentTarget, 1);

      s = s.recordCapture(1); // now missing {2,3}; from 0, 3 (dist1) < 2 (dist2)
      expect(s.missingSegments, [2, 3]);
      expect(s.currentTarget, 3);
    });
  });

  group('fillThreshold > 1', () {
    test('a segment needs K captures before it counts as filled', () {
      var s = SegmentCoverage.initial(segmentCount: 4, fillThreshold: 3);
      s = s.recordCapture(2);
      expect(s.filled[2], isFalse, reason: '1 of 3');
      expect(s.missingSegments, contains(2));

      s = s.recordCapture(2);
      expect(s.filled[2], isFalse, reason: '2 of 3');

      s = s.recordCapture(2);
      expect(s.filled[2], isTrue, reason: '3 of 3 → filled');
      expect(s.missingSegments, isNot(contains(2)));
    });

    test('0 < count < threshold is still missing and still a target candidate',
        () {
      var s = SegmentCoverage.initial(segmentCount: 3, fillThreshold: 2);
      s = s.recordCapture(1).updatePosition(1);
      expect(s.filled[1], isFalse);
      expect(s.currentTarget, 1); // partially filled, still the nearest gap
    });
  });

  group('completion', () {
    test('all filled → missing empty, target null, isComplete', () {
      var s = SegmentCoverage.initial(segmentCount: 5);
      for (var i = 0; i < 5; i++) {
        s = s.recordCapture(i);
      }
      expect(s.missingSegments, isEmpty);
      expect(s.currentTarget, isNull);
      expect(s.isComplete, isTrue);
      expect(s.progress, 1.0);
    });
  });

  group('overfill idempotence', () {
    test('capturing an already-filled segment keeps filled true', () {
      var s = SegmentCoverage.initial(segmentCount: 4);
      s = s.recordCapture(1);
      expect(s.filled[1], isTrue);
      final before = s.filled;
      s = s.recordCapture(1).recordCapture(1);
      expect(s.filled, before); // filled unchanged
      expect(s.fillCounts[1], 3); // but the count climbed
      expect(s.filledCount, 1);
    });
  });

  group('updatePosition never fills (assignment ≠ coverage)', () {
    test('moving across segments fills nothing', () {
      var s = SegmentCoverage.initial(segmentCount: 6);
      s = s.updatePosition(0).updatePosition(3).updatePosition(5);
      expect(s.filledCount, 0);
      expect(s.missingSegments.length, 6);
    });

    test('same (normalized) position returns the identical instance', () {
      final s = SegmentCoverage.initial(segmentCount: 4).updatePosition(2);
      expect(identical(s.updatePosition(2), s), isTrue);
      expect(identical(s.updatePosition(6), s), isTrue); // 6 % 4 == 2
    });
  });

  group('reset / reconfigure', () {
    test('reset clears coverage, keeps shape', () {
      var s = SegmentCoverage.initial(segmentCount: 8, fillThreshold: 2);
      s = s.recordCapture(0).recordCapture(0).updatePosition(4);
      final r = s.reset();
      expect(r.segmentCount, 8);
      expect(r.fillThreshold, 2);
      expect(r.filledCount, 0);
      expect(r.position, 0);
    });

    test('reconfigure to a new segmentCount re-inits cleanly (no stale indices)',
        () {
      var s = SegmentCoverage.initial(segmentCount: 12);
      for (var i = 0; i < 12; i++) {
        s = s.recordCapture(i);
      }
      final r = s.reconfigure(segmentCount: 8);
      expect(r.segmentCount, 8);
      expect(r.fillCounts.length, 8);
      expect(r.filledCount, 0);
      expect(r.missingSegments, [0, 1, 2, 3, 4, 5, 6, 7]);
    });
  });

  group('guards', () {
    test('segmentCount < 1 is clamped to 1', () {
      final s = SegmentCoverage.initial(segmentCount: 0);
      expect(s.segmentCount, 1);
      expect(s.missingSegments, [0]);
      expect(s.currentTarget, 0);
    });

    test('fillThreshold < 1 is clamped to 1', () {
      final s = SegmentCoverage.of(segmentCount: 3, fillThreshold: 0);
      expect(s.fillThreshold, 1);
    });

    test('recordCapture out of range → unchanged', () {
      final s = SegmentCoverage.initial(segmentCount: 4);
      expect(identical(s.recordCapture(99), s), isTrue);
      expect(identical(s.recordCapture(-1), s), isTrue);
    });

    test('of() normalizes fillCounts length and negatives', () {
      final s = SegmentCoverage.of(
        segmentCount: 3,
        fillCounts: [5, -2, 1, 9], // too long; negative
      );
      expect(s.fillCounts, [5, 0, 1]); // truncated to 3, -2 → 0
    });

    test('position is taken modulo segmentCount', () {
      final s = SegmentCoverage.of(segmentCount: 4, position: -1);
      expect(s.position, 3);
    });
  });

  group('missingByProximity', () {
    test('orders gaps nearest-first from position, forward ties first', () {
      // 6-ring, missing {1,3,5}, position 0. Distances: 1→1, 5→1(wrap), 3→3.
      // Forward tie (1) before backward (5), then 3.
      var s = SegmentCoverage.initial(segmentCount: 6);
      s = s.recordCapture(0).recordCapture(2).recordCapture(4).updatePosition(0);
      expect(s.missingByProximity(), [1, 5, 3]);
    });

    test('empty when complete', () {
      var s = SegmentCoverage.initial(segmentCount: 2);
      s = s.recordCapture(0).recordCapture(1);
      expect(s.missingByProximity(), isEmpty);
    });
  });

  group('toRingCoverage bridge', () {
    test('produces the display model with filled + nearest-missing target', () {
      var s = SegmentCoverage.initial(segmentCount: 12);
      s = s.recordCapture(0).recordCapture(6).updatePosition(0);
      final RingCoverage rc = s.toRingCoverage();
      expect(rc.segmentCount, 12);
      expect(rc.filledIndices, {0, 6});
      expect(rc.targetIndex, s.currentTarget);
      expect(rc.filledCount, 2);
    });
  });

  group('value equality', () {
    test('== / hashCode by counts + position + config', () {
      final a = SegmentCoverage.initial(segmentCount: 4).recordCapture(1);
      final b = SegmentCoverage.initial(segmentCount: 4).recordCapture(1);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);

      final c = b.updatePosition(2);
      expect(a, isNot(equals(c)));
    });
  });

  group('RingMath.segmentDistance (shared util)', () {
    test('wraparound-aware, fewer-of-two-ways', () {
      expect(RingMath.segmentDistance(0, 0, 12), 0);
      expect(RingMath.segmentDistance(0, 1, 12), 1);
      expect(RingMath.segmentDistance(0, 11, 12), 1); // the short way
      expect(RingMath.segmentDistance(0, 6, 12), 6); // half-ring max
      expect(RingMath.segmentDistance(11, 1, 12), 2);
    });
  });
}
