// test/capture/segment_capture_decision_test.dart
//
// Overlap enforcement for Level A. Tests the pure decision (evaluateSegmentCapture)
// + its integration on the existing RingCoverageEngine (evaluateCapture /
// markUncovered): proceed on empty, reject-already-filled on covered, no mutation
// on evaluation, segment-granular overlap (not exact-yaw), wraparound at the ±180°
// boundary, completion, retake (markUncovered), and reset.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/capture/ring_coverage_engine.dart';
import 'package:recapture/domain/capture/segment_capture_decision.dart';

void main() {
  group('evaluateSegmentCapture (pure)', () {
    test('empty segment → ProceedCapture carrying the index', () {
      final d = evaluateSegmentCapture(segmentIndex: 5, isFilled: false);
      expect(d, isA<ProceedCapture>());
      expect(d.segmentIndex, 5);
    });

    test('filled segment → RejectAlreadyFilled carrying the index', () {
      final d = evaluateSegmentCapture(segmentIndex: 7, isFilled: true);
      expect(d, isA<RejectAlreadyFilled>());
      expect(d.segmentIndex, 7);
    });

    test('exhaustive sealed switch compiles and routes', () {
      String describe(SegmentCaptureDecision d) => switch (d) {
            ProceedCapture() => 'go',
            RejectAlreadyFilled() => RejectAlreadyFilled.warningMessage,
          };
      expect(describe(const ProceedCapture(0)), 'go');
      expect(
        describe(const RejectAlreadyFilled(0)),
        'Already captured this angle — turn to the next section',
      );
    });

    test('warningMessage is the exact required copy', () {
      // DIRECTIVE copy: the rejection names the action that resolves it. The
      // capture screen's already-captured snack renders this constant verbatim.
      expect(
        RejectAlreadyFilled.warningMessage,
        'Already captured this angle — turn to the next section',
      );
    });

    test('value equality by variant + index', () {
      expect(const ProceedCapture(1), const ProceedCapture(1));
      expect(const RejectAlreadyFilled(1), const RejectAlreadyFilled(1));
      // same index, different variant → not equal
      expect(const ProceedCapture(1) == const RejectAlreadyFilled(1), isFalse);
      expect(const ProceedCapture(1) == const ProceedCapture(2), isFalse);
    });
  });

  group('RingCoverageEngine.evaluateCapture', () {
    RingCoverageEngine engine() => RingCoverageEngine()..start(0, 12);

    test('empty segment → ProceedCapture', () {
      final e = engine();
      e.updateYaw(0); // segment 0
      final d = e.evaluateCapture();
      expect(d, isA<ProceedCapture>());
      expect(d.segmentIndex, 0);
    });

    test('after the segment is covered → RejectAlreadyFilled', () {
      final e = engine();
      e.updateYaw(0);
      e.markCurrentCovered();
      final d = e.evaluateCapture();
      expect(d, isA<RejectAlreadyFilled>());
      expect(d.segmentIndex, 0);
    });

    test('evaluate is a pure read — does not mutate coverage', () {
      final e = engine();
      e.updateYaw(0);
      expect(e.evaluateCapture(), isA<ProceedCapture>());
      expect(e.evaluateCapture(), isA<ProceedCapture>()); // still empty
      expect(e.coveredCount, 0);
    });

    test('overlap is segment-granular, not exact-yaw', () {
      // 12 segments → 30° each. Cover at yaw 10° (segment 0), then a slightly
      // different yaw still inside segment 0 must also reject.
      final e = engine();
      e.updateYaw(10);
      e.markCurrentCovered();
      e.updateYaw(20); // same 30° slice (segment 0)
      final d = e.evaluateCapture();
      expect(d, isA<RejectAlreadyFilled>());
      expect(d.segmentIndex, 0);
    });

    test('covering one segment leaves a neighbour proceeding', () {
      final e = engine();
      e.updateYaw(10); // segment 0
      e.markCurrentCovered();
      e.updateYaw(40); // segment 1
      expect(e.evaluateCapture(), isA<ProceedCapture>());
    });

    test('wraparound: segment across the ±180° boundary enforces overlap', () {
      // yawStart 170° → yaw 190° wraps to position 20° (segment 0). Cover it,
      // then re-aim near the same wrapped slice → reject.
      final e = RingCoverageEngine()..start(170, 12);
      e.updateYaw(190);
      e.markCurrentCovered();
      e.updateYaw(195); // still segment 0 (position ~25°)
      expect(e.evaluateCapture(), isA<RejectAlreadyFilled>());
    });

    test('not started → proceeds at segment 0 (empty ring)', () {
      final e = RingCoverageEngine();
      final d = e.evaluateCapture();
      expect(d, isA<ProceedCapture>());
      expect(d.segmentIndex, 0);
    });

    test('unnormalized yaw (>360) still resolves and enforces overlap', () {
      final e = engine();
      e.updateYaw(360 + 10); // wraps to 10° → segment 0
      e.markCurrentCovered();
      e.updateYaw(360 + 15);
      expect(e.evaluateCapture(), isA<RejectAlreadyFilled>());
    });
  });

  group('full-ring coverage sweep', () {
    test('every yaw across [0,360) resolves and proceeds before any fill', () {
      final e = RingCoverageEngine()..start(0, 12);
      for (var i = 0; i < 360; i++) {
        final yaw = i * (2 * math.pi) / 360 * 180 / math.pi; // i degrees
        e.updateYaw(yaw.toDouble());
        final d = e.evaluateCapture();
        expect(d, isA<ProceedCapture>());
        expect(d.segmentIndex, inInclusiveRange(0, 11));
      }
    });
  });

  group('markUncovered (retake) + reset', () {
    test('markUncovered reverts a filled segment so capture proceeds again', () {
      final e = RingCoverageEngine()..start(0, 12);
      e.updateYaw(0);
      e.markCurrentCovered();
      expect(e.evaluateCapture(), isA<RejectAlreadyFilled>());
      e.markUncovered(0);
      expect(e.evaluateCapture(), isA<ProceedCapture>());
    });

    test('markUncovered is idempotent and range-guarded', () {
      final e = RingCoverageEngine()..start(0, 4);
      e.markUncovered(0); // already empty
      e.markUncovered(99); // out of range
      e.markUncovered(-1);
      expect(e.coveredCount, 0);
    });

    test('reset lets a previously-filled segment proceed again', () {
      final e = RingCoverageEngine()..start(0, 12);
      e.updateYaw(0);
      e.markCurrentCovered();
      e.reset();
      e.start(0, 12);
      e.updateYaw(0);
      expect(e.evaluateCapture(), isA<ProceedCapture>());
    });
  });

  group('completion', () {
    test('isComplete only once every segment is covered', () {
      final e = RingCoverageEngine()..start(0, 4);
      expect(e.isComplete, isFalse);
      for (var i = 0; i < 4; i++) {
        e.updateYaw(i * 90.0 + 5);
        e.markCurrentCovered();
      }
      expect(e.isComplete, isTrue);
      expect(e.coveredCount, 4);
      // every segment now rejects
      e.updateYaw(5);
      expect(e.evaluateCapture(), isA<RejectAlreadyFilled>());
    });
  });
}
