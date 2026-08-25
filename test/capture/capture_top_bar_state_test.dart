// test/capture/capture_top_bar_state_test.dart
//
// Pure unit tests for the top-bar model: defaults, copyWith, and value equality.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/capture_top_bar_state.dart';

void main() {
  test('defaults: help/settings enabled, no subtitle', () {
    const s = CaptureTopBarState(levelLabel: 'Level A');
    expect(s.levelSubtitle, isNull);
    expect(s.helpEnabled, isTrue);
    expect(s.settingsEnabled, isTrue);
  });

  test('copyWith overrides only the named fields', () {
    const s = CaptureTopBarState(
      levelLabel: 'Level A',
      levelSubtitle: 'Eye Ring',
    );
    final t = s.copyWith(settingsEnabled: false);
    expect(t.levelLabel, 'Level A');
    expect(t.levelSubtitle, 'Eye Ring');
    expect(t.helpEnabled, isTrue);
    expect(t.settingsEnabled, isFalse);
  });

  test('value equality', () {
    const a = CaptureTopBarState(levelLabel: 'Level A', levelSubtitle: 'Eye Ring');
    const b = CaptureTopBarState(levelLabel: 'Level A', levelSubtitle: 'Eye Ring');
    const c = CaptureTopBarState(levelLabel: 'Level B', levelSubtitle: 'Eye Ring');
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(c));
  });
}
