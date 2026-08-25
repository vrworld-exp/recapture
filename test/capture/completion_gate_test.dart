// test/capture/completion_gate_test.dart
//
// The pure final-completion gate: a level is complete when accepted >= its
// threshold; unlocked iff EVERY configured level is complete; locked (fail safe)
// on empty input; incomplete codes reported for the blocked analytics; an
// arbitrary level count (not a hardcoded 3) is honoured. Plus the config-driven
// CompletionThresholds parsing/validation. No Flutter.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/capture/completion_gate.dart';
import 'package:recapture/domain/entities/capture_config.dart';

LevelCompletionStatus _s(String code, int accepted, {int min = 1}) =>
    LevelCompletionStatus(
      levelCode: code,
      acceptedCount: accepted,
      minAcceptedFrames: min,
    );

void main() {
  group('SummaryGate', () {
    test('unlocked iff every level meets its threshold', () {
      expect(
        evaluateSummaryGate([_s('A', 3), _s('B', 1), _s('C', 2)]).isUnlocked,
        isTrue,
      );
      final locked = evaluateSummaryGate([_s('A', 3), _s('B', 1), _s('C', 0)]);
      expect(locked.isUnlocked, isFalse);
      expect(locked.areAllLevelsComplete, isFalse);
    });

    test('empty input is locked (fail safe)', () {
      final gate = evaluateSummaryGate([]);
      expect(gate.isUnlocked, isFalse);
      expect(gate.levelsTotal, 0);
    });

    test('per-level threshold respected (count below min → incomplete)', () {
      final gate = evaluateSummaryGate([_s('A', 2, min: 3), _s('B', 3, min: 3)]);
      expect(gate.isLevelComplete('A'), isFalse);
      expect(gate.isLevelComplete('B'), isTrue);
      expect(gate.isUnlocked, isFalse);
    });

    test('incomplete codes + label report the remaining levels in order', () {
      final gate = evaluateSummaryGate([_s('A', 1), _s('B', 0), _s('C', 0)]);
      expect(gate.incompleteLevelCodes, ['B', 'C']);
      expect(gate.incompleteLevelsLabel, 'B,C');
      expect(gate.levelsComplete, 1);
      expect(gate.levelsTotal, 3);
    });

    test('unknown level code is not complete (fail safe)', () {
      expect(evaluateSummaryGate([_s('A', 5)]).isLevelComplete('Z'), isFalse);
    });

    test('honours an arbitrary configured level count (not a fixed 3)', () {
      final four =
          evaluateSummaryGate([_s('A', 1), _s('B', 1), _s('C', 1), _s('D', 1)]);
      expect(four.levelsTotal, 4);
      expect(four.isUnlocked, isTrue);

      final two = evaluateSummaryGate([_s('A', 1), _s('B', 0)]);
      expect(two.levelsTotal, 2);
      expect(two.incompleteLevelCodes, ['B']);
    });

    test('regression: a complete level dropping below threshold re-locks', () {
      var gate = evaluateSummaryGate([_s('A', 1), _s('B', 1), _s('C', 1)]);
      expect(gate.isUnlocked, isTrue);
      // C's frames deleted → back under threshold.
      gate = evaluateSummaryGate([_s('A', 1), _s('B', 1), _s('C', 0)]);
      expect(gate.isUnlocked, isFalse);
      expect(gate.incompleteLevelCodes, ['C']);
    });
  });

  group('CompletionThresholds (config-driven, validated)', () {
    test('absent config → default (1) for every level', () {
      const t = CompletionThresholds.bundledDefault;
      expect(t.minAcceptedFramesFor('A'), 1);
      expect(t.minAcceptedFramesFor('C'), 1);
    });

    test('valid per-level values parsed; case-insensitive lookup', () {
      final t = CompletionThresholds.fromMap({
        'A': {'minAcceptedFrames': 5},
        'B': {'minAcceptedFrames': 3},
      });
      expect(t.minAcceptedFramesFor('a'), 5);
      expect(t.minAcceptedFramesFor('B'), 3);
      expect(t.minAcceptedFramesFor('C'), 1); // absent → default
    });

    test('invalid entries fall back to the default', () {
      final t = CompletionThresholds.fromMap({
        'A': {'minAcceptedFrames': 0}, // non-positive
        'B': {'minAcceptedFrames': -4}, // negative
        'C': {'minAcceptedFrames': 'lots'}, // ill-typed
        'D': 'nope', // not a map
      });
      expect(t.minAcceptedFramesFor('A'), 1);
      expect(t.minAcceptedFramesFor('B'), 1);
      expect(t.minAcceptedFramesFor('C'), 1);
      expect(t.minAcceptedFramesFor('D'), 1);
    });

    test('non-map raw → all defaults', () {
      expect(CompletionThresholds.fromMap(null).minAcceptedFramesFor('A'), 1);
      expect(CompletionThresholds.fromMap(42).minAcceptedFramesFor('A'), 1);
    });

    test('round-trips through CaptureConfig.fromMap', () {
      final cfg = CaptureConfig.fromMap({
        'version': 1,
        'guided_capture_completion_thresholds': {
          'A': {'minAcceptedFrames': 4},
        },
      });
      expect(cfg.completionThresholds.minAcceptedFramesFor('A'), 4);
      expect(cfg.completionThresholds.minAcceptedFramesFor('B'), 1);
    });
  });
}
