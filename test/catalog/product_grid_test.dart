// test/catalog/product_grid_test.dart
//
// The product grid: responsive columns, server-side debounced search, cursor
// pagination, the four states, and optimistic reorder.
//
// The bugs this file exists to catch are the ones that only appear on the SECOND
// page or the SECOND keystroke — a filter applied locally that stops matching
// once there is more than one page, a stale response appended under a filter the
// user has already changed, a failed append that throws away pages they waited
// for. All of them look fine in a screenshot of page one.
//
// Hermetic: the repository is faked, no HTTP, no Hive.
import 'dart:async';

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/catalog_categories_notifier.dart';
import 'package:recapture/application/catalog/catalog_products_notifier.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart';
import 'package:recapture/data/repositories/catalog_repository.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/business_profile.dart';
import 'package:recapture/domain/entities/catalog.dart';
import 'package:recapture/domain/entities/catalog_category.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/product_availability.dart';
import 'package:recapture/domain/entities/product_sync_status.dart';
import 'package:recapture/domain/entities/product_type.dart';
import 'package:recapture/presentation/screens/catalog/product_grid_section.dart';
import 'package:recapture/presentation/widgets/catalog/product_card.dart';
import 'catalog_repo_analytics_defaults.dart';
import 'catalog_repo_delete_defaults.dart';
import 'catalog_repo_publish_defaults.dart';

import 'catalog_entities_test.dart' as golden;

/// One product, differing from the golden only where a test says so.
CatalogProduct product(
  String id, {
  String? name,
  ProductType type = ProductType.threeD,
  ProductSyncStatus sync = ProductSyncStatus.synced,
  ProductAvailability availability = ProductAvailability.inStock,
  bool archived = false,
  double? price = 100,
  String? thumbnailUrl,
  int position = 0,
}) =>
    CatalogProduct.fromMap(
      golden.productGolden()
        ..['id'] = id
        ..['name'] = name ?? 'Product $id'
        ..['type'] = type.apiValue
        ..['syncStatus'] = sync.apiValue
        ..['availability'] = availability.apiValue
        ..['isArchived'] = archived
        ..['price'] = price
        ..['thumbnailUrl'] = thumbnailUrl
        ..['position'] = position,
    );

/// One recorded call to `list`.
class ListCall {
  ListCall({
    required this.cursor,
    required this.categoryId,
    required this.type,
    required this.availability,
    required this.query,
    required this.includeArchived,
  });

  final String? cursor;
  final String? categoryId;
  final ProductType? type;
  final ProductAvailability? availability;
  final String? query;
  final bool includeArchived;
}

/// A products repository the test drives page by page.
///
/// [respond] is handed the call and returns the page — a function rather than a
/// fixed list so a test can answer differently per cursor, delay one response
/// past another, or throw.
class FakeProductsRepository implements CatalogProductsRepository {
  FakeProductsRepository(this.respond);

  final Future<CatalogProductPage> Function(ListCall call) respond;

  final List<ListCall> calls = [];
  final List<List<String>> reorders = [];

  /// Set to fail the next reorder.
  CatalogFailure? reorderFailure;

  @override
  Future<CatalogProductPage> list({
    int limit = 20,
    String? cursor,
    String? categoryId,
    ProductType? type,
    ProductAvailability? availability,
    String? query,
    bool includeArchived = false,
  }) {
    final call = ListCall(
      cursor: cursor,
      categoryId: categoryId,
      type: type,
      availability: availability,
      query: query,
      includeArchived: includeArchived,
    );
    calls.add(call);
    return respond(call);
  }

  @override
  Future<void> reorder(List<String> orderedIds) async {
    reorders.add(orderedIds);
    if (reorderFailure != null) throw reorderFailure!;
  }

  // ── Not used by these tests ───────────────────────────────────────────────

  @override
  Future<CatalogProduct> get(String id) => throw UnimplementedError();

