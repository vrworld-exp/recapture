// test/admin/standee_copies_dialog_test.dart
//
// The dialog in front of the single-standee download: how many of this one
// code, and one-up or the grid. What it says, what it refuses, and what it
// hands back. The end-to-end "the number in the dialog is the number in the
// request" is asserted through the admin batch screen here and through the
// rep's standee list in test/rep/standee_assignment_test.dart.
//
// Hermetic: the repository and the delivery seam are fakes.
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/catalog/catalog_qr_service.dart';
import 'package:recapture/application/standee_sheet_plan.dart';
import 'package:recapture/data/repositories/admin_standee_repository.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/standee_sheet.dart';
import 'package:recapture/domain/entities/qr_standee.dart';
import 'package:recapture/presentation/screens/admin/admin_batch_detail_screen.dart';
import 'package:recapture/presentation/widgets/catalog/catalog_feedback.dart';
import 'package:recapture/presentation/widgets/standee_copies_dialog.dart';

const _plan = StandeeSheetPlan(columns: 3, rows: 3, perPage: 9, maxCopies: 50);

class _FakeRepo implements AdminStandeeRepository {
  _FakeRepo({this.plan = _plan, this.planThrows});

  final StandeeSheetPlan plan;
  final CatalogFailure? planThrows;
  int planReads = 0;
  final List<({String code, int copies, StandeeSheetLayout layout})> sheets =
      [];

  @override
  Future<StandeeSheetPlan> standeeSheetPlan(String code) async {
    planReads++;
    if (planThrows != null) throw planThrows!;
    return plan;
  }

  @override
  Future<StandeeSheetDownload> standeeSheet(
    String code, {
    int copies = 1,
    StandeeSheetLayout layout = StandeeSheetLayout.single,
  }) async {
    sheets.add((code: code, copies: copies, layout: layout));
    return StandeeSheetDownload(
      file: QrDownloadFile(
        bytes: Uint8List.fromList([1, 2]),
        fileName: 'standee-$code-qr.pdf',
        mimeType: 'application/pdf',
      ),
      copies: copies,
      pages: plan.pagesFor(copies, layout),
    );
  }

