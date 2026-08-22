// test/catalog/archive_restore_test.dart
//
// Archive, restore and permanent delete (features 19, 20, 21).
//
// The bugs this file exists to catch are all about the grid disagreeing with the
// server: a row that vanishes locally when the archive call failed, an undo that
// only repaints instead of restoring, a delete that reports an error for a
// product that is already gone. None of them look wrong on the screen that
// caused them — they look wrong on the next refresh, to a user who has stopped
// watching.
//
// Hermetic: the repositories are faked, no HTTP, no Hive.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/catalog_products_notifier.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart';
import 'package:recapture/data/repositories/catalog_repository.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/product_sync_status.dart';
import 'package:recapture/presentation/screens/catalog/product_grid_section.dart';
import 'package:recapture/presentation/widgets/catalog/product_actions.dart';

import 'product_grid_test.dart' as grid;

/// The grid's fake, taught the three actions this file is about.
///
/// Extends rather than re-declares so the pagination fake and this one cannot
/// drift into two different ideas of what `list` returns.
class FakeArchiveRepository extends grid.FakeProductsRepository {
  FakeArchiveRepository(super.respond);

  final List<String> archiveCalls = [];
  final List<String> restoreCalls = [];
  final List<String> deleteCalls = [];

  /// Set to fail the next call of the matching kind.
  CatalogFailure? archiveFailure;
  CatalogFailure? restoreFailure;
  CatalogFailure? deleteFailure;

  @override
  Future<CatalogProduct> archive(String id) async {
    archiveCalls.add(id);
    if (archiveFailure != null) throw archiveFailure!;
    return grid.product(id, archived: true);
  }

  @override
  Future<CatalogProduct> restore(String id) async {
    restoreCalls.add(id);
    if (restoreFailure != null) throw restoreFailure!;
    return grid.product(id);
  }

  @override
  Future<void> delete(String id) async {
    deleteCalls.add(id);
    if (deleteFailure != null) throw deleteFailure!;
  }
}

/// Auth held still — the category notifier listens to it, and the real notifier
/// would reach for secure storage.
class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

