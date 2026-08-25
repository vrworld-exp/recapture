// test/capture/review_grid_multiselect_test.dart
//
// Widget tests for the Screen 7A multi-select layer over the review grid. ONE
// shared GridSelection, TWO platform presentations, branched on
// Theme.of(context).platform (overridden here via ThemeData.platform):
//   - Android → Contextual Action Bar (long-press to enter, count + actions, X)
//   - iOS     → Edit mode (Select button, checkmarks, Cancel/Done, bottom toolbar)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/capture_evaluation.dart';
import 'package:recapture/domain/entities/review_item.dart';
import 'package:recapture/presentation/screens/capture/review_grid_screen.dart';

ReviewItem _item(String id, {CaptureVerdict verdict = CaptureVerdict.accepted}) =>
    ReviewItem(
      captureId: id,
      filePath: '/nope/$id.jpg',
      verdict: verdict,
      capturedAt: DateTime(2026, 6, 22),
    );

final _items = [_item('a'), _item('b'), _item('c'), _item('d')];

Finder _tile(String id) => find.byKey(ValueKey<String>(id));
int _checkCount() => find.byIcon(Icons.check).evaluate().length;

/// Reads the Android CAB count from its keyed Text (avoids colliding with the
/// summary header's verdict-count numbers).
String _cabCount(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('review_cab_count'))).data!;