  @override
  Future<CatalogProduct> create({
    required ProductType type,
    required String name,
    String? description,
    double? price,
    String? categoryId,
    List<String>? tags,
    ProductAvailability? availability,
    bool? featured,
    String? sourceModelId,
    String? imageKey,
  }) =>
      throw UnimplementedError();

  @override
  Future<CatalogProduct> update(
    String id, {
    String? name,
    String? description,
    Object? price,
    Object? categoryId,
    List<String>? tags,
    ProductAvailability? availability,
    bool? featured,
    ProductType? type,
    String? sourceModelId,
    String? imageKey,
  }) =>
      throw UnimplementedError();

  @override
  Future<ProductImageSlot> createImageSlot({
    required ProductImageContentType contentType,
    String? productId,
  }) =>
      throw UnimplementedError();

  @override
  Future<String> uploadImageBytes(
    Uint8List bytes, {
    required String contentType,
    String? productId,
  }) =>
      throw UnimplementedError();

  @override
  Future<CatalogProduct> commitImage(String productId, String key) =>
      throw UnimplementedError();

  @override
  Future<CatalogProduct> duplicate(String id, {String? name}) =>
      throw UnimplementedError();

  @override
  Future<CatalogProduct> archive(String id) => throw UnimplementedError();

  @override
  Future<CatalogProduct> restore(String id) => throw UnimplementedError();

  @override
  Future<void> delete(String id) => throw UnimplementedError();

  @override
  Future<int> bulk({
    required BulkProductAction action,
    required List<String> ids,
    Object? categoryId,
  }) =>
      throw UnimplementedError();
}

/// A catalog repository that serves only the category list these tests need.
class FakeCatalogRepository
    with
        CatalogRepoPublishDefaults,
        CatalogRepoAnalyticsDefaults,
        CatalogRepoDeleteDefaults
    implements CatalogRepository {
  FakeCatalogRepository({this.categories = const <CatalogCategory>[]});

  final List<CatalogCategory> categories;

  @override
  Future<CatalogCategoryList> listCategories() async => CatalogCategoryList(
        categories: categories,
        uncategorizedCount: 0,
      );

  @override
  Future<Catalog?> fetch() async => Catalog.fromMap(golden.catalogGolden());

  @override
  Future<Catalog> create({required String name, String? businessName}) =>
      throw UnimplementedError();

  @override
  Future<Catalog> update({
    String? name,
    String? businessName,
    BusinessContact? contact,
  }) =>
      throw UnimplementedError();

  @override
  Future<ProductImageSlot> createBrandingSlot({
    required BrandingSlot slot,
    required ProductImageContentType contentType,
  }) =>
      throw UnimplementedError();

  @override
  Future<String> uploadBrandingBytes(
    Uint8List bytes, {
    required BrandingSlot slot,
    required String contentType,
  }) =>
      throw UnimplementedError();

  @override
  Future<BusinessProfile> commitBranding({
    required BrandingSlot slot,
    required String key,
  }) =>
      throw UnimplementedError();

  @override
  Future<CatalogCategory> createCategory(String name) =>
      throw UnimplementedError();

  @override
  Future<CatalogCategory> renameCategory(String id, String name) =>
      throw UnimplementedError();

  @override
  Future<int> deleteCategory(String id) => throw UnimplementedError();

  @override
  Future<void> reorderCategories(List<String> orderedIds) =>
      throw UnimplementedError();
}

/// Auth held still — [CatalogCategoriesNotifier] listens to it, and the real
/// notifier would reach for secure storage.
class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

