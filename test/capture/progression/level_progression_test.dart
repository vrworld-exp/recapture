// test/capture/progression/level_progression_test.dart
//
// The PURE progression core: ordered A→B→C sequence, no-forward-skip advance gated
// on the current level's completion, backward review access, overall completion,
// and the un-complete edge — all without Hive/Flutter. Also covers the config
// builder + reconciliation.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/ledger/captured_photo_record.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry.dart';
import 'package:recapture/application/capture/progression/level_progression.dart';
import 'package:recapture/application/capture/progression/level_progression_builder.dart';
import 'package:recapture/domain/capture/capture_flow_variant.dart';
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
    test('with_bottom builds A→B→C at the variant counts (not hardcoded)', () {
      final levels = levelStatesFromConfig(
        CaptureConfig.bundledDefault,
        variant: CaptureFlowVariant.withBottom,
      );
      expect(levels.map((l) => l.levelCode).toList(), ['A', 'B', 'C']);
      // pitchBandIdForLevel: A=mid, B=high, C=low.
      expect(levels.map((l) => l.levelId).toList(), ['mid', 'high', 'low']);
      // Segment counts come from the variant defaults (16-16-16), which win
      // over the legacy band counts (10/8/12).
      expect(levels.map((l) => l.segmentCount).toList(), [16, 16, 16]);
    });

    test('without_bottom builds A→B only at 24-24 (Level C dropped)', () {
      final levels = levelStatesFromConfig(
        CaptureConfig.bundledDefault,
        variant: CaptureFlowVariant.withoutBottom,
      );
      expect(levels.map((l) => l.levelCode).toList(), ['A', 'B']);
      expect(levels.map((l) => l.levelId).toList(), ['mid', 'high']);
      expect(levels.map((l) => l.segmentCount).toList(), [24, 24]);
    });

    test('reconcile carries progress, adopts new segment count, clamps frontier',
        () {
      // Persisted: at B (index 1), A complete with the old counts.
      final persisted = LevelProgression.of([
        _level('mid', 'A', n: 12, complete: true),
        _level('high', 'B', n: 12),
        _level('low', 'C', n: 12),
      ], currentLevelIndex: 1);

      // A remote override SHRINKS with_bottom 'mid' to 5 segments.
      final newConfig = CaptureConfig.bundledDefault.copyWith(
        variantSegments: VariantSegments.fromMap(const {
          'with_bottom': {'mid': 5, 'high': 12, 'low': 12},
        }),
      );

      final r = reconcileWithConfig(
        persisted,
        newConfig,
        variant: CaptureFlowVariant.withBottom,
      );
      expect(r.currentLevel.levelId, 'high'); // frontier kept by id
      final a = r.stateForId('mid')!;
      expect(a.segmentCount, 5); // new shape
      expect(a.filledCount, 5); // 12 carried-over filled clamped to 5
      expect(a.acceptedCount, 12); // accepted carried over
    });

    test('reconcile onto without_bottom drops Level C and resizes A/B', () {
      // Persisted 3-ring session with progress on every ring.
      final persisted = LevelProgression.of([
        _level('mid', 'A', n: 12, complete: true),
        _level('high', 'B', n: 12),
        _level('low', 'C', n: 12),
      ], currentLevelIndex: 1);

      final r = reconcileWithConfig(
        persisted,
        CaptureConfig.bundledDefault,
        variant: CaptureFlowVariant.withoutBottom,
      );
      // C simply disappears; A/B carry progress at the 24-segment shape.
      expect(r.levels.map((l) => l.levelId).toList(), ['mid', 'high']);
      expect(r.levels.map((l) => l.segmentCount).toList(), [24, 24]);
      expect(r.currentLevel.levelId, 'high'); // frontier kept by id
      expect(r.stateForId('mid')!.acceptedCount, 12); // progress carried
      expect(r.stateForId('low'), isNull);
    });

    test('reconcile carries fired milestones still satisfied by coverage', () {
      // Persisted Level B: full (12/12) coverage, all milestones fired.
      final persisted = LevelProgression.of([
        _level('mid', 'A', complete: true),
        const LevelProgressState(
            levelId: 'high',
            levelCode: 'B',
            segmentCount: 12,
            filledCount: 12,
            acceptedCount: 12,
            firedMilestones: {25, 50, 75, 100}),
        _level('low', 'C', n: 12),
      ], currentLevelIndex: 1);

      // A remote override GROWS with_bottom 'high' to 24 segments → 12/24 = 50%,
      // so only 25 & 50 are still satisfied; 75 & 100 become eligible again.
      final newConfig = CaptureConfig.bundledDefault.copyWith(
        variantSegments: VariantSegments.fromMap(const {
          'with_bottom': {'mid': 12, 'high': 24, 'low': 12},
        }),
      );

      final b = reconcileWithConfig(
        persisted,
        newConfig,
        variant: CaptureFlowVariant.withBottom,
      ).stateForId('high')!;
      expect(b.segmentCount, 24);
      expect(b.firedMilestones, {25, 50});
    });
  });

  group('progressionFromLedger (upload snapshot)', () {
    CapturedPhotoRecord rec(int? segment, String path) => CapturedPhotoRecord(
          segmentIndex: segment,
          framePath: path,
          blurScore: 120,
          meanLuminance: 128,
          yawDegrees: 0,
          pitchDegrees: 0,
          sensorTimestampNs: 1,
        );

    test('derives per-level accepted + filled counts from the ledgers', () {
      final registry = LevelCaptureLedgerRegistry();
      // mid: full ring (16 distinct segments) → complete.
      for (var i = 0; i < 16; i++) {
        registry.ledgerFor('mid').recordAccepted(rec(i, 'mid/$i.jpg'));
      }
      // high: 3 accepted but only 2 distinct segments → filled < accepted.
      registry.ledgerFor('high')
        ..recordAccepted(rec(0, 'high/0.jpg'))
        ..recordAccepted(rec(0, 'high/0b.jpg'))
        ..recordAccepted(rec(5, 'high/5.jpg'));
      // low: never touched (lazily-created empty ledger).

      final p = progressionFromLedger(
        CaptureConfig.bundledDefault,
        variant: CaptureFlowVariant.withBottom,
        registry: registry,
      );

      expect(p.levels.map((l) => l.levelId).toList(), ['mid', 'high', 'low']);
      final mid = p.stateForId('mid')!;
      expect(mid.acceptedCount, 16);
      expect(mid.filledCount, 16);
      expect(mid.isComplete, isTrue);
      final high = p.stateForId('high')!;
      expect(high.acceptedCount, 3);
      expect(high.filledCount, 2);
      expect(high.isComplete, isFalse);
      final low = p.stateForId('low')!;
      expect(low.acceptedCount, 0);
      expect(low.filledCount, 0);
      expect(p.overallComplete, isFalse);
    });

    test('null / out-of-range segment indices count as accepted, not filled',
        () {
      final registry = LevelCaptureLedgerRegistry();
      registry.ledgerFor('mid')
        ..recordAccepted(rec(null, 'a.jpg')) // no segment tracking
        ..recordAccepted(rec(-1, 'b.jpg')) // defensive: below range
        ..recordAccepted(rec(99, 'c.jpg')) // defensive: beyond segmentCount
        ..recordAccepted(rec(3, 'd.jpg'));

      final mid = progressionFromLedger(
        CaptureConfig.bundledDefault,
        variant: CaptureFlowVariant.withBottom,
        registry: registry,
      ).stateForId('mid')!;
      expect(mid.acceptedCount, 4);
      expect(mid.filledCount, 1); // only segment 3
    });

    test('per-level min-accepted comes from completionThresholds by code', () {
      final registry = LevelCaptureLedgerRegistry();
      // Full coverage on 'high' (Level B)…
      for (var i = 0; i < 12; i++) {
        registry.ledgerFor('high').recordAccepted(rec(i, 'high/$i.jpg'));
      }
      // …but a remote override demands 20 accepted frames for B.
      final config = CaptureConfig.bundledDefault.copyWith(
        completionThresholds: CompletionThresholds.fromMap(const {
          'B': {'minAcceptedFrames': 20},
        }),
      );

      final high = progressionFromLedger(
        config,
        variant: CaptureFlowVariant.withBottom,
        registry: registry,
      ).stateForId('high')!;
      expect(high.minAcceptedCount, 20);
      expect(high.isComplete, isFalse); // coverage passes, count gate fails
    });

    test('without_bottom derives A/B only at the variant shape (24-24)', () {
      final p = progressionFromLedger(
        CaptureConfig.bundledDefault,
        variant: CaptureFlowVariant.withoutBottom,
        registry: LevelCaptureLedgerRegistry(),
      );
      expect(p.levels.map((l) => l.levelId).toList(), ['mid', 'high']);
      expect(p.levels.map((l) => l.segmentCount).toList(), [24, 24]);
    });
  });
}
