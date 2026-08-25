// test/capture/delete_confirmation_modal_test.dart
//
// Widget coverage for the reusable destructive-confirmation modal: the platform
// branch (Android AlertDialog / iOS CupertinoActionSheet via Theme.platform), the
// counted+pluralized message, the safe-default Cancel + dismiss=cancel contract,
// destructive confirm → true, the count==0 guard, the Retake wording reuse, and
// single-resolution on rapid taps.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/presentation/widgets/delete_confirmation_modal.dart';

void main() {
  // Pumps a host with a button that opens the modal and records its result.
  Future<List<bool>> pumpHost(
    WidgetTester tester, {
    required TargetPlatform platform,
    required int count,
    ConfirmKind kind = ConfirmKind.delete,
  }) async {
    final results = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  final r = await showDeleteConfirmation(context,
                      count: count, kind: kind);
                  results.add(r);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    return results;
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('Android (Material AlertDialog)', () {
    testWidgets('shows a counted, pluralized message + Cancel/Delete',
        (tester) async {
      await pumpHost(tester, platform: TargetPlatform.android, count: 3);
      await open(tester);

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Delete 3 photos? This can\'t be undone.'),
          findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Delete'), findsOneWidget);
    });

    testWidgets('confirm resolves true', (tester) async {
      final results =
          await pumpHost(tester, platform: TargetPlatform.android, count: 2);
      await open(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(results, [true]);
    });

    testWidgets('cancel resolves false', (tester) async {
      final results =
          await pumpHost(tester, platform: TargetPlatform.android, count: 2);
      await open(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(results, [false]);
    });

    testWidgets('tap-outside (barrier) resolves false — safe default',
        (tester) async {
      final results =
          await pumpHost(tester, platform: TargetPlatform.android, count: 2);
      await open(tester);

      await tester.tapAt(const Offset(5, 5)); // hit the dismiss barrier
      await tester.pumpAndSettle();

      expect(results, [false]);
    });

    testWidgets('singular wording at count == 1', (tester) async {
      await pumpHost(tester, platform: TargetPlatform.android, count: 1);
      await open(tester);

      expect(find.text('Delete photo?'), findsOneWidget);
      expect(find.text('Delete 1 photo? This can\'t be undone.'),
          findsOneWidget);
    });
  });

  group('iOS (CupertinoActionSheet)', () {
    testWidgets('shows a destructive Delete + Cancel with the count',
        (tester) async {
      await pumpHost(tester, platform: TargetPlatform.iOS, count: 1);
      await open(tester);

      expect(find.byType(CupertinoActionSheet), findsOneWidget);
      expect(find.text('Delete 1 photo? This can\'t be undone.'),
          findsOneWidget);
      expect(find.widgetWithText(CupertinoActionSheetAction, 'Delete'),
          findsOneWidget);
      expect(find.widgetWithText(CupertinoActionSheetAction, 'Cancel'),
          findsOneWidget);
    });

    testWidgets('destructive action resolves true', (tester) async {
      final results =
          await pumpHost(tester, platform: TargetPlatform.iOS, count: 4);
      await open(tester);

      await tester.tap(find.widgetWithText(CupertinoActionSheetAction, 'Delete'));
      await tester.pumpAndSettle();

      expect(results, [true]);
    });

    testWidgets('Cancel resolves false', (tester) async {
      final results =
          await pumpHost(tester, platform: TargetPlatform.iOS, count: 4);
      await open(tester);

      await tester.tap(find.widgetWithText(CupertinoActionSheetAction, 'Cancel'));
      await tester.pumpAndSettle();

      expect(results, [false]);
    });
  });

  group('contract', () {
    testWidgets('count == 0 is a no-op that resolves false (nothing shown)',
        (tester) async {
      final results =
          await pumpHost(tester, platform: TargetPlatform.android, count: 0);
      await open(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(results, [false]);
    });

    testWidgets('Retake kind uses retake wording (no permanence claim)',
        (tester) async {
      await pumpHost(tester,
          platform: TargetPlatform.android, count: 3, kind: ConfirmKind.retake);
      await open(tester);

      expect(find.text('Retake photos?'), findsOneWidget);
      expect(find.text('Retake 3 photos? Your current shots will be replaced.'),
          findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Retake'), findsOneWidget);
      expect(find.textContaining("can't be undone"), findsNothing);
    });

    testWidgets('rapid double-tap on Delete resolves only once', (tester) async {
      final results =
          await pumpHost(tester, platform: TargetPlatform.android, count: 2);
      await open(tester);

      final delete = find.widgetWithText(TextButton, 'Delete');
      await tester.tap(delete);
      // Second tap before settle — the dialog route is already popping.
      await tester.tap(delete, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(results, [true]);
    });
  });
}
