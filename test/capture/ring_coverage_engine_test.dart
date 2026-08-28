// test/capture/ring_coverage_engine_test.dart
//
// Pure unit tests for the eye-ring coverage engine: angular normalization +
// segment assignment (wraparound-safe, documented boundary inclusivity), the
// 0→360 sweep, coverage vs assignment separation, hysteresis, direction,
// nearest-uncovered guidance, rebaseline policy, and the RingCoverage bridge.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/capture/ring_coverage_engine.dart';
import 'package:recapture/domain/entities/ring_coverage.dart';

void main() {
  group('RingMath.normalizeDegrees', () {
    test('maps into [0, 360), wraparound-safe', () {
      expect(RingMath.normalizeDegrees(0), 0);
      expect(RingMath.normalizeDegrees(360), 0);
      expect(RingMath.normalizeDegrees(370), closeTo(10, 1e-9));
      expect(RingMath.normalizeDegrees(-10), closeTo(350, 1e-9));
      expect(RingMath.normalizeDegrees(720), 0);
      expect(RingMath.normalizeDegrees(-370), closeTo(350, 1e-9));
    });
  });

  group('RingMath.assignSegment', () {
    test('floor-based, boundary belongs to the higher segment', () {
      expect(RingMath.assignSegment(0, 12), 0);
      expect(RingMath.assignSegment(29.999, 12), 0);
      expect(RingMath.assignSegment(30, 12), 1); // exactly on boundary → higher
      expect(RingMath.assignSegment(45, 12), 1);
      expect(RingMath.assignSegment(359.999, 12), 11);
    });

    test('clamps fp 360 and guards segmentCount', () {
      expect(RingMath.assignSegment(360, 12), 11); // never escapes range
      expect(RingMath.assignSegment(123, 1), 0); // whole ring = one segment
      expect(RingMath.assignSegment(50, 0), 0); // guarded >= 1
    });
  });

  group('signedDeltaDegrees', () {
    test('shortest path, wrap-aware, sign = direction', () {
      expect(RingMath.signedDeltaDegrees(350, 10), closeTo(20, 1e-9));
      expect(RingMath.signedDeltaDegrees(10, 350), closeTo(-20, 1e-9));
      expect(RingMath.signedDeltaDegrees(0, 90), closeTo(90, 1e-9));
    });
  });

  group('sweep', () {
    test('0→330 by 30° visits segments 0..11 in order', () {
      final e = RingCoverageEngine();
      e.start(0, 12);
      for (var i = 0; i < 12; i++) {
        expect(e.updateYaw(i * 30.0), i, reason: 'yaw ${i * 30}');
      }
    });
  });

  group('wraparound', () {
    test('yawStart=170, yaw 190 → position 20° (segment 0), continuous', () {
      final e = RingCoverageEngine();
      e.start(170, 12);
      expect(e.updateYaw(170), 0);
      final seg = e.updateYaw(190); // "−170" wrapped; delta = 20
      expect(e.normalizedDelta, closeTo(20, 1e-9));
      expect(seg, 0);
    });

    test('crossing 360 boundary stays continuous (yawStart=350)', () {
      final e = RingCoverageEngine();
      e.start(350, 12);
      expect(e.updateYaw(350), 0); // delta 0
      expect(e.updateYaw(10), 0); // delta 20 → seg 0
      expect(e.normalizedDelta, closeTo(20, 1e-9));
      expect(e.updateYaw(20), 1); // delta 30 → seg 1, no jump
    });
  });

  group('direction', () {
    test('forward vs backward', () {
      final e = RingCoverageEngine();
      e.start(0, 12);
      e.updateYaw(0);
      e.updateYaw(30);
      expect(e.lastTurn, RingTurn.forward);
      e.updateYaw(10);
      expect(e.lastTurn, RingTurn.backward);
    });

    test('movement below the dead-band stays idle', () {
      final e = RingCoverageEngine();
      e.start(0, 12);
      e.updateYaw(0);
      e.updateYaw(0.1); // < 0.5° dead-band
      expect(e.lastTurn, RingTurn.idle);
    });
  });

  group('skip / reverse', () {
    test('fast jump assigns the actual position; skipped stay uncovered', () {
      final e = RingCoverageEngine();
      e.start(0, 12);
      e.updateYaw(0);
      e.markCurrentCovered();
      expect(e.updateYaw(200), 6); // jumped to segment 6
      e.markCurrentCovered();
      expect(e.coveredSegments, [0, 6]);
      expect(e.uncoveredSegments, isNot(contains(0)));
    });
  });

  group('coverage vs assignment', () {
    test('being in a segment does NOT cover it; capture does', () {
      final e = RingCoverageEngine();
      e.start(0, 4);
      e.updateYaw(95); // segment 1
      expect(e.currentSegment, 1);
      expect(e.covered.every((c) => !c), isTrue); // nothing covered yet
      e.markCurrentCovered();
      expect(e.covered[1], isTrue);
    });

    test('markCurrentCovered is idempotent; progress + isComplete', () {
      final e = RingCoverageEngine();
      e.start(0, 4);
      for (var i = 0; i < 4; i++) {
        e.updateYaw(i * 90.0 + 5);
        e.markCurrentCovered();
        e.markCurrentCovered(); // idempotent
      }
      expect(e.coveredCount, 4);
      expect(e.progress, 1.0);
      expect(e.isComplete, isTrue);
    });

    test('partial progress', () {
      final e = RingCoverageEngine();
      e.start(0, 4);
      e.updateYaw(0);
      e.markCurrentCovered();
      expect(e.progress, 0.25);
      expect(e.isComplete, isFalse);
    });

    test('markCovered out of range / not started → no-op', () {
      final e = RingCoverageEngine();
      e.markCovered(0); // not started
      expect(e.started, isFalse);
      e.start(0, 4);
      e.markCovered(99);
      e.markCovered(-1);
      expect(e.coveredCount, 0);
    });
  });

  group('segmentCount edge cases', () {
    test('segmentCount = 1 → whole ring is segment 0', () {
      final e = RingCoverageEngine();
      e.start(0, 1);
      expect(e.updateYaw(200), 0);
      e.markCurrentCovered();
      expect(e.isComplete, isTrue);
    });

    test('segmentCount = 0 is guarded to 1', () {
      final e = RingCoverageEngine();
      e.start(0, 0);
      expect(e.segmentCount, 1);
      expect(e.updateYaw(123), 0);
    });

    test('large count is fine-grained', () {
      final e = RingCoverageEngine();
      e.start(0, 36);
      expect(e.updateYaw(95), 9); // 95 / 10 = 9.5 → floor 9
    });
  });

  group('not started', () {
    test('updateYaw before start returns null, no crash', () {
      final e = RingCoverageEngine();
      expect(e.updateYaw(123), isNull);
      expect(e.started, isFalse);
      expect(e.currentSegment, 0);
      expect(e.progress, 0);
      expect(e.isComplete, isFalse);
      expect(e.nearestUncovered(), isNull);
    });
  });

  group('rebaseline', () {
    test('moves origin, recomputes segment, preserves coverage', () {
      final e = RingCoverageEngine();
      e.start(0, 12);
      e.updateYaw(0);
      e.markCurrentCovered(); // cover segment 0
      e.updateYaw(60); // segment 2
      e.rebaseline(60); // new origin = current yaw → position 0 → segment 0
      expect(e.currentSegment, 0);
      expect(e.normalizedDelta, closeTo(0, 1e-9));
      expect(e.covered[0], isTrue); // coverage preserved by index
      // updates now measured from the new origin
      expect(e.updateYaw(90), 1); // 90 − 60 = 30 → segment 1
    });

    test('rebaseline before start is a no-op', () {
      final e = RingCoverageEngine();
      e.rebaseline(100);
      expect(e.started, isFalse);
    });
  });

  group('reset', () {
    test('clears to not-started', () {
      final e = RingCoverageEngine();
      e.start(0, 4);
      e.updateYaw(0);
      e.markCurrentCovered();
      e.reset();
      expect(e.started, isFalse);
      expect(e.covered, isEmpty);
      expect(e.updateYaw(50), isNull);
    });
  });

  group('hysteresis', () {
    test('off by default: boundary dither flips at the floor boundary', () {
      final e = RingCoverageEngine();
      e.start(0, 12); // size 30
      expect(e.updateYaw(29), 0);
      expect(e.updateYaw(31), 1);
      expect(e.updateYaw(29), 0); // flips back immediately (no hysteresis)
    });

    test('on: small dither around a boundary does not flicker', () {
      final e = RingCoverageEngine(boundaryHysteresisDeg: 5);
      e.start(0, 12); // size 30
      expect(e.updateYaw(25), 0);
      expect(e.updateYaw(31), 0); // 1° past boundary, within 5° band → hold
      expect(e.updateYaw(29), 0);
      expect(e.updateYaw(33), 0); // still within band
      expect(e.updateYaw(36), 1); // clearly past (>30+5) → switch
      expect(e.updateYaw(31), 1); // now holds at 1 within its band
    });

    test('on: a multi-segment jump still switches immediately', () {
      final e = RingCoverageEngine(boundaryHysteresisDeg: 5);
      e.start(0, 12);
      e.updateYaw(5); // segment 0
      expect(e.updateYaw(200), 6); // far jump leaves the band
    });
  });

  group('nearestUncovered', () {
    test('returns current if uncovered', () {
      final e = RingCoverageEngine();
      e.start(0, 12);
      e.updateYaw(95); // segment 3
      expect(e.nearestUncovered(), 3);
    });

    test('forward tie preference and wraparound', () {
      final e = RingCoverageEngine();
      e.start(0, 4);
      // cover 0; from 0, neighbours 1 (fwd) and 3 (bwd) are equidistant → fwd.
      e.updateYaw(0);
      e.markCurrentCovered();
      expect(e.nearestUncovered(from: 0), 1);
    });

    test('null when all covered', () {
      final e = RingCoverageEngine();
      e.start(0, 2);
      e.updateYaw(0);
      e.markCovered(0);
      e.markCovered(1);
      expect(e.nearestUncovered(), isNull);
    });
  });

  group('toRingCoverage bridge', () {
    test('produces the display model with filled + target', () {
      final e = RingCoverageEngine();
      e.start(0, 12);
      e.updateYaw(0);
      e.markCurrentCovered(); // segment 0
      e.updateYaw(95); // segment 3 (uncovered)
      final RingCoverage rc = e.toRingCoverage();
      expect(rc.segmentCount, 12);
      expect(rc.filledIndices, {0});
      expect(rc.targetIndex, 3); // nearest uncovered from current
      expect(rc.filledCount, 1);
    });
  });
}
