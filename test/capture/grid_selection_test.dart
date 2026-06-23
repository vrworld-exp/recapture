// test/capture/grid_selection_test.dart
//
// Unit tests for the platform-agnostic multi-select controller. No widgets, no
// platform — pure logic, keyed by id, with the deselect-last divergence driven by
// the autoExitWhenEmpty flag the widget layer supplies.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/grid_selection.dart';

void main() {
  late GridSelection s;
  var notifications = 0;
  setUp(() {
    s = GridSelection()..addListener(() => notifications++);
    notifications = 0;
  });
  tearDown(() => s.dispose());

  test('starts empty, not in selection mode', () {
    expect(s.isSelectionMode, isFalse);
    expect(s.count, 0);
    expect(s.selectedIds, isEmpty);
    expect(s.isSelected('a'), isFalse);
  });

  test('enterSelection turns on mode and selects the initial id', () {
    s.enterSelection('a');
    expect(s.isSelectionMode, isTrue);
    expect(s.selectedIds, {'a'});
    expect(s.count, 1);
    expect(notifications, 1);
  });

  test('enterSelection with no id enters mode with empty selection', () {
    s.enterSelection();
    expect(s.isSelectionMode, isTrue);
    expect(s.count, 0);
  });

  test('toggle adds then removes, keyed by id', () {
    s.enterSelection();
    s.toggle('a');
    s.toggle('b');
    expect(s.selectedIds, {'a', 'b'});
    s.toggle('a');
    expect(s.selectedIds, {'b'});
    expect(s.isSelected('a'), isFalse);
  });

  test('toggle on a fresh controller turns selection mode on', () {
    s.toggle('a');
    expect(s.isSelectionMode, isTrue);
    expect(s.selectedIds, {'a'});
  });

  test('deselect-last with autoExitWhenEmpty=true exits (Android)', () {
    s.enterSelection('a');
    s.toggle('a', autoExitWhenEmpty: true); // removes last
    expect(s.count, 0);
    expect(s.isSelectionMode, isFalse);
  });

  test('deselect-last with autoExitWhenEmpty=false stays (iOS)', () {
    s.enterSelection('a');
    s.toggle('a', autoExitWhenEmpty: false); // removes last
    expect(s.count, 0);
    expect(s.isSelectionMode, isTrue);
  });

  test('selectAll adds all ids and enters mode', () {
    s.selectAll(['a', 'b', 'c']);
    expect(s.isSelectionMode, isTrue);
    expect(s.selectedIds, {'a', 'b', 'c'});
    expect(s.count, 3);
  });

  test('clear empties selection but stays in mode by default', () {
    s.selectAll(['a', 'b']);
    s.clear();
    expect(s.count, 0);
    expect(s.isSelectionMode, isTrue);
  });

  test('clear with autoExitWhenEmpty exits mode', () {
    s.selectAll(['a', 'b']);
    s.clear(autoExitWhenEmpty: true);
    expect(s.count, 0);
    expect(s.isSelectionMode, isFalse);
  });

  test('exitSelection clears selection and turns off mode', () {
    s.selectAll(['a', 'b']);
    s.exitSelection();
    expect(s.count, 0);
    expect(s.isSelectionMode, isFalse);
  });

  test('retain drops ids no longer present', () {
    s.selectAll(['a', 'b', 'c']);
    s.retain({'a', 'c'}); // 'b' was deleted
    expect(s.selectedIds, {'a', 'c'});
  });

  test('retain to empty with autoExit exits (Android)', () {
    s.selectAll(['a', 'b']);
    s.retain({'z'}, autoExitWhenEmpty: true); // all deleted
    expect(s.count, 0);
    expect(s.isSelectionMode, isFalse);
  });

  test('retain to empty without autoExit stays (iOS)', () {
    s.selectAll(['a', 'b']);
    s.retain({'z'}, autoExitWhenEmpty: false);
    expect(s.count, 0);
    expect(s.isSelectionMode, isTrue);
  });

  test('retain with no change does not notify', () {
    s.selectAll(['a', 'b']);
    notifications = 0;
    s.retain({'a', 'b', 'c'}); // nothing to drop
    expect(notifications, 0);
    expect(s.selectedIds, {'a', 'b'});
  });

  test('selectedIds is an unmodifiable snapshot', () {
    s.selectAll(['a']);
    expect(() => s.selectedIds.add('x'), throwsUnsupportedError);
  });

  test('rapid toggles end in a consistent final selection', () {
    s.enterSelection();
    for (var i = 0; i < 5; i++) {
      s.toggle('a');
      s.toggle('b');
    }
    // 'a' toggled 5x (odd → present), 'b' toggled 5x (odd → present)
    expect(s.selectedIds, {'a', 'b'});
  });
}