/// The grid with its overflow menu wired to the real actions.
///
/// Deliberately the REAL [showProductActionsMenu]: the confirmation copy and
/// the undo wiring are the feature here, and a test that stubbed the menu would
/// assert only that a callback fires.
Widget harness(
  FakeArchiveRepository repo, {
  double width = 400,
  double height = 800,
}) =>
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_StubAuth.new),
        catalogProductsRepositoryProvider.overrideWithValue(repo),
        catalogRepositoryProvider.overrideWithValue(grid.FakeCatalogRepository()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              height: height,
              child: CustomScrollView(
                slivers: [
                  ProductGridSection(
                    onOpenProduct: (_) {},
                    onAddProduct: () {},
                    onProductMenu: showProductActionsMenu,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

/// Opens the overflow menu on the card at [index] and taps [label].
Future<void> pickMenuAction(
  WidgetTester tester,
  String label, {
  int index = 0,
}) async {
  await tester.tap(find.byTooltip('Product options').at(index));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

/// The grid's current items, read from the provider rather than the widget tree
/// — the widget tree only holds the cells that are laid out.
List<String> itemIds(WidgetTester tester) {
  final element = tester.element(find.byType(ProductGridSection));
  final container = ProviderScope.containerOf(element, listen: false);
  return container
      .read(catalogProductsProvider)
      .items
      .map((product) => product.id)
      .toList();
}

void main() {
  group('archive (feature 19)', () {
    testWidgets('removes the row optimistically and offers a real undo',
        (tester) async {
      final repo = FakeArchiveRepository(
        (_) async => grid.pageOf([grid.product('a'), grid.product('b')]),
      );
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();
      expect(itemIds(tester), ['a', 'b']);

      await pickMenuAction(tester, 'Archive');

      // Gone from the unarchived grid, which is what a refetch would also do.
      expect(repo.archiveCalls, ['a']);
      expect(itemIds(tester), ['b']);
      expect(find.textContaining('archived'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      // The REAL inverse call, and the row back where it was — not appended.
      expect(repo.restoreCalls, ['a']);
      expect(itemIds(tester), ['a', 'b']);
    });

    testWidgets('a failed archive puts the row back and says why',
        (tester) async {
      final repo = FakeArchiveRepository(
        (_) async => grid.pageOf([grid.product('a'), grid.product('b')]),
      );
      repo.archiveFailure = const CatalogFailure(
        code: 'OFFLINE',
        message: "You're offline — check your connection and try again.",
        isOffline: true,
      );
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      await pickMenuAction(tester, 'Archive');

      // No fake success: the row is exactly where the server still has it.
      expect(itemIds(tester), ['a', 'b']);
      expect(find.textContaining("You're offline"), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('says a live product leaves the public catalog at next publish',
        (tester) async {
      final repo = FakeArchiveRepository(
        (_) async => grid.pageOf([
          grid.product('a', sync: ProductSyncStatus.synced),
          grid.product('b'),
        ]),
      );
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      await pickMenuAction(tester, 'Archive');

      expect(
        find.textContaining('leaves your public catalog at the next publish'),
        findsOneWidget,
      );
    });

    testWidgets('warns when that was the last product', (tester) async {
      // Publish is gated CATALOG_EMPTY from here on, and the user finds that out
      // at the Publish button otherwise.
      final repo = FakeArchiveRepository(
        (_) async => grid.pageOf([grid.product('only')]),
      );
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      await pickMenuAction(tester, 'Archive');

      expect(
        find.textContaining('publishing needs at least one'),
        findsOneWidget,
      );
    });
  });

  group('restore (feature 20)', () {
    testWidgets('the Archived filter lists archived rows and restores them',
        (tester) async {
      final repo = FakeArchiveRepository(
        (call) async => grid.pageOf([
          grid.product('a', archived: call.includeArchived),
          grid.product('b'),
        ]),
      );
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Archived'));
      await tester.pumpAndSettle();
      expect(repo.calls.last.includeArchived, isTrue);

      // Restore is offered FIRST on an archived row — Archive is not offered at
      // all, because it is not a thing you can do to something already archived.
      await tester.tap(find.byTooltip('Product options').first);
      await tester.pumpAndSettle();
      expect(find.text('Restore'), findsOneWidget);
      expect(find.text('Archive'), findsNothing);

      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();

      expect(repo.restoreCalls, ['a']);
      expect(find.textContaining('back in your catalog'), findsOneWidget);
    });
  });

  group('permanent delete (feature 21)', () {
    testWidgets('is gated on typing the product name', (tester) async {
      final repo = FakeArchiveRepository(
        (_) async => grid.pageOf([grid.product('a', name: 'Chair 02')]),
      );
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      await pickMenuAction(tester, 'Delete permanently');
      expect(find.text('Delete Chair 02?'), findsOneWidget);

      // Empty field → the confirm button is disabled, not merely ignored.
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(repo.deleteCalls, isEmpty);
      expect(find.text('Delete Chair 02?'), findsOneWidget);

      // A near miss is still a miss.
      await tester.enterText(find.byType(TextField).last, 'Chair');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(repo.deleteCalls, isEmpty);

      // Case-insensitive: the gate exists to make the act deliberate, not to
      // test typing accuracy.
      await tester.enterText(find.byType(TextField).last, 'chair 02');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(repo.deleteCalls, ['a']);
      expect(itemIds(tester), isEmpty);
    });

    testWidgets('warns that a live product is removed from the public catalog',
        (tester) async {
      final repo = FakeArchiveRepository(
        (_) async => grid.pageOf([
          grid.product('a', name: 'Live One', sync: ProductSyncStatus.synced),
        ]),
      );
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      await pickMenuAction(tester, 'Delete permanently');

      expect(find.textContaining('This product is live'), findsOneWidget);
      expect(
        find.textContaining('removed from your public catalog'),
        findsOneWidget,
      );
    });

    testWidgets('a never-published product gets no live warning',
        (tester) async {
      final repo = FakeArchiveRepository(
        (_) async => grid.pageOf([
          grid.product('a', name: 'Draft One', sync: ProductSyncStatus.never),
        ]),
      );
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      await pickMenuAction(tester, 'Delete permanently');

      expect(find.textContaining('This product is live'), findsNothing);
      // The permanence is still stated — that part is true of every product.
      expect(find.textContaining('cannot be undone'), findsOneWidget);
    });

    testWidgets('deleting something already deleted is success, not an error',
        (tester) async {
      // The double tap. The API answers the same indistinguishable NOT_FOUND it
      // uses for "not yours", and the outcome the user asked for has happened
      // either way.
      final repo = FakeArchiveRepository(
        (_) async => grid.pageOf([grid.product('a', name: 'Chair 02')]),
      );
      repo.deleteFailure = const CatalogFailure(
        code: CatalogErrorCodes.notFound,
        message: 'That product no longer exists.',
        statusCode: 404,
      );
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      await pickMenuAction(tester, 'Delete permanently');
      await tester.enterText(find.byType(TextField).last, 'Chair 02');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(itemIds(tester), isEmpty);
      expect(find.textContaining('could not be deleted'), findsNothing);
    });

    testWidgets('cancelling deletes nothing', (tester) async {
      final repo = FakeArchiveRepository(
        (_) async => grid.pageOf([grid.product('a', name: 'Chair 02')]),
      );
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      await pickMenuAction(tester, 'Delete permanently');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(repo.deleteCalls, isEmpty);
      expect(itemIds(tester), ['a']);
    });
  });
}
