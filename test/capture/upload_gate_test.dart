// test/capture/upload_gate_test.dart
//
// The pure hard upload gate: eligible iff EVERY configured level meets its
// absolute-minimum accepted shots (inclusive); short levels + per-level deficit +
// summed deficit reported for the disabled-state messaging/analytics; empty input
// fails safe (NOT eligible).
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/capture/upload_gate.dart';

UploadLevelStatus _s(String code, int accepted, int required) =>
    UploadLevelStatus(levelCode: code, accepted: accepted, required: required);

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
}
