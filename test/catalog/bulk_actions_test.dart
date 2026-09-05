// test/catalog/bulk_actions_test.dart
//
// Bulk selection and bulk actions (feature 30, T-022).
//
// The bug this file exists to catch is a REPORTING bug, and it is the reason the
// feature is written the way it is. `POST /catalog/products/bulk` is
// all-or-nothing per call: one id that is no longer a live product of the
// catalog — a row someone deleted on another device — makes the server refuse
// the whole batch with `ID_SET_MISMATCH` and apply nothing. A client that
// forwarded that verdict would tell a user that eighteen perfectly good products
// failed; a client that swallowed it would say "Done" over twenty products it
// never touched. Neither is acceptable, so the notifier bisects the rejected
// chunk until the bad ids are isolated, and reports both halves.
//
// The other two things guarded here are the ones that make a selection
// TRUSTWORTHY: it survives scrolling and pagination (it is a set of ids, not of
// widgets), and it does NOT survive a filter change — silently carrying an
// invisible selection into a Delete is the worst thing this feature could do.
//
// Hermetic: the repositories are faked, no HTTP, no Hive.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/bulk_selection_notifier.dart';
import 'package:recapture/application/catalog/catalog_products_notifier.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart';
import 'package:recapture/data/repositories/catalog_repository.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/presentation/widgets/catalog/product_card.dart';

import 'product_grid_test.dart' as grid;

/// One recorded bulk call.
class BulkCall {
  BulkCall(this.action, this.ids, this.categoryId);

  final BulkProductAction action;
  final List<String> ids;
  final Object? categoryId;
}

/// A products repository that behaves like the real bulk endpoint.
///
/// The important half is [deadIds]: the server counts the ids that are live
/// products of the catalog and, if that count does not match, applies NOTHING
/// and answers `ID_SET_MISMATCH`. Modelling that faithfully is the only way this
/// file can prove the client turns it into per-item outcomes.
class BulkRepository extends grid.FakeProductsRepository {
  BulkRepository(
    super.respond, {
    Set<String>? deadIds,
  }) : deadIds = deadIds ?? <String>{};

  /// Ids the server no longer has (deleted elsewhere, or never ours).
  final Set<String> deadIds;

  /// A failure that is NOT id-scoped — offline, a 500, a rate limit. Splitting
  /// one of these would only make N failing requests out of one.
  CatalogFailure? hardFailure;

  final List<BulkCall> bulkCalls = [];

  @override
  Future<int> bulk({
    required BulkProductAction action,
    required List<String> ids,
    Object? categoryId = kCatalogUnchanged,
  }) async {
    bulkCalls.add(BulkCall(action, ids, categoryId));
    if (hardFailure != null) throw hardFailure!;
    if (ids.any(deadIds.contains)) {
      throw const CatalogFailure(
        code: 'ID_SET_MISMATCH',
        message:
            'One or more products could not be found. Reload and try again.',
        statusCode: 400,
      );
    }
    return ids.length;
  }
}

class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

/// A container over [repo], with the first page already served.
Future<ProviderContainer> loaded(
  BulkRepository repo, {
  String? nextCursor,
}) async {
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith(_StubAuth.new),
      catalogProductsRepositoryProvider.overrideWithValue(repo),
      catalogRepositoryProvider.overrideWithValue(grid.FakeCatalogRepository()),
    ],
  );
  addTearDown(container.dispose);

  // Both notifiers alive before the first pump: the selection notifier listens
  // to the query, and that listener has to exist before a filter moves.
  container.read(bulkSelectionProvider);
  container.read(catalogProductsProvider);
  await Future<void>.delayed(Duration.zero);
  return container;
}

/// [count] products with predictable ids: p0, p1, …
List<CatalogProduct> products(int count) => [
      for (var i = 0; i < count; i++)
        grid.product('p$i', name: 'Product $i', position: i),
    ];

