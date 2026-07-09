// test/capture/level_segment_machine_test.dart
//
// Per-level segment state machines for Levels A/B/C as INDEPENDENT instances of
// the SAME engine. Proves: per-level segment counts (may differ), strict state
// independence (mutating one leaves the others untouched), per-level `yawStart`
// re-baselining + wraparound, overlap eval, resume restore, and that the factory
// sizes B/C from their own bands — all pure, no Flutter/Hive.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/analytics/capture_level_events.dart';
import 'package:recapture/application/capture/progression/level_segment_machines.dart';
import 'package:recapture/domain/capture/capture_flow_variant.dart';
import 'package:recapture/domain/capture/level_segment_machine.dart';
import 'package:recapture/domain/capture/ring_coverage_engine.dart';
import 'package:recapture/domain/capture/segment_capture_decision.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/segment_coverage.dart';

LevelSegmentMachine _machine(String id, String code, int n) =>
    LevelSegmentMachine(
      levelId: id,
      levelCode: code,
      band: PitchBand(id: id, minDegrees: 0, maxDegrees: 90, segments: n),
    );

/// Fills every segment of [m] so it reaches completion (begins at yaw 0 first).
void _fillAll(LevelSegmentMachine m) {
  for (var i = 0; i < m.segmentCount; i++) {
    m.recordCapture(i);
  }
}