/// The grid inside a scroll view of the given [width], with nothing else on
/// screen — the shell's header is not what these tests are about.
Widget harness(
  FakeProductsRepository repo, {
  double width = 400,
  double height = 800,
  FakeCatalogRepository? catalogRepo,
  ValueChanged<CatalogProduct>? onOpenProduct,
}) =>
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_StubAuth.new),
        catalogProductsRepositoryProvider.overrideWithValue(repo),
        catalogRepositoryProvider
            .overrideWithValue(catalogRepo ?? FakeCatalogRepository()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              height: height,
              child: Consumer(
                builder: (context, ref, _) =>
                    NotificationListener<ScrollNotification>(
                  onNotification: (n) =>
                      ProductGridSection.handleScrollNotification(ref, n),
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      ProductGridSection(
                        onOpenProduct: onOpenProduct ?? (_) {},
                        onAddProduct: () {},
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

CatalogProductPage pageOf(List<CatalogProduct> items, {String? next}) =>
    CatalogProductPage(items: items, nextCursor: next);

void main() {
  group('column count comes from the constraints', () {
    // The rule under test is that a NARROW BROWSER WINDOW is a phone layout.
    // Nothing here knows or cares which platform it is on, which is the point —
    // a `kIsWeb` branch would pass a test at one width and be wrong at another.
    test('breakpoints', () {
      expect(productGridColumns(360), 2);
      expect(productGridColumns(599), 2);
      expect(productGridColumns(600), 3);
      expect(productGridColumns(899), 3);
      expect(productGridColumns(900), 4);
      expect(productGridColumns(1199), 4);
      expect(productGridColumns(1200), 5);
      expect(productGridColumns(1600), 5);
    });

    for (final (width, columns) in [
      (360.0, 2),
      (700.0, 3),
      (1000.0, 4),
      (1400.0, 5),
    ]) {
      testWidgets('renders $columns columns at ${width.toInt()}px',
          (tester) async {
        tester.view.physicalSize = Size(width + 200, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final repo = FakeProductsRepository(
          (_) async => pageOf([for (var i = 0; i < 10; i++) product('p$i')]),
        );
        await tester.pumpWidget(harness(repo, width: width, height: 1000));
        await tester.pumpAndSettle();

        final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
        final delegate =
            grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
        expect(delegate.crossAxisCount, columns);
      });
    }

    testWidgets('a very long name ellipsizes instead of overflowing',
        (tester) async {
      final repo = FakeProductsRepository(
        (_) async => pageOf([
          product('p1', name: 'A ' * 120),
          product('p2'),
        ]),
      );
      await tester.pumpWidget(harness(repo, width: 360));
      await tester.pumpAndSettle();

      // tester.takeException() would carry the overflow assertion if the card
      // had let the text push it past its cell.
      expect(tester.takeException(), isNull);
      final text = tester.widget<Text>(
        find.descendant(
          of: find.byType(ProductCard).first,
          matching: find.textContaining('A A A'),
        ),
      );
      expect(text.maxLines, 2);
      expect(text.overflow, TextOverflow.ellipsis);
    });
  });

  group('the four states', () {
    testWidgets('loading shows skeletons, not an empty state', (tester) async {
      final completer = Completer<CatalogProductPage>();
      final repo = FakeProductsRepository((_) => completer.future);

      await tester.pumpWidget(harness(repo));
      await tester.pump(); // let the first fetch start

      expect(find.text('No products yet'), findsNothing);
      expect(find.text('No products match'), findsNothing);
      expect(find.byType(SliverGrid), findsOneWidget); // the skeleton grid

      completer.complete(pageOf([product('p1')]));
      await tester.pumpAndSettle();
    });

    testWidgets('an empty catalog says "no products yet"', (tester) async {
      final repo = FakeProductsRepository((_) async => pageOf([]));
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      expect(find.text('No products yet'), findsOneWidget);
      // The first-run state must NOT offer to clear filters there are none of.
      expect(find.text('Clear filters'), findsNothing);
    });

    testWidgets('a filter that matches nothing echoes the query',
        (tester) async {
      final repo = FakeProductsRepository(
        (call) async =>
            call.query == null ? pageOf([product('p1')]) : pageOf([]),
      );
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'zebra');
      await tester.pump(kProductSearchDebounce);
      await tester.pumpAndSettle();

      expect(find.text('No products match'), findsOneWidget);
      expect(find.textContaining('zebra'), findsWidgets);
      expect(find.text('Clear filters'), findsOneWidget);
      // …and it is a DIFFERENT state from the first-run one.
      expect(find.text('No products yet'), findsNothing);
    });

    testWidgets('a failed first page shows the error with a retry',
        (tester) async {
      var attempt = 0;
      final repo = FakeProductsRepository((_) async {
        attempt++;
        if (attempt == 1) {
          throw const CatalogFailure(
            code: 'OFFLINE',
            message: "You're offline — check your connection and try again.",
            isOffline: true,
          );
        }
        return pageOf([product('p1', name: 'Walnut Chair')]);
      });

      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      expect(find.textContaining("You're offline"), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(find.text('Walnut Chair'), findsOneWidget);
    });
  });

  group('search', () {
    testWidgets('is debounced and server-side', (tester) async {
      final repo = FakeProductsRepository((_) async => pageOf([product('p1')]));
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();
      expect(repo.calls.length, 1); // the initial load

      await tester.enterText(find.byType(TextField), 'c');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byType(TextField), 'ch');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byType(TextField), 'cha');

      // Still nothing — three keystroke, no requests.
      expect(repo.calls.length, 1);

      await tester.pump(kProductSearchDebounce);
      await tester.pumpAndSettle();

      expect(repo.calls.length, 2);
      // The term went to the SERVER. A client-side filter over the loaded page
      // is the bug this asserts against: it would silently stop matching
      // anything that lives on page 2.
      expect(repo.calls.last.query, 'cha');
      expect(repo.calls.last.cursor, isNull); // pagination reset
    });

    testWidgets('whitespace alone is not a search', (tester) async {
      final repo = FakeProductsRepository((_) async => pageOf([product('p1')]));
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '   ');
      await tester.pump(kProductSearchDebounce);
      await tester.pumpAndSettle();

      expect(repo.calls.last.query, isNull);
    });
  });

  group('pagination', () {
    testWidgets('appends the next page and never double-fetches a cursor',
        (tester) async {
      final repo = FakeProductsRepository((call) async {
        if (call.cursor == null) {
          return pageOf(
            [for (var i = 0; i < 20; i++) product('a$i', position: i)],
            next: 'cursor-2',
          );
        }
        return pageOf(
          [for (var i = 0; i < 5; i++) product('b$i', position: 20 + i)],
        );
      });

      await tester.pumpWidget(harness(repo, width: 400, height: 600));
      await tester.pumpAndSettle();
      expect(repo.calls.length, 1);

      // Several scroll gestures past the prefetch line — the guard is in the
      // notifier, so hammering the boundary must still produce ONE request.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -4000));
      await tester.pump();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -4000));
      await tester.pumpAndSettle();

      final cursorCalls =
          repo.calls.where((c) => c.cursor == 'cursor-2').length;
      expect(cursorCalls, 1);
      expect(repo.calls.where((c) => c.cursor == null).length, 1);
    });

    testWidgets('a failed append keeps the loaded pages and offers a retry',
        (tester) async {
      var appendAttempts = 0;
      final repo = FakeProductsRepository((call) async {
        if (call.cursor == null) {
          return pageOf(
            [for (var i = 0; i < 20; i++) product('a$i', position: i)],
            next: 'cursor-2',
          );
        }
        appendAttempts++;
        if (appendAttempts == 1) {
          throw const CatalogFailure(
            code: 'OFFLINE',
            message: "You're offline — check your connection and try again.",
            isOffline: true,
          );
        }
        return pageOf([product('b0', name: 'Second page item')]);
      });

      await tester.pumpWidget(harness(repo, width: 400, height: 600));
      await tester.pumpAndSettle();

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -6000));
      await tester.pumpAndSettle();

      // Pages 1 is still there. Losing it would mean the user pays for the
      // scroll twice.
      expect(find.byType(ProductCard), findsWidgets);
      expect(find.text('Load more'), findsOneWidget);

      // The footer grew when the error replaced the spinner, so it sits below
      // where the drag left the viewport.
      await tester.ensureVisible(find.text('Load more'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Load more'));
      await tester.pumpAndSettle();

      expect(appendAttempts, 2);
    });
  });

  group('the notifier', () {
    late ProviderContainer container;

    ProviderContainer containerWith(FakeProductsRepository repo) {
      final c = ProviderContainer(
        overrides: [
          authProvider.overrideWith(_StubAuth.new),
          catalogProductsRepositoryProvider.overrideWithValue(repo),
          catalogRepositoryProvider.overrideWithValue(FakeCatalogRepository()),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('a page that arrives after the filter changed is discarded', () async {
      final firstPage = Completer<CatalogProductPage>();
      final repo = FakeProductsRepository((call) {
        if (call.type == null) return firstPage.future;
        return Future.value(pageOf([product('filtered', name: 'Only 3D')]));
      });
      container = containerWith(repo);
      final notifier = container.read(catalogProductsProvider.notifier);
      container.read(catalogProductsProvider); // start the first load
      await Future<void>.delayed(Duration.zero);

      // The filter moves while the unfiltered page is still in flight.
      notifier.setType(ProductType.threeD);
      await Future<void>.delayed(Duration.zero);

      // …and only now does the old request answer.
      firstPage.complete(pageOf([product('stale', name: 'Stale item')]));
      await Future<void>.delayed(Duration.zero);

      final state = container.read(catalogProductsProvider);
      expect(state.items.map((p) => p.name), ['Only 3D']);
      expect(state.items.any((p) => p.name == 'Stale item'), isFalse);
    });

    test('an append that lands after a filter change is not appended',
        () async {
      final append = Completer<CatalogProductPage>();
      final repo = FakeProductsRepository((call) {
        if (call.cursor != null) return append.future;
        if (call.type != null) {
          return Future.value(pageOf([product('f1', name: 'Filtered')]));
        }
        return Future.value(
          pageOf([product('p1', name: 'First')], next: 'cursor-2'),
        );
      });
      container = containerWith(repo);
      final notifier = container.read(catalogProductsProvider.notifier);
      container.read(catalogProductsProvider);
      await Future<void>.delayed(Duration.zero);

      final loadMore = notifier.loadMore();
      notifier.setType(ProductType.imageOnly);
      await Future<void>.delayed(Duration.zero);

      append.complete(pageOf([product('p2', name: 'Stale page two')]));
      await loadMore;
      await Future<void>.delayed(Duration.zero);

      final state = container.read(catalogProductsProvider);
      expect(state.items.map((p) => p.name), ['Filtered']);
    });

    test('a repeated id from a shifted cursor is not duplicated', () async {
      final repo = FakeProductsRepository((call) async {
        if (call.cursor == null) {
          return pageOf(
            [product('p1'), product('p2')],
            next: 'cursor-2',
          );
        }
        // The server re-sends p2 because a position moved under the cursor.
        return pageOf([product('p2'), product('p3')]);
      });
      container = containerWith(repo);
      container.read(catalogProductsProvider);
      await Future<void>.delayed(Duration.zero);
      await container.read(catalogProductsProvider.notifier).loadMore();

      final ids = container.read(catalogProductsProvider).items.map((p) => p.id);
      expect(ids.toList(), ['p1', 'p2', 'p3']);
    });

    test('reorder sends the loaded block and rolls back on failure', () async {
      final repo = FakeProductsRepository(
        (_) async => pageOf([
          product('p1', position: 0),
          product('p2', position: 1),
          product('p3', position: 2),
        ]),
      );
      container = containerWith(repo);
      final notifier = container.read(catalogProductsProvider.notifier);
      container.read(catalogProductsProvider);
      await Future<void>.delayed(Duration.zero);

      // Move the last card to the front (ReorderableListView index convention).
      await notifier.reorder(2, 0);
      expect(
        container.read(catalogProductsProvider).items.map((p) => p.id).toList(),
        ['p3', 'p1', 'p2'],
      );
      expect(repo.reorders.single, ['p3', 'p1', 'p2']);
      // Positions are renumbered locally to match what the server just did.
      expect(
        container.read(catalogProductsProvider).items.map((p) => p.position),
        [0, 1, 2],
      );

      repo.reorderFailure = const CatalogFailure(
        code: 'ID_SET_MISMATCH',
        message: 'One or more products could not be reordered.',
      );
      await expectLater(notifier.reorder(0, 3), throwsA(isA<CatalogFailure>()));

      // Rolled all the way back: the server rejects a mismatched set wholesale,
      // so a failure means nothing moved.
      expect(
        container.read(catalogProductsProvider).items.map((p) => p.id).toList(),
        ['p3', 'p1', 'p2'],
      );
    });

    test('reorder is refused while a filter is applied', () async {
      final repo = FakeProductsRepository(
        (_) async => pageOf([product('p1'), product('p2')]),
      );
      container = containerWith(repo);
      final notifier = container.read(catalogProductsProvider.notifier);
      container.read(catalogProductsProvider);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(catalogProductsProvider).canReorder, isTrue);

      notifier.setCategory('cat-1');
      await Future<void>.delayed(Duration.zero);

      // The server renumbers exactly what it is sent to 0..n-1, so reordering a
      // filtered subset would drag those products ahead of everything else.
      expect(container.read(catalogProductsProvider).canReorder, isFalse);
      await notifier.reorder(1, 0);
      expect(repo.reorders, isEmpty);
    });

    test('the archived chip is a request parameter, not a local filter',
        () async {
      final repo = FakeProductsRepository((_) async => pageOf([product('p1')]));
      container = containerWith(repo);
      final notifier = container.read(catalogProductsProvider.notifier);
      container.read(catalogProductsProvider);
      await Future<void>.delayed(Duration.zero);

      notifier.setIncludeArchived(true);
      await Future<void>.delayed(Duration.zero);

      expect(repo.calls.last.includeArchived, isTrue);
      expect(repo.calls.last.cursor, isNull); // reset, not appended
    });

    test('the uncategorized bucket goes out as the literal "none"', () async {
      final repo = FakeProductsRepository((_) async => pageOf([product('p1')]));
      container = containerWith(repo);
      final notifier = container.read(catalogProductsProvider.notifier);
      container.read(catalogProductsProvider);
      await Future<void>.delayed(Duration.zero);

      notifier.setCategory(kUncategorizedFilterId);
      await Future<void>.delayed(Duration.zero);

      expect(repo.calls.last.categoryId, 'none');
    });

    test('a failed refresh keeps the visible products', () async {
      var attempt = 0;
      final repo = FakeProductsRepository((_) async {
        attempt++;
        if (attempt == 1) return pageOf([product('p1', name: 'Kept')]);
        throw const CatalogFailure(code: 'OFFLINE', message: 'Offline.');
      });
      container = containerWith(repo);
      container.read(catalogProductsProvider);
      await Future<void>.delayed(Duration.zero);

      await container.read(catalogProductsProvider.notifier).refresh();

      final state = container.read(catalogProductsProvider);
      expect(state.items.single.name, 'Kept');
      expect(state.error, isNull); // not a whole-screen failure
      expect(state.appendError, isNotNull); // reported in the footer instead
    });
  });

  // The gesture itself, not just the notifier underneath it. Every bug this
  // group covers passed the notifier tests above and still left the user with a
  // grid whose cards would not move: the drag started, the card followed the
  // finger, and the release did nothing at all.
  group('reordering by drag', () {
    /// Drags the handle of the card at [fromCard] onto the card at [ontoCard],
    /// optionally releasing somewhere else entirely.
    ///
    /// Steps the pointer rather than using `tester.drag`, because the whole
    /// point is what happens BETWEEN the two points — the live shuffle and,
    /// with it, the rebuild that used to throw the drag away.
    Future<void> dragCard(
      WidgetTester tester, {
      required int fromCard,
      required int ontoCard,
      Offset? releaseAt,
      PointerDeviceKind kind = PointerDeviceKind.touch,
    }) async {
      final handles = find.byIcon(Icons.drag_indicator);
      final cards = find.byType(ProductCard);
      final start = tester.getCenter(handles.at(fromCard));
      final end = tester.getCenter(cards.at(ontoCard));

      final gesture = await tester.startGesture(start, kind: kind);
      await tester.pump(const Duration(milliseconds: 30));
      for (var step = 1; step <= 10; step++) {
        await gesture.moveTo(Offset.lerp(start, end, step / 10)!);
        await tester.pump(const Duration(milliseconds: 16));
      }
      if (releaseAt != null) {
        await gesture.moveTo(releaseAt);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();
    }

    /// The ids the grid is showing, in slot order. The feedback under the
    /// finger is a `ProductCard` too, so it is dropped: it is not a slot.
    List<String> visibleIds(WidgetTester tester, {int? take}) {
      final ids = tester
          .widgetList<ProductCard>(find.byType(ProductCard))
          .map((card) => card.product.id)
          .toList();
      return take == null ? ids : ids.take(take).toList();
    }

    FakeProductsRepository sixProducts() => FakeProductsRepository(
          (_) async => pageOf([
            for (var i = 0; i < 6; i++) product('p$i', position: i),
          ]),
        );

    for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
      // One implementation for the APK and the browser: a second code path per
      // pointer kind is how the two builds drift until only one of them works.
      testWidgets('a ${kind.name} drag onto another card writes the new order',
          (tester) async {
        final repo = sixProducts();
        await tester.pumpWidget(harness(repo, width: 400, height: 800));
        await tester.pumpAndSettle();

        await dragCard(tester, fromCard: 0, ontoCard: 1, kind: kind);

        expect(repo.reorders.single.take(3), ['p1', 'p0', 'p2']);
      });
    }

    testWidgets('the cards shuffle under the finger before the drop',
        (tester) async {
      final repo = sixProducts();
      await tester.pumpWidget(harness(repo, width: 400, height: 800));
      await tester.pumpAndSettle();

      final handles = find.byIcon(Icons.drag_indicator);
      final cards = find.byType(ProductCard);
      final start = tester.getCenter(handles.at(0));
      final end = tester.getCenter(cards.at(1));

      final gesture = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 30));
      for (var step = 1; step <= 10; step++) {
        await gesture.moveTo(Offset.lerp(start, end, step / 10)!);
        await tester.pump(const Duration(milliseconds: 16));
      }

      // Mid-drag, with nothing yet written: the grid already shows the order a
      // release would produce. The user aims at a slot they can see.
      expect(visibleIds(tester, take: 2), ['p1', 'p0']);
      expect(repo.reorders, isEmpty);

      await gesture.up();
      await tester.pumpAndSettle();
      expect(repo.reorders.single.take(2), ['p1', 'p0']);
    });

    testWidgets('releasing over the gutter still lands the card', (tester) async {
      // THE bug this whole path exists for. The drop used to be a DragTarget's
      // onAccept, so a release over the 16px gap between two cards — or over
      // anything else that is not a card — hit no target and silently did
      // nothing, which is indistinguishable from a broken feature.
      final repo = sixProducts();
      await tester.pumpWidget(harness(repo, width: 400, height: 800));
      await tester.pumpAndSettle();

      final cards = find.byType(ProductCard);
      final gutter = Offset(
        (tester.getRect(cards.at(0)).right + tester.getRect(cards.at(1)).left) /
            2,
        tester.getRect(cards.at(0)).center.dy,
      );

      await dragCard(tester, fromCard: 0, ontoCard: 1, releaseAt: gutter);

      expect(repo.reorders.single.take(2), ['p1', 'p0']);
    });

    testWidgets('a drag that never leaves its own slot writes nothing',
        (tester) async {
      final repo = sixProducts();
      await tester.pumpWidget(harness(repo, width: 400, height: 800));
      await tester.pumpAndSettle();

      await dragCard(tester, fromCard: 0, ontoCard: 0);

      expect(repo.reorders, isEmpty);
    });

    testWidgets('the grid scrolls itself when the drag reaches the bottom edge',
        (tester) async {
      // Without this a card can only ever be moved as far as the viewport
      // shows, which for a catalog is most of the reordering anyone wants.
      tester.view.physicalSize = const Size(500, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final repo = FakeProductsRepository(
        (_) async => pageOf([
          for (var i = 0; i < 20; i++) product('p$i', position: i),
        ]),
      );
      await tester.pumpWidget(harness(repo, width: 400, height: 700));
      await tester.pumpAndSettle();

      // The filter bar scrolls horizontally, so "the Scrollable" has to name
      // the vertical one explicitly.
      final scrollable = tester.state<ScrollableState>(
        find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable && widget.axisDirection == AxisDirection.down,
        ),
      );
      expect(scrollable.position.pixels, 0);

      final start = tester.getCenter(find.byIcon(Icons.drag_indicator).at(0));
      final gesture = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 30));
      // One move to pick the card up, then into the bottom band and HELD
      // there: the scroll has to keep going while the finger sits still, or
      // reaching the far end of a catalog means a series of little nudges.
      await gesture.moveTo(start + const Offset(0, 40));
      await tester.pump(const Duration(milliseconds: 16));
      await gesture.moveTo(Offset(start.dx, 690));
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(scrollable.position.pixels, greaterThan(0));

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('reordering is off while bulk selection is active',
        (tester) async {
      final repo = sixProducts();
      await tester.pumpWidget(harness(repo, width: 400, height: 800));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.drag_indicator), findsWidgets);

      await tester.longPress(find.byType(ProductCard).first);
      await tester.pumpAndSettle();

      // A drag that moved a card the user meant to tick is not a reorder
      // anyone asked for, so the affordance goes away rather than misfiring.
      expect(find.byIcon(Icons.drag_indicator), findsNothing);
    });
  });

  group('the card', () {
    testWidgets('shows a failed sync without opening the product',
        (tester) async {
      final repo = FakeProductsRepository(
        (_) async => pageOf([
          product('p1', name: 'Broken', sync: ProductSyncStatus.failed),
          product('p2', name: 'Fine'),
        ]),
      );
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      // Feature 68: a product the last publish broke has to be findable by
      // scrolling, not by opening every card in turn.
      expect(find.text('Failed'), findsOneWidget);
    });

    testWidgets('a null price reads as "no price set", never as zero',
        (tester) async {
      final repo = FakeProductsRepository(
        (_) async => pageOf([product('p1', price: null)]),
      );
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      expect(find.text('No price set'), findsOneWidget);
      expect(find.text('₹0'), findsNothing);
    });

    testWidgets('a broken thumbnail URL falls back to the placeholder',
        (tester) async {
      final repo = FakeProductsRepository(
        (_) async => pageOf([
          product('p1', thumbnailUrl: 'https://cdn.example.com/gone.jpg'),
        ]),
      );
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      // The default test HTTP client 400s every image, which is exactly the
      // 404 case: the card must render a placeholder, never a broken-image box.
      expect(tester.takeException(), isNull);
      expect(find.byType(ProductCard), findsOneWidget);
    });

    testWidgets('tapping a card opens that product', (tester) async {
      CatalogProduct? opened;
      final repo = FakeProductsRepository(
        (_) async => pageOf([product('p1', name: 'Walnut Chair')]),
      );
      await tester.pumpWidget(
        harness(repo, onOpenProduct: (p) => opened = p),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Walnut Chair'));
      await tester.pump();

      expect(opened?.id, 'p1');
    });
  });
}
