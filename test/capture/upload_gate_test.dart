// test/capture/upload_gate_test.dart
//
// The pure hard upload gate: eligible iff EVERY configured level meets its
// absolute-minimum accepted shots AND its ring-coverage floor (both inclusive);
// short levels + per-level deficit + summed deficit reported for the
// disabled-state messaging/analytics; empty input fails safe (NOT eligible).
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/capture/upload_gate.dart';

UploadLevelStatus _s(String code, int accepted, int required) =>
    UploadLevelStatus(levelCode: code, accepted: accepted, required: required);

UploadLevelStatus _c(String code, int accepted, int required,
        {required int filled, required int requiredFilled}) =>
    UploadLevelStatus(
      levelCode: code,
      accepted: accepted,
      required: required,
      filled: filled,
      requiredFilled: requiredFilled,
    );

void main() {
  test('eligible when every level meets its minimum (inclusive at exactly min)',
      () {
    final gate = evaluateUploadGate([_s('A', 5, 3), _s('B', 2, 2), _s('C', 9, 4)]);
    expect(gate.eligible, isTrue);
    expect(gate.shortLevels, isEmpty);
    expect(gate.totalDeficit, 0);
    expect(gate.shortLevelsLabel, '');
  });

  test('one level short → not eligible, names it + deficit', () {
    final gate = evaluateUploadGate([_s('A', 5, 3), _s('B', 0, 2), _s('C', 9, 4)]);
    expect(gate.eligible, isFalse);
    expect(gate.shortLevels.map((l) => l.levelCode).toList(), ['B']);
    expect(gate.shortLevels.single.deficit, 2);
    expect(gate.shortLevelsLabel, 'B');
    expect(gate.totalDeficit, 2);
  });

  test('multiple short → all listed in order, total_deficit is the sum', () {
    final gate = evaluateUploadGate([_s('A', 0, 3), _s('B', 1, 2), _s('C', 9, 4)]);
    expect(gate.shortLevelsLabel, 'A,B');
    expect(gate.totalDeficit, 3 + 1); // A short 3, B short 1
  });

  test('empty input fails safe — NOT eligible', () {
    final gate = evaluateUploadGate([]);
    expect(gate.eligible, isFalse);
    expect(gate.totalDeficit, 0);
  });

  test('deficit is 0 and meetsMinimum true at/above the floor', () {
    expect(_s('A', 2, 2).meetsMinimum, isTrue);
    expect(_s('A', 2, 2).deficit, 0);
    expect(_s('A', 3, 2).meetsMinimum, isTrue);
    expect(_s('A', 1, 2).meetsMinimum, isFalse);
    expect(_s('A', 1, 2).deficit, 1);
  });

  group('ring-coverage floor', () {
    test('shots met but coverage short → NOT eligible; deficit = segments short',
        () {
      // 15 accepted but only 12 distinct segments against a floor of 15 —
      // the exact shape that used to 400 at POST /jobs.
      final l = _c('A', 15, 1, filled: 12, requiredFilled: 15);
      expect(l.meetsMinimum, isFalse);
      expect(l.shotsShort, 0);
      expect(l.segmentsShort, 3);
      expect(l.deficit, 3);
      expect(evaluateUploadGate([l]).eligible, isFalse);
    });

    test('coverage met exactly at the floor passes (inclusive)', () {
      final l = _c('A', 15, 1, filled: 15, requiredFilled: 15);
      expect(l.meetsMinimum, isTrue);
      expect(l.deficit, 0);
    });

    test('both floors short → deficit is the LARGER shortfall', () {
      // 2 shots against a floor of 6, 2 segments against a floor of 15:
      // one new shot fills at most one new segment, so 13 more are needed.
      final l = _c('A', 2, 6, filled: 2, requiredFilled: 15);
      expect(l.shotsShort, 4);
      expect(l.segmentsShort, 13);
      expect(l.deficit, 13);
    });

    test('requiredFilled 0 (legacy caller) enforces no coverage', () {
      expect(_s('A', 1, 1).meetsMinimum, isTrue); // filled defaults to 0
    });

    test('a coverage-short level is listed among shortLevels', () {
      final gate = evaluateUploadGate([
        _c('A', 12, 1, filled: 12, requiredFilled: 10),
        _c('B', 16, 1, filled: 9, requiredFilled: 10),
      ]);
      expect(gate.eligible, isFalse);
      expect(gate.shortLevelsLabel, 'B');
      expect(gate.totalDeficit, 1);
    });
  });
}
