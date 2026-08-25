// test/capture/review_grid_retake_test.dart
//
// Verifies the Retake intent seam on the Screen 7A review grid: the per-tile
// Retake control appears only when an onRetake hook is supplied (and the tile has
// a known ring position), builds a RetakeRequest for that segment, is hidden in
// selection mode, and debounces rapid double-taps to a single emission.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/capture_evaluation.dart';
import 'package:recapture/domain/entities/retake_request.dart';
import 'package:recapture/domain/entities/review_item.dart';
import 'package:recapture/presentation/screens/capture/review_grid_screen.dart';

ReviewItem _item(
  String id, {
  int? ringIndex,
  CaptureVerdict verdict = CaptureVerdict.warn,
}) =>
    ReviewItem(
      captureId: id,
      filePath: '/nope/$id.jpg',
      verdict: verdict,
      ringIndex: ringIndex,
      capturedAt: DateTime(2026, 6, 22),
    );

Finder _retake(String id) => find.byKey(Key('review_retake_$id'));
Finder _tile(String id) => find.byKey(ValueKey<String>(id));

Future<void> _pump(
  WidgetTester tester, {
  required List<ReviewItem> items,
  void Function(RetakeRequest)? onRetake,
  void Function(Set<String>)? onDelete,
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(platform: TargetPlatform.android),
    home: ReviewGridScreen(
      items: items,
      onRetake: onRetake,
      onDeleteSelected: onDelete,
    ),
  ));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('no Retake control when onRetake is not supplied', (tester) async {
    await _pump(tester, items: [_item('a', ringIndex: 0)]);
    expect(_retake('a'), findsNothing);
  });

  testWidgets('Retake control shows + emits a RetakeRequest for the segment',
      (tester) async {
    RetakeRequest? captured;
    await _pump(
      tester,
      items: [_item('a', ringIndex: 4)],
      onRetake: (r) => captured = r,
    );

    expect(_retake('a'), findsOneWidget);
    await tester.tap(_retake('a'));
    await tester.pump();

    expect(captured, isNotNull);
    expect(captured!.ringIndex, 4);
    expect(captured!.replacingCaptureId, 'a');
    expect(captured!.returnToReviewAfter, isTrue);
  });

  testWidgets('a tile without a ring index has no Retake control', (tester) async {
    await _pump(
      tester,
      items: [_item('a')], // ringIndex null
      onRetake: (_) {},
    );
    expect(_retake('a'), findsNothing);
  });

  testWidgets('rapid double-tap fires onRetake only once (debounced)',
      (tester) async {
    var count = 0;
    await _pump(
      tester,
      items: [_item('a', ringIndex: 1)],
      onRetake: (_) => count++,
    );

    await tester.tap(_retake('a'));
    await tester.tap(_retake('a')); // immediate second tap
    await tester.pump();

    expect(count, 1);
  });

  testWidgets('Retake control is hidden in selection mode', (tester) async {
    await _pump(
      tester,
      items: [_item('a', ringIndex: 0)],
      onRetake: (_) {},
      onDelete: (_) {}, // enables multi-select
    );
    expect(_retake('a'), findsOneWidget);

    // Enter Android selection mode via long-press.
    await tester.longPress(_tile('a'));
    await tester.pump();

    expect(_retake('a'), findsNothing,
        reason: 'retake is hidden while (de)selecting');
  });
}