BulkRepository repositoryOf(
  List<CatalogProduct> page, {
  Set<String>? deadIds,
  List<CatalogProduct>? secondPage,
}) =>
    BulkRepository(
      (call) async => call.cursor == null
          ? CatalogProductPage(
              items: page,
              nextCursor: secondPage == null ? null : 'cursor-2',
            )
          : CatalogProductPage(items: secondPage ?? const <CatalogProduct>[]),
      deadIds: deadIds,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('per-item reporting', () {
    test('a partial run is itemised, never flattened into "done"', () async {
      // Two of the twenty were deleted on another device.
      final repo = repositoryOf(products(20), deadIds: {'p3', 'p11'});
      final container = await loaded(repo);
      final notifier = container.read(bulkSelectionProvider.notifier);

      notifier.selectAllLoaded();
      final result = await notifier.run(action: BulkProductAction.archive);

      expect(result.requested, 20);
      expect(result.succeeded, hasLength(18));
      expect(result.failed, hasLength(2));
      expect(result.failedIds.toSet(), {'p3', 'p11'});
      expect(result.isCompleteSuccess, isFalse);
      expect(result.isPartial, isTrue);
      expect(result.isolationExhausted, isFalse);
      // The report names the products, not the ids — a list of ObjectIds is not
      // something the user can act on.
      expect(
          result.failed.map((f) => f.name),
          containsAll(<String>[
            'Product 3',
            'Product 11',
          ]));
    });

    test('the failed subset stays selected, so a retry has a target', () async {
      final repo = repositoryOf(products(6), deadIds: {'p2'});
      final container = await loaded(repo);
      final notifier = container.read(bulkSelectionProvider.notifier);

      notifier.selectAllLoaded();
      await notifier.run(action: BulkProductAction.archive);

      expect(container.read(bulkSelectionProvider).ids, {'p2'});
    });

    test('a retry re-runs the failed ids ONLY', () async {
      final repo = repositoryOf(products(6), deadIds: {'p2'});
      final container = await loaded(repo);
      final notifier = container.read(bulkSelectionProvider.notifier);

      notifier.selectAllLoaded();
      final first = await notifier.run(action: BulkProductAction.archive);
      repo.bulkCalls.clear();

      // The row came back (someone restored it, or the earlier read was stale).
      repo.deadIds.clear();
      notifier.selectOnly(first.failedIds);
      final second = await notifier.run(action: BulkProductAction.archive);

      expect(second.succeeded, ['p2']);
      expect(second.failed, isEmpty);
      // Exactly one call, carrying exactly the failed id: re-sending the
      // eighteen that already worked would archive them twice.
      expect(repo.bulkCalls, hasLength(1));
      expect(repo.bulkCalls.single.ids, ['p2']);
    });

    test('a failure that is NOT id-scoped is never bisected', () async {
      final repo = repositoryOf(products(20))
        ..hardFailure = const CatalogFailure(
          code: 'OFFLINE',
          message: "You're offline — check your connection and try again.",
          isOffline: true,
        );
      final container = await loaded(repo);
      final notifier = container.read(bulkSelectionProvider.notifier);

      notifier.selectAllLoaded();
      final result = await notifier.run(action: BulkProductAction.delete);

      // ONE request. Splitting an offline failure would make twenty of them.
      expect(repo.bulkCalls, hasLength(1));
      expect(result.isCompleteFailure, isTrue);
      expect(result.failed, hasLength(20));
      expect(result.failed.first.failure.isOffline, isTrue);
    });

    test('every id being stale isolates every id, not the batch', () async {
      final repo = repositoryOf(
        products(8),
        deadIds: {for (var i = 0; i < 8; i++) 'p$i'},
      );
      final container = await loaded(repo);
      final notifier = container.read(bulkSelectionProvider.notifier);

      notifier.selectAllLoaded();
      final result = await notifier.run(action: BulkProductAction.archive);

      expect(result.succeeded, isEmpty);
      expect(result.failed, hasLength(8));
      expect(result.failedIds.toSet(), {for (var i = 0; i < 8; i++) 'p$i'});
    });

    test(
      'an exhausted isolation budget reports the rest as FAILED, and says so',
      () async {
        // Bisecting 300 stale ids down to singletons costs far more requests
        // than the budget allows. What must NOT happen is the remainder being
        // counted as successes.
        final ids = [for (var i = 0; i < 300; i++) 'stale$i'];
        final repo = repositoryOf(products(1), deadIds: ids.toSet());
        final container = await loaded(repo);
        final notifier = container.read(bulkSelectionProvider.notifier);

        notifier.selectOnly(ids);
        final result = await notifier.run(action: BulkProductAction.archive);

        expect(result.succeeded, isEmpty);
        expect(result.failed, hasLength(300));
        expect(result.isolationExhausted, isTrue);
      },
    );

    test('a selection over the id limit is chunked', () async {
      final ids = [for (var i = 0; i < kBulkProductIdLimit + 5; i++) 'q$i'];
      final repo = repositoryOf(products(1));
      final container = await loaded(repo);
      final notifier = container.read(bulkSelectionProvider.notifier);

      notifier.selectOnly(ids);
      final result = await notifier.run(action: BulkProductAction.restore);

      expect(repo.bulkCalls, hasLength(2));
      expect(repo.bulkCalls.first.ids, hasLength(kBulkProductIdLimit));
      expect(repo.bulkCalls.last.ids, hasLength(5));
      expect(result.succeeded, hasLength(ids.length));
    });

    test('a run with nothing selected does nothing at all', () async {
      final repo = repositoryOf(products(4));
      final container = await loaded(repo);
      final notifier = container.read(bulkSelectionProvider.notifier);

      notifier.enter();
      final result = await notifier.run(action: BulkProductAction.delete);

      expect(repo.bulkCalls, isEmpty);
      expect(result.requested, 0);
    });
  });

  group('the grid after a run', () {
    test('only the SUCCEEDED ids leave an unarchived grid', () async {
      final repo = repositoryOf(products(5), deadIds: {'p1'});
      final container = await loaded(repo);
      final notifier = container.read(bulkSelectionProvider.notifier);

      notifier.selectAllLoaded();
      await notifier.run(action: BulkProductAction.archive);

      final remaining = [
        for (final item in container.read(catalogProductsProvider).items)
          item.id,
      ];
      // p1 failed, so it must still be exactly where it was — a row that
      // vanished locally after a failed archive is the grid lying.
      expect(remaining, ['p1']);
    });

    test('a delete drops the succeeded rows and keeps the failed one',
        () async {
      final repo = repositoryOf(products(4), deadIds: {'p0'});
      final container = await loaded(repo);
      final notifier = container.read(bulkSelectionProvider.notifier);

      notifier.selectAllLoaded();
      await notifier.run(action: BulkProductAction.delete);

      expect(
        [
          for (final item in container.read(catalogProductsProvider).items)
            item.id
        ],
        ['p0'],
      );
    });

    test('a category move updates the rows in place', () async {
      final repo = repositoryOf(products(3));
      final container = await loaded(repo);
      final notifier = container.read(bulkSelectionProvider.notifier);

      notifier.selectAllLoaded();
      await notifier.run(
        action: BulkProductAction.setCategory,
        categoryId: 'cat-9',
      );

      expect(
        container
            .read(catalogProductsProvider)
            .items
            .every((item) => item.categoryId == 'cat-9'),
        isTrue,
      );
      // SET_CATEGORY needs the key present even when the value is null, so the
      // sentinel must never reach the request.
      expect(repo.bulkCalls.single.categoryId, 'cat-9');
    });
  });

  group('selection stability', () {
    test('survives pagination — a second page never evicts it', () async {
      final repo = repositoryOf(
        products(3),
        secondPage: [
          grid.product('p3', name: 'Product 3', position: 3),
          grid.product('p4', name: 'Product 4', position: 4),
        ],
      );
      final container = await loaded(repo);
      final notifier = container.read(bulkSelectionProvider.notifier);

      notifier.enter('p0');
      notifier.toggle('p2');
      expect(container.read(bulkSelectionProvider).ids, {'p0', 'p2'});

      await container.read(catalogProductsProvider.notifier).loadMore();

      expect(container.read(catalogProductsProvider).items, hasLength(5));
      expect(container.read(bulkSelectionProvider).ids, {'p0', 'p2'});
    });

    test('a filter change clears it — and says so', () async {
      final repo = repositoryOf(products(4));
      final container = await loaded(repo);
      final notifier = container.read(bulkSelectionProvider.notifier);

      notifier.enter('p0');
      notifier.toggle('p1');

      container.read(catalogProductsProvider.notifier).setCategory('cat-1');
      await Future<void>.delayed(Duration.zero);

      final selection = container.read(bulkSelectionProvider);
      expect(selection.ids, isEmpty);
      expect(selection.isActive, isTrue,
          reason: 'the user is still picking; only the set is stale');
      expect(selection.clearedByFilterChange, isTrue,
          reason:
              'a selection that empties itself invisibly is the whole risk');
    });

    test('select-all covers the LOADED products and admits it', () async {
      final repo = repositoryOf(
        products(3),
        secondPage: [grid.product('p3', name: 'Product 3', position: 3)],
      );
      final container = await loaded(repo);
      final notifier = container.read(bulkSelectionProvider.notifier);

      notifier.selectAllLoaded();

      final selection = container.read(bulkSelectionProvider);
      expect(selection.ids, {'p0', 'p1', 'p2'});
      expect(selection.scopedToLoaded, isTrue,
          reason: 'there is another page, and it was not selected');
    });

    test('select-all on a fully loaded grid claims no such caveat', () async {
      final repo = repositoryOf(products(3));
      final container = await loaded(repo);

      container.read(bulkSelectionProvider.notifier).selectAllLoaded();

      expect(container.read(bulkSelectionProvider).scopedToLoaded, isFalse);
    });

    test('the selection is ordered like the grid, stragglers last', () async {
      final repo = repositoryOf(products(4));
      final container = await loaded(repo);
      final notifier = container.read(bulkSelectionProvider.notifier);

      // p9 is not on any loaded page — it must still be part of the action.
      notifier.selectOnly(['p3', 'p9', 'p1']);

      expect(notifier.orderedSelection(), ['p1', 'p3', 'p9']);
    });
  });

  group('range select', () {
    test('extends from the anchor, inclusive, in either direction', () async {
      final repo = repositoryOf(products(6));
      final container = await loaded(repo);
      final notifier = container.read(bulkSelectionProvider.notifier);

      notifier.enter('p4');
      notifier.selectRangeTo('p1');

      expect(
          container.read(bulkSelectionProvider).ids, {'p1', 'p2', 'p3', 'p4'});
    });

    test('the anchor stays put, so the range can be widened', () async {
      final repo = repositoryOf(products(6));
      final container = await loaded(repo);
      final notifier = container.read(bulkSelectionProvider.notifier);

      notifier.enter('p1');
      notifier.selectRangeTo('p2');
      notifier.selectRangeTo('p4');

      expect(
          container.read(bulkSelectionProvider).ids, {'p1', 'p2', 'p3', 'p4'});
    });

    test('with no anchor it degrades to a toggle, never a guess', () async {
      final repo = repositoryOf(products(6));
      final container = await loaded(repo);
      final notifier = container.read(bulkSelectionProvider.notifier);

      notifier.selectOnly(const <String>[]); // active, no anchor
      notifier.selectRangeTo('p3');

      expect(container.read(bulkSelectionProvider).ids, {'p3'});
    });

    testWidgets('Shift+click on a card selects the range', (tester) async {
      final repo = repositoryOf(products(6));
      await tester.pumpWidget(grid.harness(repo, width: 400, height: 900));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProductCard).first),
      );
      container.read(bulkSelectionProvider.notifier).enter('p0');
      await tester.pump();

      // Found by NAME, not by index. `find.byType` only sees the cells the
      // sliver has actually built, so an index into it stops meaning "the third
      // product" the moment the grid scrolls.
      final third = find.ancestor(
        of: find.text('Product 2'),
        matching: find.byType(ProductCard),
      );
      await tester.ensureVisible(third);
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(third);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      expect(container.read(bulkSelectionProvider).ids, {'p0', 'p1', 'p2'});
    });

    testWidgets('a plain tap toggles while selecting, and opens when not',
        (tester) async {
      final repo = repositoryOf(products(4));
      final opened = <String>[];
      await tester.pumpWidget(grid.harness(
        repo,
        width: 400,
        height: 900,
        onOpenProduct: (product) => opened.add(product.id),
      ));
      await tester.pumpAndSettle();

      // Not selecting: a tap opens.
      await tester.tap(find.byType(ProductCard).first);
      await tester.pump();
      expect(opened, ['p0']);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProductCard).first),
      );
      container.read(bulkSelectionProvider.notifier).enter();
      await tester.pump();

      // Selecting: the same tap ticks the card instead.
      await tester.tap(find.byType(ProductCard).first);
      await tester.pump();
      expect(opened, ['p0'],
          reason: 'a tap in selection mode must not navigate');
      expect(container.read(bulkSelectionProvider).ids, {'p0'});
    });

    testWidgets('a long-press enters selection mode on its own',
        (tester) async {
      final repo = repositoryOf(products(4));
      await tester.pumpWidget(grid.harness(repo, width: 400, height: 900));
      await tester.pumpAndSettle();

      await tester.longPress(find.byType(ProductCard).at(1));
      await tester.pump();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProductCard).first),
      );
      final selection = container.read(bulkSelectionProvider);
      expect(selection.isActive, isTrue);
      expect(selection.ids, {'p1'});
    });

    testWidgets('checkboxes appear only while selecting', (tester) async {
      final repo = repositoryOf(products(4));
      await tester.pumpWidget(grid.harness(repo, width: 400, height: 900));
      await tester.pumpAndSettle();

      ProductCard cardAt(int index) =>
          tester.widget<ProductCard>(find.byType(ProductCard).at(index));

      // Null, not false: the checkbox is absent rather than drawn unticked.
      expect(cardAt(0).isSelected, isNull);

      ProviderScope.containerOf(tester.element(find.byType(ProductCard).first))
          .read(bulkSelectionProvider.notifier)
          .enter('p0');
      await tester.pump();

      expect(cardAt(0).isSelected, isTrue);
      expect(cardAt(1).isSelected, isFalse);
    });
  });
}
