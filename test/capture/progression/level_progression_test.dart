// test/capture/progression/level_progression_test.dart
//
// The PURE progression core: ordered A→B→C sequence, no-forward-skip advance gated
// on the current level's completion, backward review access, overall completion,
// and the un-complete edge — all without Hive/Flutter. Also covers the config
// builder + reconciliation.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/progression/level_progression.dart';
import 'package:recapture/application/capture/progression/level_progression_builder.dart';
import 'package:recapture/domain/entities/capture_config.dart';

/// A level state with [n] segments; [complete] fills it to the 80% gate (+accepted).
LevelProgressState _level(String id, String code, {int n = 10, bool complete = false}) =>
    LevelProgressState(
      levelId: id,
      levelCode: code,
      segmentCount: n,
      filledCount: complete ? n : 0,
      acceptedCount: complete ? n : 0,
    );

LevelProgression _abc({bool a = false, bool b = false, bool c = false}) =>
    LevelProgression.of([
      _level('mid', 'A', complete: a),
      _level('high', 'B', complete: b),
      _level('low', 'C', complete: c),
    ]);

void main() {
  group('sequence + no-skip advance', () {
    test('incomplete current level → canAdvance false, advance is a no-op', () {
      final p = _abc();
      expect(p.currentLevelIndex, 0);
      expect(p.currentLevel.levelCode, 'A');
      expect(p.canAdvance, isFalse);
      expect(identical(p.advance(), p), isTrue); // rejected, frontier unchanged
    });

    test('completing the current level allows a single-step advance', () {
      final p = _abc(a: true).advance();
      expect(p.currentLevelIndex, 1);
      expect(p.currentLevel.levelCode, 'B');
      // A's state is preserved across the advance.
      expect(p.stateForId('mid')!.isComplete, isTrue);
    });

    test('cannot skip an incomplete level (B) to reach C', () {
      // At B, B incomplete → advance rejected (no jump to C).
      final atB = _abc(a: true).advance();
      expect(atB.currentLevel.levelCode, 'B');
      expect(atB.canAdvance, isFalse);
      expect(atB.advance().currentLevelIndex, 1); // still B
    });

    test('advancing the last complete level is a no-op (session finishes)', () {
      final atC = _abc(a: true, b: true, c: true).advance().advance();
      expect(atC.currentLevel.levelCode, 'C');
      expect(atC.isLastLevel, isTrue);
      expect(atC.canAdvance, isTrue); // C is complete...
      expect(identical(atC.advance(), atC), isTrue); // ...but there is no next
    });
  });

  group('overall completion + un-complete edge', () {
    test('overallComplete only when every level is complete', () {
      expect(_abc(a: true, b: true).overallComplete, isFalse);
      expect(_abc(a: true, b: true, c: true).overallComplete, isTrue);
    });

    test('review un-completing a PRIOR level flips overallComplete; frontier holds',
        () {
      // At C, all complete.
      var p = _abc(a: true, b: true, c: true).advance().advance();
      expect(p.currentLevelIndex, 2);
      expect(p.overallComplete, isTrue);

      // A delete drops B below the gate.
      p = p.updateLevel('high', filledCount: 0, acceptedCount: 0);
      expect(p.overallComplete, isFalse);
      expect(p.currentLevelIndex, 2); // frontier NOT regressed
      expect(p.firstIncompleteIndex, 1); // guide the user back to B
    });
  });

  group('backward review access', () {
    test('any reached level may be reviewed; beyond the frontier may not', () {
      final atC = _abc(a: true, b: true, c: true).advance().advance();
      expect(atC.canReview(0), isTrue);
      expect(atC.canReview(2), isTrue);
      expect(atC.canReviewId('mid'), isTrue);
      expect(atC.canReviewId('high'), isTrue);

      // From B, C is beyond the frontier → not reviewable (no forward skip).
      final atB = _abc(a: true).advance();
      expect(atB.canReview(2), isFalse);
      expect(atB.canReviewId('low'), isFalse);
    });
  });

  group('degenerate + defensive', () {
    test('single-level progression: first is also last, finishes on completion',
        () {
      final solo = LevelProgression.of([_level('mid', 'A', complete: true)]);
      expect(solo.isLastLevel, isTrue);
      expect(solo.overallComplete, isTrue);
      expect(identical(solo.advance(), solo), isTrue);
    });

    test('out-of-range current index is clamped, never throws', () {
      final p = LevelProgression.of([_level('mid', 'A')], currentLevelIndex: 99);
      expect(p.currentLevelIndex, 0);
    });

    test('updateLevel on an unknown id is a no-op', () {
      final p = _abc();
      expect(p.updateLevel('nope', filledCount: 5), p);
    });
  });

  group('config builder + reconciliation', () {
    test('builds A→B→C from config bands (not hardcoded)', () {
      final levels = levelStatesFromConfig(CaptureConfig.bundledDefault);
      expect(levels.map((l) => l.levelCode).toList(), ['A', 'B', 'C']);
      // pitchBandIdForLevel: A=mid, B=high, C=low.
      expect(levels.map((l) => l.levelId).toList(), ['mid', 'high', 'low']);
      // Segment counts come from the bands (bundled: mid=10, high=8, low=12).
      expect(levels[0].segmentCount, 10);
      expect(levels[1].segmentCount, 8);
      expect(levels[2].segmentCount, 12);
    });

    test('reconcile carries progress, adopts new segment count, clamps frontier',
        () {
      // Persisted: at B (index 1), A complete with old counts.
      final persisted = LevelProgression.of([
        _level('mid', 'A', n: 10, complete: true),
        _level('high', 'B', n: 8),
        _level('low', 'C', n: 12),
      ], currentLevelIndex: 1);

      // New config shrinks 'mid' to 5 segments.
      final newConfig = CaptureConfig.bundledDefault.copyWith(pitchBands: const [
        PitchBand(id: 'low', minDegrees: 0, maxDegrees: 30, segments: 12),
        PitchBand(id: 'mid', minDegrees: 30, maxDegrees: 60, segments: 5),
        PitchBand(id: 'high', minDegrees: 60, maxDegrees: 90, segments: 8),
      ]);

      final r = reconcileWithConfig(persisted, newConfig);
      expect(r.currentLevel.levelId, 'high'); // frontier kept by id
      final a = r.stateForId('mid')!;
      expect(a.segmentCount, 5); // new shape
      expect(a.filledCount, 5); // 10 carried-over filled clamped to 5
      expect(a.acceptedCount, 10); // accepted carried over
    });

    test('reconcile carries fired milestones still satisfied by coverage', () {
      // Persisted Level B: full (8/8) coverage, all milestones fired.
      final persisted = LevelProgression.of([
        _level('mid', 'A', complete: true),
        const LevelProgressState(
            levelId: 'high',
            levelCode: 'B',
            segmentCount: 8,
            filledCount: 8,
            acceptedCount: 8,
            firedMilestones: {25, 50, 75, 100}),
        _level('low', 'C', n: 12),
      ], currentLevelIndex: 1);

      // New config GROWS 'high' to 16 segments → 8/16 = 50%, so only 25 & 50 are
      // still satisfied; 75 & 100 become eligible to fire again.
      final newConfig = CaptureConfig.bundledDefault.copyWith(pitchBands: const [
        PitchBand(id: 'mid', minDegrees: 30, maxDegrees: 60, segments: 10),
        PitchBand(id: 'high', minDegrees: 60, maxDegrees: 90, segments: 16),
        PitchBand(id: 'low', minDegrees: 0, maxDegrees: 30, segments: 12),
      ]);

      final b = reconcileWithConfig(persisted, newConfig).stateForId('high')!;
      expect(b.segmentCount, 16);
      expect(b.firedMilestones, {25, 50});
    });
  });
}