  @override
  Future<QrCodePage> codes(String batchId, {String? after, int? limit}) async =>
      const QrCodePage(
        codes: [
          QrStandeeCode(
            code: 'ABCD2345',
            state: QrCodeState.unassigned,
            url: 'https://scan.test/r/ABCD2345',
          ),
        ],
        nextAfter: null,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeDeliverer implements QrDeliverer {
  final List<QrDownloadFile> delivered = [];

  @override
  Future<void> deliver(QrDownloadFile file) async => delivered.add(file);
}

Widget _dialogApp(
  _FakeRepo repo, {
  required void Function(StandeeSheetChoice?) onResult,
}) =>
    ProviderScope(
      overrides: [adminStandeeRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: const ValueKey('open'),
              onPressed: () async {
                final choice = await showStandeeCopiesDialog(
                  context,
                  code: 'ABCD2345',
                  plan: adminStandeeSheetPlanProvider('ABCD2345'),
                );
                onResult(choice);
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

String _pages(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('standee_copies_pages')))
    .data!;

Future<void> _type(WidgetTester tester, String copies) async {
  await tester.enterText(
    find.byKey(const ValueKey('standee_copies_field')),
    copies,
  );
  await tester.pumpAndSettle();
}

Future<void> _pick(WidgetTester tester, String layoutKey) async {
  await tester.tap(find.byKey(ValueKey(layoutKey)));
  await tester.pumpAndSettle();
}

TextButton _download(WidgetTester tester) => tester.widget<TextButton>(
      find.byKey(const ValueKey('standee_copies_download')),
    );

void main() {
  group('what the dialog says', () {
    testWidgets(
        'names the code, defaults to ONE copy one-up, and offers both layouts',
        (tester) async {
      await tester.pumpWidget(_dialogApp(_FakeRepo(), onResult: (_) {}));
      await _open(tester);

      expect(find.text('Download standee'), findsOneWidget);
      expect(find.text('ABCD2345'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('standee_copies_field')),
            )
            .controller!
            .text,
        '1',
      );
      // The two layouts, described as what comes off the printer. The grid's
      // count is the server's, not a number the dialog remembers.
      expect(find.text('1 QR per page'), findsOneWidget);
      expect(find.text('9 QRs per page'), findsOneWidget);
      expect(find.text('3 × 3 cut-out cards on each A4 page.'), findsOneWidget);
      expect(_pages(tester), '1');
    });

    testWidgets('pages follow the number AND the layout', (tester) async {
      await tester.pumpWidget(_dialogApp(_FakeRepo(), onResult: (_) {}));
      await _open(tester);

      // One-up: ten copies is ten pages.
      await _type(tester, '10');
      expect(_pages(tester), '10');

      // The grid: ten copies at nine-up is two pages.
      await _pick(tester, 'standee_layout_grid');
      expect(_pages(tester), '2');

      await _type(tester, '9');
      expect(_pages(tester), '1');

      // Back to one-up, the count follows.
      await _pick(tester, 'standee_layout_single');
      expect(_pages(tester), '9');
    });

    testWidgets('the grid shape is the server\'s', (tester) async {
      final repo = _FakeRepo(
        plan: const StandeeSheetPlan(
          columns: 2,
          rows: 2,
          perPage: 4,
          maxCopies: 50,
        ),
      );
      await tester.pumpWidget(_dialogApp(repo, onResult: (_) {}));
      await _open(tester);

      expect(find.text('4 QRs per page'), findsOneWidget);
      await _type(tester, '5');
      await _pick(tester, 'standee_layout_grid');
      expect(_pages(tester), '2');
    });

    testWidgets('the stepper stays inside 1..max', (tester) async {
      await tester.pumpWidget(_dialogApp(_FakeRepo(), onResult: (_) {}));
      await _open(tester);

      await tester.tap(find.byKey(const ValueKey('standee_copies_minus')));
      await tester.pumpAndSettle();
      expect(_pages(tester), '1');

      await _type(tester, '50');
      await tester.tap(find.byKey(const ValueKey('standee_copies_plus')));
      await tester.pumpAndSettle();
      expect(_pages(tester), '50');
    });
  });

  group('what the dialog refuses', () {
    testWidgets('0, 51 and an empty field disable Download', (tester) async {
      await tester.pumpWidget(_dialogApp(_FakeRepo(), onResult: (_) {}));
      await _open(tester);
      expect(_download(tester).onPressed, isNotNull);

      for (final bad in ['0', '51', '']) {
        await _type(tester, bad);
        expect(_download(tester).onPressed, isNull, reason: 'copies="$bad"');
        expect(find.text('Enter a number from 1 to 50.'), findsOneWidget);
        expect(_pages(tester), '—');
      }
    });

    testWidgets('a retired code shows the refusal and NO retry',
        (tester) async {
      final repo = _FakeRepo(
        planThrows: const CatalogFailure(
          code: 'CODE_RETIRED',
          message: 'server prose',
          statusCode: 409,
        ),
      );
      await tester.pumpWidget(_dialogApp(repo, onResult: (_) {}));
      await _open(tester);

      expect(find.textContaining('retired'), findsOneWidget);
      expect(find.text('server prose'), findsNothing);
      expect(
        find.byKey(const ValueKey('standee_copies_plan_retry')),
        findsNothing,
      );
      expect(_download(tester).onPressed, isNull);
    });

    testWidgets('a plan that would not load offers Try again', (tester) async {
      final repo = _FakeRepo(
        planThrows: const CatalogFailure(
          code: 'OFFLINE',
          message: 'no network',
          isOffline: true,
        ),
      );
      await tester.pumpWidget(_dialogApp(repo, onResult: (_) {}));
      await _open(tester);
      expect(repo.planReads, 1);

      await tester.tap(find.byKey(const ValueKey('standee_copies_plan_retry')));
      await tester.pumpAndSettle();
      expect(repo.planReads, 2);
    });
  });

  group('what the dialog hands back', () {
    testWidgets('Download pops with the choice; Cancel pops with null',
        (tester) async {
      final results = <StandeeSheetChoice?>[];
      await tester.pumpWidget(_dialogApp(_FakeRepo(), onResult: results.add));

      await _open(tester);
      await _type(tester, '10');
      await _pick(tester, 'standee_layout_grid');
      await tester.tap(find.byKey(const ValueKey('standee_copies_download')));
      await tester.pumpAndSettle();

      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('standee_copies_cancel')));
      await tester.pumpAndSettle();

      expect(results, hasLength(2));
      expect(results[0]!.copies, 10);
      expect(results[0]!.layout, StandeeSheetLayout.grid);
      expect(results[1], isNull);
    });

    testWidgets(
        'from the admin batch screen: the choice in the dialog is the request',
        (tester) async {
      final repo = _FakeRepo();
      final deliverer = _FakeDeliverer();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          adminStandeeRepositoryProvider.overrideWithValue(repo),
          qrDelivererProvider.overrideWithValue(deliverer),
        ],
        child: const MaterialApp(
          home: AdminBatchDetailScreen(batchId: 'b1'),
        ),
      ));
      await tester.pumpAndSettle();

      // The row's send button asks first.
      await tester.tap(find.byIcon(Icons.save_alt));
      await tester.pumpAndSettle();
      expect(find.text('Download standee'), findsOneWidget);
      expect(repo.sheets, isEmpty);

      await _type(tester, '4');
      await tester.tap(find.byKey(const ValueKey('standee_copies_download')));
      await tester.pumpAndSettle();

      expect(repo.sheets, [
        (code: 'ABCD2345', copies: 4, layout: StandeeSheetLayout.single),
      ]);
      expect(deliverer.delivered.single.mimeType, 'application/pdf');
      expect(
        find.text('Standee ABCD2345 saved — 4 copies over 4 pages.'),
        findsOneWidget,
      );
      await tester.pump(kCatalogToastDuration);
      await tester.pumpAndSettle();
    });
  });

  group('StandeeSheetPlan arithmetic', () {
    test('matches the server for both layouts', () {
      expect(_plan.pagesFor(1, StandeeSheetLayout.single), 1);
      expect(_plan.pagesFor(10, StandeeSheetLayout.single), 10);
      expect(_plan.pagesFor(1, StandeeSheetLayout.grid), 1);
      expect(_plan.pagesFor(9, StandeeSheetLayout.grid), 1);
      expect(_plan.pagesFor(10, StandeeSheetLayout.grid), 2);
      expect(_plan.pagesFor(50, StandeeSheetLayout.grid), 6);
    });

    test('the notice names copies and pages only when there are copies', () {
      final one = StandeeSheetDownload(
        file: QrDownloadFile(
          bytes: Uint8List(0),
          fileName: 'x.pdf',
          mimeType: 'application/pdf',
        ),
        copies: 1,
        pages: 1,
      );
      expect(standeeSheetNotice('ABCD2345', one), 'Standee ABCD2345 saved.');

      final ten = StandeeSheetDownload(file: one.file, copies: 10, pages: 2);
      expect(
        standeeSheetNotice('ABCD2345', ten),
        'Standee ABCD2345 saved — 10 copies over 2 pages.',
      );
      // A stripped pages header drops the clause rather than saying zero.
      final stripped =
          StandeeSheetDownload(file: one.file, copies: 3, pages: 0);
      expect(
        standeeSheetNotice('ABCD2345', stripped),
        'Standee ABCD2345 saved — 3 copies.',
      );
    });
  });
}