void main() {
  group('per-level segment counts (may differ from A)', () {
    test('A=30, B=24, C=24 each compute coverage for their own N', () {
      final a = _machine('mid', 'A', 30);
      final b = _machine('high', 'B', 24);
      final c = _machine('low', 'C', 24);
      expect(a.segmentCount, 30);
      expect(b.segmentCount, 24);
      expect(c.segmentCount, 24);
      expect(a.filled.length, 30);
      expect(b.filled.length, 24);
      expect(b.missingSegments.length, 24);
    });

    test('segmentCount overrides the band default; guarded >= 1', () {
      final m = LevelSegmentMachine(
        levelId: 'high',
        levelCode: 'B',
        band: PitchBand(id: 'high', minDegrees: 0, maxDegrees: 90, segments: 24),
        segmentCount: 12,
      );
      expect(m.segmentCount, 12);
      final guarded = _machine('x', 'X', 0);
      expect(guarded.segmentCount, 1);
    });
  });

  group('per-level independence (no shared mutable state)', () {
    test('filling B leaves A and C completely unchanged', () {
      final a = _machine('mid', 'A', 30);
      final b = _machine('high', 'B', 24);
      final c = _machine('low', 'C', 24);

      b.recordCapture(0);
      b.recordCapture(5);

      expect(b.filledCount, 2);
      expect(a.filledCount, 0);
      expect(c.filledCount, 0);
      expect(a.missingSegments.length, 30);
      expect(c.missingSegments.length, 24);
    });

    test('B complete while C is not-started — independent completion', () {
      final b = _machine('high', 'B', 24);
      final c = _machine('low', 'C', 24);
      _fillAll(b);

      expect(b.isComplete, isTrue);
      expect(c.isComplete, isFalse);
      expect(c.filledCount, 0);
      expect(c.progress, 0);
      expect(b.progress, 1.0);
    });

    test('interleaved mutation of all three — no cross-instance corruption', () {
      final a = _machine('mid', 'A', 30);
      final b = _machine('high', 'B', 24);
      final c = _machine('low', 'C', 24);

      a.recordCapture(1);
      b.recordCapture(2);
      c.recordCapture(3);
      a.recordCapture(1); // overfill A@1
      b.removeCapture(2); // back to empty B@2
      c.recordCapture(4);

      expect(a.fillCounts[1], 2);
      expect(a.filledCount, 1);
      expect(b.filledCount, 0); // 2 was removed
      expect(c.filledCount, 2); // 3 and 4
      expect(c.missingSegments.contains(3), isFalse);
      expect(c.missingSegments.contains(4), isFalse);
    });
  });

  group('per-level yawStart re-baselining + wraparound', () {
    test('each level baselines its own start heading independently', () {
      final b = _machine('high', 'B', 24);
      final c = _machine('low', 'C', 24);
      expect(b.started, isFalse);
      expect(b.yawStart, isNull);

      b.begin(100); // B orbits from heading 100°
      c.begin(250); // C orbits from a different heading
      expect(b.yawStart, 100);
      expect(c.yawStart, 250);

      // Same raw yaw maps to DIFFERENT segments under different baselines.
      // size = 360/24 = 15°.
      b.updateYaw(115); // 15° past B's start → segment 1
      c.updateYaw(115); // (115-250) normalized = 225° → 225/15 = segment 15
      expect(b.currentSegment, 1);
      expect(c.currentSegment, 15);
    });

    test('wraparound is correct per level (crossing 360→0)', () {
      final m = _machine('mid', 'A', 12); // size = 30°
      m.begin(350);
      m.updateYaw(20); // (20-350) normalized = 30° → segment 1
      expect(m.currentSegment, 1);
      m.updateYaw(345); // (345-350) normalized = 355° → segment 11
      expect(m.currentSegment, 11);
    });

    test('re-begin re-baselines without clearing fill', () {
      final m = _machine('high', 'B', 24);
      m.begin(0);
      m.updateYaw(0);
      m.recordCaptureHere(); // fill segment 0
      expect(m.filledCount, 1);

      m.begin(180); // new heading; fill preserved, origin moved
      expect(m.yawStart, 180);
      expect(m.filledCount, 1);
      expect(m.currentSegment, 0); // position reset by start()
    });

    test('updateYaw before begin is ignored (returns null)', () {
      final m = _machine('low', 'C', 24);
      expect(m.updateYaw(42), isNull);
      expect(m.currentSegment, 0);
    });
  });

  group('overlap eval against the fill source of truth', () {
    test('current segment empty → proceed; filled → reject', () {
      final m = _machine('mid', 'A', 12);
      m.begin(0);
      m.updateYaw(0); // segment 0
      expect(m.evaluateCapture(), const ProceedCapture(0));

      m.recordCaptureHere();
      expect(m.evaluateCapture(), const RejectAlreadyFilled(0));

      m.updateYaw(30); // move to segment 1 (empty)
      expect(m.evaluateCapture(), const ProceedCapture(1));
    });

    test('removeCapture frees a segment and reports it missing', () {
      final m = _machine('high', 'B', 24);
      m.recordCapture(7);
      expect(m.isFilledAt(7), isTrue);
      final nowMissing = m.removeCapture(7);
      expect(nowMissing, isTrue);
      expect(m.isFilledAt(7), isFalse);
    });

    test('currentTarget tracks nearest missing from position', () {
      final m = _machine('mid', 'A', 12);
      m.begin(0);
      m.updateYaw(0);
      // fill all but segment 6
      for (var i = 0; i < 12; i++) {
        if (i != 6) m.recordCapture(i);
      }
      expect(m.currentTarget, 6);
      expect(m.isComplete, isFalse);
      m.recordCapture(6);
      expect(m.currentTarget, isNull);
      expect(m.isComplete, isTrue);
    });
  });

  group('resume restore (independent per level)', () {
    test('restore installs saved coverage + re-baselines yawStart', () {
      final saved = SegmentCoverage.initial(segmentCount: 24)
          .recordCapture(3)
          .recordCapture(8);
      final m = _machine('high', 'B', 24);
      m.restore(saved, yawStart: 90);

      expect(m.filledCount, 2);
      expect(m.isFilledAt(3), isTrue);
      expect(m.isFilledAt(8), isTrue);
      expect(m.yawStart, 90);
    });

    test('restore with mismatched N reconfigures to this level shape', () {
      final saved = SegmentCoverage.initial(segmentCount: 30).recordCapture(29);
      final m = _machine('high', 'B', 24);
      m.restore(saved);
      expect(m.coverage.segmentCount, 24); // reshaped, stale index dropped
    });

    test('two levels restore independently — no bleed', () {
      final b = _machine('high', 'B', 24)
        ..restore(SegmentCoverage.initial(segmentCount: 24).recordCapture(1));
      final c = _machine('low', 'C', 24)
        ..restore(SegmentCoverage.initial(segmentCount: 24).recordCapture(20));
      expect(b.isFilledAt(1), isTrue);
      expect(b.isFilledAt(20), isFalse);
      expect(c.isFilledAt(20), isTrue);
      expect(c.isFilledAt(1), isFalse);
    });
  });

  group('same engine — no per-level fork', () {
    test('A/B/C are the same class (no subclass per level)', () {
      final a = _machine('mid', 'A', 30);
      final b = _machine('high', 'B', 24);
      final c = _machine('low', 'C', 24);
      expect(a.runtimeType, LevelSegmentMachine);
      expect(b.runtimeType, LevelSegmentMachine);
      expect(c.runtimeType, LevelSegmentMachine);
      expect(b.runtimeType, a.runtimeType);
      expect(c.runtimeType, a.runtimeType);
    });

    test('reset clears fill and baseline', () {
      final m = _machine('mid', 'A', 12);
      m.begin(45);
      m.recordCapture(0);
      m.reset();
      expect(m.filledCount, 0);
      expect(m.started, isFalse);
      expect(m.lastTurn, RingTurn.idle);
    });
  });

  group('factory from config (per-level counts via effectiveSegmentsFor)', () {
    test('with_bottom builds A/B/C at the variant counts (12-12-12)', () {
      final machines = levelSegmentMachinesFromConfig(
        CaptureConfig.bundledDefault,
        variant: CaptureFlowVariant.withBottom,
      );
      expect(machines.length, 3);

      final byCode = {for (final m in machines) m.levelCode: m};
      // Variant bundled defaults win over the legacy band counts (10/8/12).
      expect(byCode['A']!.levelId, 'mid');
      expect(byCode['A']!.segmentCount, 12);
      expect(byCode['B']!.levelId, 'high');
      expect(byCode['B']!.segmentCount, 12);
      expect(byCode['C']!.levelId, 'low');
      expect(byCode['C']!.segmentCount, 12);
    });

    test('without_bottom builds A/B only at 18-18 (no Level C machine)', () {
      final machines = levelSegmentMachinesFromConfig(
        CaptureConfig.bundledDefault,
        variant: CaptureFlowVariant.withoutBottom,
      );
      expect(machines.length, 2);
      expect(machines[0].levelId, 'mid');
      expect(machines[0].segmentCount, 18);
      expect(machines[1].levelId, 'high');
      expect(machines[1].segmentCount, 18);
    });

    test('machines from config are independent instances', () {
      final machines = levelSegmentMachinesFromConfig(
        CaptureConfig.bundledDefault,
        variant: CaptureFlowVariant.withBottom,
      );
      machines[1].recordCapture(0); // fill B@0
      expect(machines[0].filledCount, 0);
      expect(machines[2].filledCount, 0);
      expect(machines[1].filledCount, 1);
    });

    test('levelSegmentMachineFor resolves a single level', () {
      final c = levelSegmentMachineFor(
        CaptureLevel.c,
        CaptureConfig.bundledDefault,
        variant: CaptureFlowVariant.withBottom,
      );
      expect(c.levelId, 'low');
      expect(c.levelCode, 'C');
      expect(c.segmentCount, 12);
    });

    test('missing band falls back to the first band shell; the count still '
        'comes from the variant defaults (never an empty ring)', () {
      const cfg = CaptureConfig(
        version: 1,
        pitchBands: [
          PitchBand(id: 'mid', minDegrees: 30, maxDegrees: 60, segments: 9),
        ],
        thresholds: CaptureThresholds(
          minSharpness: 0.45,
          minCoveragePct: 80,
          maxTiltDeltaDeg: 12,
        ),
      );
      // 'high' band absent → the band SHELL falls back to the only band, but
      // the segment count resolves through the variant defaults (high=12).
      final b = levelSegmentMachineFor(
        CaptureLevel.b,
        cfg,
        variant: CaptureFlowVariant.withBottom,
      );
      expect(b.band.id, 'mid'); // fell back to the only band
      expect(b.segmentCount, 12); // variant bundled default for 'high'
    });
  });
}