Future<void> _pump(
  WidgetTester tester, {
  required TargetPlatform platform,
  List<ReviewItem>? items,
  void Function(ReviewItem)? onTap,
  void Function(Set<String>)? onDelete,
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(platform: platform),
    home: ReviewGridScreen(
      items: items ?? _items,
      onTapTile: onTap,
      onDeleteSelected: onDelete,
    ),
  ));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('Android — Contextual Action Bar', () {
    testWidgets('long-press enters selection with a CAB (count 1)',
        (tester) async {
      await _pump(tester, platform: TargetPlatform.android, onDelete: (_) {});
      await tester.longPress(_tile('a'));
      await tester.pump();

      expect(find.byKey(const Key('review_cab_close')), findsOneWidget);
      expect(find.byKey(const Key('review_action_delete')), findsOneWidget);
      expect(_cabCount(tester), '1'); // CAB count
      expect(_checkCount(), 1); // 'a' shows a checkmark
    });

    testWidgets('tap toggles selection in selection mode', (tester) async {
      await _pump(tester, platform: TargetPlatform.android, onDelete: (_) {});
      await tester.longPress(_tile('a'));
      await tester.pump();
      await tester.tap(_tile('b'));
      await tester.pump();
      expect(_cabCount(tester), '2');
      expect(_checkCount(), 2);

      await tester.tap(_tile('a')); // deselect a
      await tester.pump();
      expect(_cabCount(tester), '1');
      expect(_checkCount(), 1);
    });

    testWidgets('deselecting the last item dismisses the CAB (auto-exit)',
        (tester) async {
      await _pump(tester, platform: TargetPlatform.android, onDelete: (_) {});
      await tester.longPress(_tile('a'));
      await tester.pump();
      await tester.tap(_tile('a')); // deselect last
      await tester.pump();

      expect(find.byKey(const Key('review_cab_close')), findsNothing);
      expect(find.text('Review — Level A'), findsOneWidget); // normal app bar
    });

    testWidgets('system BACK exits selection without leaving the screen',
        (tester) async {
      await _pump(tester, platform: TargetPlatform.android, onDelete: (_) {});
      await tester.longPress(_tile('a'));
      await tester.pump();
      expect(find.byKey(const Key('review_cab_close')), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pump();

      // Selection exited, but the grid is still on screen.
      expect(find.byKey(const Key('review_cab_close')), findsNothing);
      expect(find.byType(GridView), findsOneWidget);
    });

    testWidgets('X closes selection and clears', (tester) async {
      await _pump(tester, platform: TargetPlatform.android, onDelete: (_) {});
      await tester.longPress(_tile('a'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('review_cab_close')));
      await tester.pump();
      expect(find.byKey(const Key('review_cab_close')), findsNothing);
      expect(_checkCount(), 0);
    });

    testWidgets('select-all selects every item', (tester) async {
      await _pump(tester, platform: TargetPlatform.android, onDelete: (_) {});
      await tester.longPress(_tile('a'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('review_action_select_all')));
      await tester.pump();
      expect(_cabCount(tester), '${_items.length}');
      expect(_checkCount(), _items.length);
    });

    testWidgets('delete fires onDeleteSelected with ids and exits',
        (tester) async {
      Set<String>? deleted;
      await _pump(tester,
          platform: TargetPlatform.android, onDelete: (ids) => deleted = ids);
      await tester.longPress(_tile('a'));
      await tester.pump();
      await tester.tap(_tile('b'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('review_action_delete')));
      await tester.pump();

      expect(deleted, {'a', 'b'});
      expect(find.byKey(const Key('review_cab_close')), findsNothing); // exited
    });
  });

  group('iOS — Edit mode', () {
    testWidgets('Select button enters Edit mode with Cancel/Done + toolbar',
        (tester) async {
      await _pump(tester, platform: TargetPlatform.iOS, onDelete: (_) {});
      expect(find.byKey(const Key('review_select_button')), findsOneWidget);

      await tester.tap(find.byKey(const Key('review_select_button')));
      await tester.pump();

      expect(find.byKey(const Key('review_ios_cancel')), findsOneWidget);
      expect(find.byKey(const Key('review_ios_done')), findsOneWidget);
      expect(find.byKey(const Key('review_action_delete')), findsOneWidget);
      expect(find.text('0 Selected'), findsOneWidget);
    });

    testWidgets('tapping tiles toggles checkmarks and count', (tester) async {
      await _pump(tester, platform: TargetPlatform.iOS, onDelete: (_) {});
      await tester.tap(find.byKey(const Key('review_select_button')));
      await tester.pump();
      await tester.tap(_tile('a'));
      await tester.tap(_tile('b'));
      await tester.pump();
      expect(find.text('2 Selected'), findsOneWidget);
      expect(_checkCount(), 2);
    });

    testWidgets('deselecting the last item STAYS in Edit mode', (tester) async {
      await _pump(tester, platform: TargetPlatform.iOS, onDelete: (_) {});
      await tester.tap(find.byKey(const Key('review_select_button')));
      await tester.pump();
      await tester.tap(_tile('a'));
      await tester.pump();
      await tester.tap(_tile('a')); // deselect last
      await tester.pump();

      // Still in Edit mode (does not auto-exit, per iOS convention).
      expect(find.byKey(const Key('review_ios_done')), findsOneWidget);
      expect(find.text('0 Selected'), findsOneWidget);
    });

    testWidgets('Cancel exits Edit mode and clears', (tester) async {
      await _pump(tester, platform: TargetPlatform.iOS, onDelete: (_) {});
      await tester.tap(find.byKey(const Key('review_select_button')));
      await tester.pump();
      await tester.tap(_tile('a'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('review_ios_cancel')));
      await tester.pump();

      expect(find.byKey(const Key('review_select_button')), findsOneWidget);
      expect(_checkCount(), 0);
    });

    testWidgets('Done exits Edit mode', (tester) async {
      await _pump(tester, platform: TargetPlatform.iOS, onDelete: (_) {});
      await tester.tap(find.byKey(const Key('review_select_button')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('review_ios_done')));
      await tester.pump();
      expect(find.byKey(const Key('review_select_button')), findsOneWidget);
    });

    testWidgets('delete fires onDeleteSelected and exits', (tester) async {
      Set<String>? deleted;
      await _pump(tester,
          platform: TargetPlatform.iOS, onDelete: (ids) => deleted = ids);
      await tester.tap(find.byKey(const Key('review_select_button')));
      await tester.pump();
      await tester.tap(_tile('c'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('review_action_delete')));
      await tester.pump();

      expect(deleted, {'c'});
      expect(find.byKey(const Key('review_select_button')), findsOneWidget);
    });
  });

  group('cross-cutting', () {
    testWidgets('normal-mode tap opens (does not select)', (tester) async {
      final opened = <ReviewItem>[];
      await _pump(tester,
          platform: TargetPlatform.android,
          onTap: opened.add,
          onDelete: (_) {});
      await tester.tap(_tile('a'));
      await tester.pump();
      expect(opened.single.captureId, 'a');
      expect(find.byKey(const Key('review_cab_close')), findsNothing);
      expect(_checkCount(), 0);
    });

    testWidgets('no onDeleteSelected → multi-select disabled', (tester) async {
      await _pump(tester, platform: TargetPlatform.iOS); // no onDelete
      // iOS: no Select button when multi-select is disabled.
      expect(find.byKey(const Key('review_select_button')), findsNothing);

      // Android: long-press does nothing.
      await _pump(tester, platform: TargetPlatform.android);
      await tester.longPress(_tile('a'));
      await tester.pump();
      expect(find.byKey(const Key('review_cab_close')), findsNothing);
    });

    testWidgets('selection survives a widget rebuild (id-keyed)',
        (tester) async {
      await _pump(tester, platform: TargetPlatform.android, onDelete: (_) {});
      await tester.longPress(_tile('a'));
      await tester.pump();
      await tester.tap(_tile('b'));
      await tester.pump();
      expect(_checkCount(), 2);

      // Re-pump the same widget config (a rebuild) — state lives in the
      // controller, so the selection persists.
      await _pump(tester, platform: TargetPlatform.android, onDelete: (_) {});
      expect(find.text('2'), findsOneWidget);
      expect(_checkCount(), 2);
    });

    testWidgets('removed item is dropped from the selection', (tester) async {
      await _pump(tester, platform: TargetPlatform.android, onDelete: (_) {});
      await tester.longPress(_tile('a'));
      await tester.pump();
      await tester.tap(_tile('b'));
      await tester.pump();
      expect(find.text('2'), findsOneWidget);

      // Parent rebuilds with 'b' removed (e.g. after a delete).
      await _pump(tester,
          platform: TargetPlatform.android,
          items: [_item('a'), _item('c'), _item('d')],
          onDelete: (_) {});
      // 'b' dropped → count 1, still selecting.
      expect(find.text('1'), findsOneWidget);
      expect(find.byKey(const Key('review_cab_close')), findsOneWidget);
    });
  });
}
