// test/admin/standee_sheet_dialog_test.dart
//
// The dialog in front of the batch-sheet download: what it says, what it
// refuses, and — THE assertion of this file — that the number typed into it
// is the number the request carries. A dialog that showed "10 copies" and
// downloaded one would be discovered at the restaurant, after the paper is cut.
//
// Hermetic: the repository and the delivery seam are fakes, so there is no
// Dio, no share sheet and no platform channel anywhere in here.
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/catalog/catalog_qr_service.dart';
import 'package:recapture/data/repositories/admin_standee_repository.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/domain/entities/qr_standee.dart';
import 'package:recapture/presentation/screens/admin/admin_standees_screen.dart';
import 'package:recapture/presentation/screens/admin/standee_sheet_dialog.dart';
import 'package:recapture/presentation/widgets/catalog/catalog_feedback.dart';

const _plan = BatchSheetPlan(
  standees: 48,
  skippedRetired: 2,
  columns: 3,
  rows: 3,
  perPage: 9,
  maxCopies: 50,
);

/// Answers the plan and the sheet; everything else is out of scope here.
class _FakeRepo implements AdminStandeeRepository {
  _FakeRepo({this.plan = _plan, this.planThrows});

  final BatchSheetPlan plan;
  final CatalogFailure? planThrows;
  int planReads = 0;

  /// Every (batch, copies) pair the sheet was asked for.
  final List<({String batchId, int copies})> sheets = [];

  @override
  Future<BatchSheetPlan> batchSheetPlan(String batchId) async {
    planReads++;
    if (planThrows != null) throw planThrows!;
    return plan;
  }

  @override
  Future<BatchSheetDownload> batchSheet(String batchId,
      {int copies = 1}) async {
    sheets.add((batchId: batchId, copies: copies));
    return BatchSheetDownload(
      file: QrDownloadFile(
        bytes: Uint8List.fromList([6, 7]),
        fileName: 'standee-sheet.pdf',
        mimeType: 'application/pdf',
      ),
      standees: plan.standees,
      pages: plan.pagesFor(copies),
      skippedRetired: plan.skippedRetired,
      copies: copies,
      cards: plan.cardsFor(copies),
    );
  }

  @override
  Future<List<QrBatchSummary>> batches() async => [
        QrBatchSummary(
          id: 'b1',
          label: 'Vendor A — run 1',
          count: 50,
          createdAt: DateTime(2026, 9, 5),
          unassigned: 48,
          active: 0,
          retired: 2,
        ),
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeDeliverer implements QrDeliverer {
  final List<QrDownloadFile> delivered = [];

  @override
  Future<void> deliver(QrDownloadFile file) async => delivered.add(file);
}

/// The dialog on its own, opened from a button, so the test can read what it
/// popped with.
Widget _dialogApp(_FakeRepo repo, {required void Function(int?) onResult}) =>
    ProviderScope(
      overrides: [adminStandeeRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: const ValueKey('open'),
              onPressed: () async {
                final copies = await showStandeeSheetDialog(
                  context,
                  batchId: 'b1',
                  label: 'Vendor A — run 1',
                );
                onResult(copies);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('open')));
  await tester.pumpAndSettle();
}

String _valueOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey(key))).data!;

Future<void> _type(WidgetTester tester, String copies) async {
  await tester.enterText(
    find.byKey(const ValueKey('standee_sheet_copies')),
    copies,
  );
  await tester.pumpAndSettle();
}

