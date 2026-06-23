// test/capture/review_grid_action_surface_test.dart
//
// Verifies the Screen 7A action surface is reconciled to ONE coherent set: the
// multi-select Retake action sits alongside Delete in the selection chrome
// (Android CAB / iOS Edit toolbar, gated on onRetakeSelected), and the persistent
// "Back to Capture" bar shows outside selection mode (gated on onBackToCapture and
// never coexisting with the iOS selection toolbar).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/capture_evaluation.dart';
import 'package:recapture/domain/entities/review_item.dart';
import 'package:recapture/presentation/screens/capture/review_grid_screen.dart';

ReviewItem _item(String id) => ReviewItem(
      captureId: id,
      filePath: '/nope/$id.jpg',
      verdict: CaptureVerdict.accepted,
      ringIndex: 0,
      capturedAt: DateTime(2026, 6, 22),
    );

final _items = [_item('a'), _item('b'), _item('c')];

Finder _tile(String id) => find.byKey(ValueKey<String>(id));
Finder get _retakeAction => find.byKey(const Key('review_action_retake'));
Finder get _deleteAction => find.byKey(const Key('review_action_delete'));
Finder get _backToCapture => find.byKey(const Key('review_back_to_capture'));

Future<void> _pump(
  WidgetTester tester, {
  required TargetPlatform platform,
  void Function(Set<String>)? onDelete,
  void Function(Set<String>)? onRetakeSelected,
  void Function()? onBackToCapture,
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(platform: platform),
    home: ReviewGridScreen(
      items: _items,
      onDeleteSelected: onDelete,
      onRetakeSelected: onRetakeSelected,
      onBackToCapture: onBackToCapture,
    ),
  ));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('Android CAB', () {
    testWidgets('Retake action appears next to Delete when wired', (tester) async {
      Set<String>? retook;
      await _pump(
        tester,
        platform: TargetPlatform.android,
        onDelete: (_) {},
        onRetakeSelected: (ids) => retook = ids,
      );
      await tester.longPress(_tile('a'));
      await tester.pump();

      expect(_retakeAction, findsOneWidget);
      expect(_deleteAction, findsOneWidget);

      await tester.tap(_retakeAction);
      await tester.pump();

      expect(retook, {'a'});
      // Retake leaves selection mode (parent navigates away).
      expect(_retakeAction, findsNothing);
    });

    testWidgets('no Retake action when onRetakeSelected is absent', (tester) async {
      await _pump(tester, platform: TargetPlatform.android, onDelete: (_) {});
      await tester.longPress(_tile('a'));
      await tester.pump();

      expect(_retakeAction, findsNothing);
      expect(_deleteAction, findsOneWidget); // delete still there
    });
  });

  group('iOS Edit toolbar', () {
    testWidgets('Retake action appears in the bottom toolbar when wired',
        (tester) async {
      Set<String>? retook;
      await _pump(
        tester,
        platform: TargetPlatform.iOS,
        onDelete: (_) {},
        onRetakeSelected: (ids) => retook = ids,
      );
      // iOS enters selection via the Select button.
      await tester.tap(find.byKey(const Key('review_select_button')));
      await tester.pump();
      await tester.tap(_tile('a'));
      await tester.pump();

      expect(_retakeAction, findsOneWidget);
      await tester.tap(_retakeAction);
      await tester.pump();
      expect(retook, {'a'});
    });
  });

  group('Back to Capture bar', () {
    testWidgets('shows outside selection and invokes the hook', (tester) async {
      var tapped = 0;
      await _pump(
        tester,
        platform: TargetPlatform.android,
        onDelete: (_) {},
        onBackToCapture: () => tapped++,
      );

      expect(_backToCapture, findsOneWidget);
      await tester.tap(_backToCapture);
      await tester.pump();
      expect(tapped, 1);
    });

    testWidgets('absent when no hook is supplied', (tester) async {
      await _pump(tester, platform: TargetPlatform.android, onDelete: (_) {});
      expect(_backToCapture, findsNothing);
    });

    testWidgets('hidden while the iOS selection toolbar is up (one surface)',
        (tester) async {
      await _pump(
        tester,
        platform: TargetPlatform.iOS,
        onDelete: (_) {},
        onBackToCapture: () {},
      );
      expect(_backToCapture, findsOneWidget);

      await tester.tap(find.byKey(const Key('review_select_button')));
      await tester.pump();

      // The Edit toolbar replaces the Back-to-Capture bar — never both.
      expect(_backToCapture, findsNothing);
      expect(_deleteAction, findsOneWidget);
    });
  });
}