void main() {
  group('what the dialog says', () {
    testWidgets('names the batch, the counts, the grid and ONE copy by default',
        (tester) async {
      await tester.pumpWidget(_dialogApp(_FakeRepo(), onResult: (_) {}));
      await _open(tester);

      expect(find.text('Download standee sheets'), findsOneWidget);
      expect(find.text('Vendor A — run 1'), findsOneWidget);
      expect(_valueOf(tester, 'standee_sheet_standees'), '48');
      // "48" against a batch of 50 reads as a bug until something says why.
      expect(find.text('2 retired, will be skipped'), findsOneWidget);
      expect(_valueOf(tester, 'standee_sheet_per_page'), '9');
      expect(find.text('3 × 3 on A4'), findsOneWidget);

      // One copy is the default: the plain sheet, exactly what the button
      // always produced. 48 cards at nine-up is six pages.
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('standee_sheet_copies')),
            )
            .controller!
            .text,
        '1',
      );
      expect(_valueOf(tester, 'standee_sheet_cards'), '48');
      expect(_valueOf(tester, 'standee_sheet_pages'), '6');
    });

    testWidgets('recomputes the cards and pages as the number is typed',
        (tester) async {
      await tester.pumpWidget(_dialogApp(_FakeRepo(), onResult: (_) {}));
      await _open(tester);

      // 48 × 10 = 480 cards; 480 / 9 = 53.3 → 54 pages. The page count is the
      // number an admin is here to see, and it must move with the field.
      await _type(tester, '10');
      expect(_valueOf(tester, 'standee_sheet_cards'), '480');
      expect(_valueOf(tester, 'standee_sheet_pages'), '54');

      await _type(tester, '2');
      expect(_valueOf(tester, 'standee_sheet_cards'), '96');
      expect(_valueOf(tester, 'standee_sheet_pages'), '11');
    });

    testWidgets('the stepper moves the number and stays inside 1..max',
        (tester) async {
      await tester.pumpWidget(_dialogApp(_FakeRepo(), onResult: (_) {}));
      await _open(tester);

      await tester.tap(find.byKey(const ValueKey('standee_sheet_copies_plus')));
      await tester.pumpAndSettle();
      expect(_valueOf(tester, 'standee_sheet_cards'), '96');

      // Two presses down from 2 is 0, which is not a sheet: clamps at 1.
      await tester
          .tap(find.byKey(const ValueKey('standee_sheet_copies_minus')));
      await tester
          .tap(find.byKey(const ValueKey('standee_sheet_copies_minus')));
      await tester.pumpAndSettle();
      expect(_valueOf(tester, 'standee_sheet_cards'), '48');

      await _type(tester, '50');
      await tester.tap(find.byKey(const ValueKey('standee_sheet_copies_plus')));
      await tester.pumpAndSettle();
      expect(_valueOf(tester, 'standee_sheet_cards'), '${48 * 50}');
    });
  });

  group('what the dialog refuses', () {
    testWidgets('0, 51 and an empty field disable Download and say the range',
        (tester) async {
      await tester.pumpWidget(_dialogApp(_FakeRepo(), onResult: (_) {}));
      await _open(tester);

      TextButton download() => tester.widget<TextButton>(
            find.byKey(const ValueKey('standee_sheet_download')),
          );

      expect(download().onPressed, isNotNull);

      for (final bad in ['0', '51', '']) {
        await _type(tester, bad);
        // A 400 after the press would be this dialog's own failure, and it can
        // see it coming — so the button goes, not just the request.
        expect(download().onPressed, isNull, reason: 'copies="$bad"');
        expect(find.text('Enter a number from 1 to 50.'), findsOneWidget);
        expect(_valueOf(tester, 'standee_sheet_pages'), '—');
      }

      await _type(tester, '50');
      expect(download().onPressed, isNotNull);
      expect(find.text('Enter a number from 1 to 50.'), findsNothing);
    });

    testWidgets('the copies ceiling is the SERVER\'s, not a number of its own',
        (tester) async {
      final repo = _FakeRepo(
        plan: const BatchSheetPlan(
          standees: 3,
          skippedRetired: 0,
          columns: 3,
          rows: 3,
          perPage: 9,
          maxCopies: 5,
        ),
      );
      await tester.pumpWidget(_dialogApp(repo, onResult: (_) {}));
      await _open(tester);

      await _type(tester, '6');
      expect(find.text('Enter a number from 1 to 5.'), findsOneWidget);
    });

    testWidgets('a refused batch shows the refusal and NO retry',
        (tester) async {
      final repo = _FakeRepo(
        planThrows: const CatalogFailure(
          code: 'NOTHING_TO_PRINT',
          message: 'server prose',
          statusCode: 409,
        ),
      );
      await tester.pumpWidget(_dialogApp(repo, onResult: (_) {}));
      await _open(tester);

      // OUR sentence, never the server's, and the way out it names is a
      // different button — retrying this one would get the same answer.
      expect(find.textContaining('retired'), findsOneWidget);
      expect(find.text('server prose'), findsNothing);
      expect(
          find.byKey(const ValueKey('standee_sheet_plan_retry')), findsNothing);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('standee_sheet_download')),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets(
        'a plan that would not load offers Try again, which re-reads it',
        (tester) async {
      final repo = _FakeRepo(
        planThrows: const CatalogFailure(
          code: 'OFFLINE',
          message: 'no network',
          isOffline: true,
        ),
      );
      await tester.pumpWidget(_dialogApp(repo, onResult: (_) {}));
      await _open(tester);

      expect(find.byKey(const ValueKey('standee_sheet_plan_error')),
          findsOneWidget);
      expect(repo.planReads, 1);

      await tester.tap(find.byKey(const ValueKey('standee_sheet_plan_retry')));
      await tester.pumpAndSettle();
      expect(repo.planReads, 2);
    });
  });

  group('what the dialog hands back', () {
    testWidgets('Download pops with the typed number; Cancel pops with null',
        (tester) async {
      final results = <int?>[];
      await tester.pumpWidget(_dialogApp(_FakeRepo(), onResult: results.add));

      await _open(tester);
      await _type(tester, '10');
      await tester.tap(find.byKey(const ValueKey('standee_sheet_download')));
      await tester.pumpAndSettle();

      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('standee_sheet_cancel')));
      await tester.pumpAndSettle();

      expect(results, [10, null]);
    });

    testWidgets(
        'from the inventory row: the number in the dialog is the number in the request',
        (tester) async {
      final repo = _FakeRepo();
      final deliverer = _FakeDeliverer();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          adminStandeeRepositoryProvider.overrideWithValue(repo),
          qrDelivererProvider.overrideWithValue(deliverer),
        ],
        child: const MaterialApp(home: AdminStandeesScreen()),
      ));
      await tester.pumpAndSettle();

      // The row's PDF button no longer downloads on the spot: it asks first.
      await tester.tap(find.byKey(const ValueKey('admin_batch_sheet_b1')));
      await tester.pumpAndSettle();
      expect(find.text('Download standee sheets'), findsOneWidget);
      expect(repo.sheets, isEmpty);

      await _type(tester, '10');
      await tester.tap(find.byKey(const ValueKey('standee_sheet_download')));
      await tester.pumpAndSettle();

      // THE assertion of this file.
      expect(repo.sheets, [(batchId: 'b1', copies: 10)]);
      expect(deliverer.delivered.single.mimeType, 'application/pdf');
      // And the toast afterwards says what the dialog promised.
      expect(
        find.text('Saved 48 standees × 10 copies over 54 pages. '
            '2 retired and were skipped.'),
        findsOneWidget,
      );
      // Let the toast's auto-hide timer run out, so nothing is pending at
      // teardown.
      await tester.pump(kCatalogToastDuration);
      await tester.pumpAndSettle();
    });

    testWidgets('backing out of the dialog downloads nothing', (tester) async {
      final repo = _FakeRepo();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          adminStandeeRepositoryProvider.overrideWithValue(repo),
          qrDelivererProvider.overrideWithValue(_FakeDeliverer()),
        ],
        child: const MaterialApp(home: AdminStandeesScreen()),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('admin_batch_sheet_b1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('standee_sheet_cancel')));
      await tester.pumpAndSettle();

      expect(repo.sheets, isEmpty);
    });
  });

  group('BatchSheetPlan arithmetic', () {
    test('matches the server: ceil(standees × copies / perPage), never below 1',
        () {
      const plan = BatchSheetPlan(
        standees: 7,
        skippedRetired: 0,
        columns: 3,
        rows: 3,
        perPage: 9,
        maxCopies: 50,
      );
      expect(plan.pagesFor(1), 1);
      expect(plan.pagesFor(2), 2); // 14 → 2
      expect(plan.pagesFor(9), 7); // 63 → 7 exactly
      expect(plan.pagesFor(10), 8); // 70 → 8
      expect(plan.cardsFor(10), 70);
    });

    test('reads the server shape and falls back on the copies ceiling', () {
      final plan = BatchSheetPlan.fromMap({
        'standees': 4,
        'skippedRetired': 1,
        'columns': 1,
        'rows': 2,
        'perPage': 2,
      });
      expect(plan.pagesFor(3), 6);
      expect(plan.maxCopies, kStandeeSheetMaxCopiesFallback);
    });
  });
}
