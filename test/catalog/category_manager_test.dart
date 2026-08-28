// test/catalog/category_manager_test.dart
//
// The category manager (features 22-26).
//
// What this file is really guarding: that deleting a GROUPING never looks like
// deleting the things inside it, that the Uncategorized bucket cannot be
// mutated into a real category, and that a reorder the server rejects does not
// leave the screen quietly disagreeing with it.
//
// Hermetic: both repositories are faked, no HTTP, no Hive.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/catalog_categories_notifier.dart';
import 'package:recapture/application/catalog/category_products_notifier.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart';
import 'package:recapture/data/repositories/catalog_repository.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/business_profile.dart';
import 'package:recapture/domain/entities/catalog.dart';
import 'package:recapture/domain/entities/catalog_category.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/product_availability.dart';
import 'package:recapture/domain/entities/product_type.dart';
import 'package:recapture/presentation/screens/catalog/category_manager_screen.dart';
import 'catalog_repo_analytics_defaults.dart';
import 'catalog_repo_delete_defaults.dart';
import 'catalog_repo_publish_defaults.dart';

import 'catalog_entities_test.dart' as golden;
import 'product_grid_test.dart' as grid;

CatalogCategory category(
  String id, {
  required String name,
  int position = 0,
  int productCount = 0,
}) =>
    CatalogCategory.fromMap(
      golden.categoryGolden()
        ..['id'] = id
        ..['name'] = name
        ..['position'] = position
        ..['productCount'] = productCount,
    );

/// A product that knows which category it is in.
///
/// [grid.product] leaves the golden's own `categoryId` on every row, which is
/// fine for a list the server already filtered — but the add-products picker
/// filters LOCALLY, so its fixtures have to carry the truth the filter reads.
CatalogProduct productIn(
  String id,
  String? categoryId, {
  String? name,
  bool archived = false,
}) =>
    CatalogProduct.fromMap(
      golden.productGolden()
        ..['id'] = id
        ..['name'] = name ?? 'Product $id'
        ..['categoryId'] = categoryId
        ..['isArchived'] = archived,
    );

/// One recorded bulk call.
class BulkCall {
  BulkCall(this.action, this.ids, this.categoryId);

  final BulkProductAction action;
  final List<String> ids;
  final Object? categoryId;
}

/// A catalog repository whose category list the test drives.
class FakeCategoriesRepository
    with
        CatalogRepoPublishDefaults,
        CatalogRepoAnalyticsDefaults,
        CatalogRepoDeleteDefaults
    implements CatalogRepository {
  FakeCategoriesRepository(this.categories, {this.uncategorizedCount = 0});

  List<CatalogCategory> categories;
  int uncategorizedCount;

  final List<List<String>> reorders = [];
  final List<String> creates = [];
  final List<(String, String)> renames = [];
  final List<String> deletes = [];

  CatalogFailure? reorderFailure;
  CatalogFailure? createFailure;

  /// What `deleteCategory` reports as moved — the SERVER's count, which
  /// includes archived products the confirmation's `productCount` does not.
  int movedOnDelete = 0;

  @override
  Future<CatalogCategoryList> listCategories() async => CatalogCategoryList(
        categories: List.of(categories),
        uncategorizedCount: uncategorizedCount,
      );

  @override
  Future<CatalogCategory> createCategory(String name) async {
    creates.add(name);
    if (createFailure != null) throw createFailure!;
    final created = category(
      'new-${creates.length}',
      name: name,
      position: categories.length,
    );
    categories = [...categories, created];
    return created;
  }

  @override
  Future<CatalogCategory> renameCategory(String id, String name) async {
    renames.add((id, name));
    final renamed = categories.firstWhere((c) => c.id == id).copyWith(name: name);
    categories = [
      for (final c in categories)
        if (c.id == id) renamed else c,
    ];
    return renamed;
  }

  @override
  Future<int> deleteCategory(String id) async {
    deletes.add(id);
    categories = [
      for (final c in categories)
        if (c.id != id) c,
    ];
    return movedOnDelete;
  }

  @override
  Future<void> reorderCategories(List<String> orderedIds) async {
    reorders.add(orderedIds);
    if (reorderFailure != null) throw reorderFailure!;
    categories = [
      for (var i = 0; i < orderedIds.length; i++)
        categories.firstWhere((c) => c.id == orderedIds[i]).copyWith(position: i),
    ];
  }

  // ── Not used by these tests ───────────────────────────────────────────────

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
}

/// A products repository that answers per-category lists and records bulk moves.
class FakeCategoryProductsRepository implements CatalogProductsRepository {
  FakeCategoryProductsRepository(this.byCategory);

  /// categoryId (or `'none'`) → its products.
  Map<String, List<CatalogProduct>> byCategory;

  final List<BulkCall> bulkCalls = [];

  /// What the next [bulk] throws, if anything.
  CatalogFailure? bulkFailure;

  /// Pages the way the server does, so a drain that re-reads the first page
  /// sees the category actually shrinking rather than the same rows forever.
  @override
  Future<CatalogProductPage> list({
    int limit = 20,
    String? cursor,
    String? categoryId,
    ProductType? type,
    ProductAvailability? availability,
    String? query,
    bool includeArchived = false,
  }) async {
    // A null [categoryId] is "no category filter at all" — a third thing,
    // distinct from a real id and from `'none'`, and the one the add-products
    // picker asks for. It sees the whole catalog.
    final all = categoryId == null
        ? [for (final products in byCategory.values) ...products]
        : byCategory[categoryId] ?? const <CatalogProduct>[];
    final start = cursor == null ? 0 : int.parse(cursor);
    final end = (start + limit).clamp(0, all.length);
    return CatalogProductPage(
      items: all.sublist(start.clamp(0, all.length), end),
      nextCursor: end < all.length ? '$end' : null,
    );
  }

  @override
  Future<int> bulk({
    required BulkProductAction action,
    required List<String> ids,
    Object? categoryId,
  }) async {
    bulkCalls.add(BulkCall(action, ids, categoryId));
    final failure = bulkFailure;
    if (failure != null) throw failure;
    if (action != BulkProductAction.setCategory) return ids.length;

    // Model the server: the products LEAVE the category they were in. A fake
    // that records the call without moving anything makes a drain look like it
    // never finishes, which is exactly the bug this fake is used to test.
    final destination = categoryId == null ? 'none' : categoryId as String;
    final moved = <CatalogProduct>[];
    final next = <String, List<CatalogProduct>>{};
    byCategory.forEach((key, products) {
      final kept = <CatalogProduct>[];
      for (final product in products) {
        (ids.contains(product.id) ? moved : kept).add(product);
      }
      next[key] = kept;
    });
    next.update(
      destination,
      (existing) => [...existing, ...moved],
      ifAbsent: () => moved,
    );
    byCategory = next;
    return moved.length;
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
  Future<void> reorder(List<String> orderedIds) => throw UnimplementedError();
}

class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

Widget harness(
  FakeCategoriesRepository categories, {
  FakeCategoryProductsRepository? products,
  double width = 500,
  double height = 900,
  ThemeData? theme,
}) =>
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_StubAuth.new),
        catalogRepositoryProvider.overrideWithValue(categories),
        catalogProductsRepositoryProvider.overrideWithValue(
          products ?? FakeCategoryProductsRepository({}),
        ),
      ],
      child: MaterialApp(
        theme: theme,
        home: Center(
          child: SizedBox(
            width: width,
            height: height,
            child: const CategoryManagerScreen(),
          ),
        ),
      ),
    );

/// Focuses the row whose name is [name], so a keyboard shortcut reaches it.
///
/// `Focus.of` from a context BELOW the row's InkWell resolves to the node the
/// InkWell created — which is where a real keyboard user's focus would be.
void focusRow(WidgetTester tester, String name) {
  final context = tester.element(
    find.ancestor(of: find.text(name), matching: find.byType(Row)).first,
  );
  Focus.of(context).requestFocus();
}

Future<void> pressAlt(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  await tester.pumpAndSettle();
}

void main() {
  layoutTests();
  group('reorder (feature 25)', () {
    test('moves optimistically and sends the FULL ordered id list', () async {
      final repo = FakeCategoriesRepository([
        category('a', name: 'Starters', position: 0),
        category('b', name: 'Mains', position: 1),
        category('c', name: 'Desserts', position: 2),
      ]);
      final container = ProviderContainer(overrides: [
        authProvider.overrideWith(_StubAuth.new),
        catalogRepositoryProvider.overrideWithValue(repo),
      ]);
      addTearDown(container.dispose);
      await container.read(catalogCategoriesProvider.future);

      // ReorderableListView's convention: the target counted BEFORE the dragged
      // row is removed, so 0 → 2 is "move the first one after the second".
      await container.read(catalogCategoriesProvider.notifier).reorder(0, 2);

      expect(repo.reorders.single, ['b', 'a', 'c']);
      expect(
        container
            .read(catalogCategoriesProvider)
            .value!
            .categories
            .map((c) => c.id),
        ['b', 'a', 'c'],
      );
    });

    test('rolls back and re-reads when the server refuses', () async {
      // ID_SET_MISMATCH means NOTHING moved — most likely because another
      // device reordered first. Rolling back without re-reading would leave
      // this screen quietly disagreeing with the server.
      final repo = FakeCategoriesRepository([
        category('a', name: 'Starters', position: 0),
        category('b', name: 'Mains', position: 1),
      ]);
      repo.reorderFailure = const CatalogFailure(
        code: CatalogErrorCodes.idSetMismatch,
        message: 'Send every category id exactly once. Reload and try again.',
      );
      final container = ProviderContainer(overrides: [
        authProvider.overrideWith(_StubAuth.new),
        catalogRepositoryProvider.overrideWithValue(repo),
      ]);
      addTearDown(container.dispose);
      await container.read(catalogCategoriesProvider.future);

      await expectLater(
        container.read(catalogCategoriesProvider.notifier).reorder(0, 2),
        throwsA(isA<CatalogFailure>()),
      );
      // Flush the re-read the rollback schedules.
      await Future<void>.delayed(Duration.zero);

      expect(
        container
            .read(catalogCategoriesProvider)
            .value!
            .categories
            .map((c) => c.id),
        ['a', 'b'],
      );
    });

    testWidgets('Alt + arrow reorders without a drag', (tester) async {
      // Drag-only is inaccessible on a desktop, and the browser build is a
      // desktop far more often than the APK is.
      final repo = FakeCategoriesRepository([
        category('a', name: 'Starters', position: 0),
        category('b', name: 'Mains', position: 1),
      ]);
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      focusRow(tester, 'Mains');
      await tester.pump();
      await pressAlt(tester, LogicalKeyboardKey.arrowUp);

      expect(repo.reorders.single, ['b', 'a']);
    });
  });

  group('create and rename (features 22, 23)', () {
    testWidgets('creates and clears the field', (tester) async {
      final repo = FakeCategoriesRepository([]);
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'Desserts');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(repo.creates, ['Desserts']);
      expect(find.text('Desserts'), findsWidgets);
    });

    testWidgets('a duplicate name lands beside the field, not in a toast',
        (tester) async {
      // The backend owns uniqueness within a catalog; its sentence goes where
      // the user typed, so they can fix it without remembering a snackbar.
      final repo = FakeCategoriesRepository([]);
      repo.createFailure = const CatalogFailure(
        code: CatalogErrorCodes.duplicateName,
        message: 'A category with that name already exists in your catalog.',
        statusCode: 409,
      );
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'Mains');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('already uses this name'),
        findsOneWidget,
      );
    });

    testWidgets('cannot send a name past the backend bound', (tester) async {
      // The field itself is bounded to the server's limit, so an over-long
      // paste is capped at the keyboard rather than discovered as a 400 after
      // the user has stopped looking at the field.
      final repo = FakeCategoriesRepository([]);
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextField).first,
        'x' * (kMaxCategoryNameLength + 40),
      );
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(repo.creates.single.length, kMaxCategoryNameLength);
    });

    testWidgets('renames in place', (tester) async {
      final repo = FakeCategoriesRepository([
        category('a', name: 'Startrs', position: 0),
      ]);
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Category options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'Starters');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(repo.renames.single, ('a', 'Starters'));
      // A live category can be renamed; the change is a draft edit like any
      // other, and the copy says so rather than implying it is already public.
      expect(find.textContaining('after you publish'), findsOneWidget);
    });
  });

  group('delete (feature 24)', () {
    testWidgets('an empty category deletes with no destination to choose',
        (tester) async {
      final repo = FakeCategoriesRepository([
        category('a', name: 'Empty One', position: 0),
      ]);
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Category options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.textContaining('This category is empty'), findsOneWidget);
      expect(find.text('Uncategorized'), findsOneWidget); // the fixed row only

      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(repo.deletes, ['a']);
    });

    testWidgets('a non-empty category names the count before it happens',
        (tester) async {
      final repo = FakeCategoriesRepository([
        category('a', name: 'Chairs', position: 0, productCount: 3),
        category('b', name: 'Tables', position: 1),
      ]);
      repo.movedOnDelete = 3;
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Category options').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      // Deleting a grouping must never look like it deleted the things in it.
      expect(
        find.text('The 3 products in this category will move — nothing is '
            'deleted with it. Choose where they go.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Move and delete'));
      await tester.pumpAndSettle();

      expect(repo.deletes, ['a']);
      expect(find.textContaining('3 products moved to Uncategorized'),
          findsOneWidget);
    });

    testWidgets('reassigning to another category moves first, then deletes',
        (tester) async {
      // The endpoint has exactly one behaviour — everything to Uncategorized —
      // so a chosen destination has to be honoured while the category still
      // exists.
      final repo = FakeCategoriesRepository([
        category('a', name: 'Chairs', position: 0, productCount: 2),
        category('b', name: 'Tables', position: 1),
      ]);
      final products = FakeCategoryProductsRepository({
        'a': [grid.product('p1'), grid.product('p2')],
      });
      await tester.pumpWidget(harness(repo, products: products));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Category options').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Tables').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move and delete'));
      await tester.pumpAndSettle();

      expect(products.bulkCalls.single.action, BulkProductAction.setCategory);
      expect(products.bulkCalls.single.ids, ['p1', 'p2']);
      expect(products.bulkCalls.single.categoryId, 'b');
      expect(repo.deletes, ['a']);
      expect(find.textContaining('moved to Tables'), findsOneWidget);
    });

    testWidgets('reassignment drains a category past the loadable ceiling',
        (tester) async {
      // The regression this exists for: the reassignment used to select the
      // LOADED products and move the selection, so a category holding more than
      // kCategoryProductsMax handed its remainder to the delete endpoint — and
      // the delete knows one destination, Uncategorized. The user picked
      // Tables, most of the products went somewhere else, and the toast
      // reported the truncated number as a success.
      const total = kCategoryProductsMax + 1;
      final repo = FakeCategoriesRepository([
        category('a', name: 'Chairs', position: 0, productCount: total),
        category('b', name: 'Tables', position: 1),
      ]);
      final products = FakeCategoryProductsRepository({
        'a': [for (var i = 0; i < total; i++) grid.product('p$i')],
      });
      await tester.pumpWidget(harness(repo, products: products));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Category options').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Tables').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move and delete'));
      await tester.pumpAndSettle();

      // Every product reached the chosen destination...
      expect(products.byCategory['b'], hasLength(total));
      // ...nothing was left for the delete to sweep into Uncategorized...
      expect(products.byCategory['a'], isEmpty);
      expect(products.byCategory['none'] ?? const [], isEmpty);
      // ...every write named Tables, and only then did the category go.
      expect(
        products.bulkCalls.every((call) =>
            call.action == BulkProductAction.setCategory &&
            call.categoryId == 'b'),
        isTrue,
      );
      expect(repo.deletes, ['a']);
      // The count reported is the count that moved, not the count it could see.
      expect(find.textContaining('$total products moved to Tables'),
          findsOneWidget);
    });
  });

  group('the Uncategorized bucket (feature 26)', () {
    testWidgets('is always present, always last, and never mutable',
        (tester) async {
      final repo = FakeCategoriesRepository(
        [category('a', name: 'Chairs', position: 0)],
        uncategorizedCount: 4,
      );
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      expect(find.text('Uncategorized'), findsOneWidget);
      expect(find.text('4 products'), findsOneWidget);

      // One drag handle and one menu — both belong to the real category. The
      // bucket is a null `categoryId`, not a row the server could rename.
      expect(find.byType(ReorderableDragStartListener), findsOneWidget);
      expect(find.byTooltip('Category options'), findsOneWidget);
      expect(
        find.byTooltip('Always last, and cannot be renamed or deleted'),
        findsOneWidget,
      );
    });

    testWidgets('is offered even at zero', (tester) async {
      // It must not appear and disappear as products move in and out of it.
      final repo = FakeCategoriesRepository(
        [category('a', name: 'Chairs', position: 0)],
      );
      await tester.pumpWidget(harness(repo));
      await tester.pumpAndSettle();

      expect(find.text('Uncategorized'), findsOneWidget);
      expect(find.text('0 products'), findsWidgets);
    });
  });

  group('moving products between categories', () {
    testWidgets('multi-select and Move to… bulk-writes the destination',
        (tester) async {
      final repo = FakeCategoriesRepository([
        category('a', name: 'Chairs', position: 0, productCount: 2),
        category('b', name: 'Tables', position: 1),
      ]);
      final products = FakeCategoryProductsRepository({
        'a': [grid.product('p1'), grid.product('p2')],
      });
      // Wide enough for master/detail, so the pane is on screen beside the list.
      await tester.pumpWidget(
        harness(repo, products: products, width: 1000),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Chairs'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      await tester.tap(find.text('Move to…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tables').last);
      await tester.pumpAndSettle();

      expect(products.bulkCalls.single.ids, ['p1']);
      expect(products.bulkCalls.single.categoryId, 'b');
    });
  });

  group('adding products to a category (feature 26)', () {
    // What this group is really guarding: that a category the user has just
    // CREATED is not a dead end. It lands empty, and the only advice the pane
    // used to offer was to go and do it somewhere else.

    testWidgets('an empty category offers the picker, and it leaves out what '
        'is already in it', (tester) async {
      final repo = FakeCategoriesRepository([
        category('a', name: 'Chairs', position: 0),
        category('b', name: 'Tables', position: 1),
      ]);
      final products = FakeCategoryProductsRepository({
        'a': [productIn('p0', 'a', name: 'Walnut stool')],
        'b': [productIn('p1', 'b', name: 'Oak table')],
        'none': [productIn('p2', null, name: 'Loose lamp')],
      });
      // Wide enough for master/detail, so the pane is beside the list.
      await tester.pumpWidget(harness(repo, products: products, width: 1000));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Chairs'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add products'));
      await tester.pumpAndSettle();

      // Scoped to the sheet: the pane underneath is still showing what IS in
      // Chairs, which is the other half of what is being checked here.
      Finder inSheet(Finder finder) =>
          find.descendant(of: find.byType(BottomSheet), matching: finder);

      // Everything that is NOT already in Chairs...
      expect(inSheet(find.text('Oak table')), findsOneWidget);
      expect(inSheet(find.text('Loose lamp')), findsOneWidget);
      expect(inSheet(find.text('Walnut stool')), findsNothing);
      // ...each saying where it would be coming FROM, because a product sits in
      // one category and this is a move, not a copy.
      expect(inSheet(find.textContaining('in Tables')), findsOneWidget);
      expect(inSheet(find.textContaining('in Uncategorized')), findsOneWidget);

      await tester.tap(inSheet(find.text('Oak table')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add 1'));
      await tester.pumpAndSettle();

      expect(products.bulkCalls.single.action, BulkProductAction.setCategory);
      expect(products.bulkCalls.single.ids, ['p1']);
      expect(products.bulkCalls.single.categoryId, 'a');
      expect(find.textContaining('added to Chairs'), findsOneWidget);
      // The pane re-read itself rather than patching a row in.
      expect(find.text('Oak table'), findsOneWidget);
    });

    testWidgets('nothing ticked is not a write', (tester) async {
      final repo = FakeCategoriesRepository([category('a', name: 'Chairs')]);
      final products = FakeCategoryProductsRepository({
        'b': [productIn('p1', 'b', name: 'Oak table')],
      });
      await tester.pumpWidget(harness(repo, products: products, width: 1000));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Chairs'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add products'));
      await tester.pumpAndSettle();

      final add =
          tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Add'));
      expect(add.onPressed, isNull);
      expect(products.bulkCalls, isEmpty);
    });

    testWidgets('an empty catalog and a category that already holds everything '
        'are different sentences', (tester) async {
      final repo = FakeCategoriesRepository([category('a', name: 'Chairs')]);
      final products = FakeCategoryProductsRepository({});
      await tester.pumpWidget(harness(repo, products: products, width: 1000));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Chairs'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add products'));
      await tester.pumpAndSettle();
      expect(find.text('No products yet'), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      // The other empty: there ARE products, and they are all already here. The
      // entry point is the selection bar now, because the pane is not empty.
      final full = FakeCategoriesRepository([
        category('a', name: 'Chairs', productCount: 1),
      ]);
      await tester.pumpWidget(harness(
        full,
        products: FakeCategoryProductsRepository({
          'a': [productIn('p1', 'a', name: 'Oak chair')],
        }),
        width: 1000,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Chairs'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add products'));
      await tester.pumpAndSettle();
      expect(find.text('Everything is already here'), findsOneWidget);
    });

    testWidgets('search narrows the list without dropping what is ticked',
        (tester) async {
      final repo = FakeCategoriesRepository([category('a', name: 'Chairs')]);
      final products = FakeCategoryProductsRepository({
        'b': [
          productIn('p1', 'b', name: 'Oak table'),
          productIn('p2', 'b', name: 'Pine bench'),
        ],
      });
      await tester.pumpWidget(harness(repo, products: products, width: 1000));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Chairs'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add products'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Oak table'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.ancestor(
          of: find.text('Search products'),
          matching: find.byType(TextFormField),
        ),
        'bench',
      );
      await tester.pumpAndSettle();

      expect(find.text('Oak table'), findsNothing);
      expect(find.text('Pine bench'), findsOneWidget);
      // Ticked, filtered out, still counted — the selection is by id, and a
      // search that silently untick things would send the wrong list.
      expect(find.text('1 selected'), findsOneWidget);

      // "Select all" under a filter means all of THESE, and adds to what is
      // already ticked rather than replacing it.
      await tester.tap(find.text('Select these'));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);
    });

    testWidgets('a pick the server no longer has is not confirmed as an add',
        (tester) async {
      final repo = FakeCategoriesRepository([category('a', name: 'Chairs')]);
      final products = FakeCategoryProductsRepository({
        'b': [productIn('p1', 'b', name: 'Oak table')],
      });
      await tester.pumpWidget(harness(repo, products: products, width: 1000));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Chairs'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add products'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Oak table'));
      await tester.pumpAndSettle();

      // Deleted from another device between the picker reading it and the user
      // pressing Add. The server moves nothing, and the count it reports — not
      // the number asked for — is what the screen may claim.
      products.byCategory = {'b': <CatalogProduct>[]};
      await tester.tap(find.text('Add 1'));
      await tester.pumpAndSettle();

      expect(find.textContaining('had already moved'), findsOneWidget);
      expect(find.textContaining('added to Chairs'), findsNothing);
    });

    testWidgets('a refused write says so', (tester) async {
      final repo = FakeCategoriesRepository([category('a', name: 'Chairs')]);
      final products = FakeCategoryProductsRepository({
        'b': [productIn('p1', 'b', name: 'Oak table')],
      })
        ..bulkFailure = const CatalogFailure(
          code: 'INTERNAL',
          message: 'nope',
          statusCode: 500,
        );
      await tester.pumpWidget(harness(repo, products: products, width: 1000));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Chairs'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add products'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Oak table'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add 1'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('could not be added'),
        findsOneWidget,
      );
    });

    testWidgets('the Uncategorized bucket is not somewhere you add TO',
        (tester) async {
      // "Adding" a product to Uncategorized is REMOVING its category, and that
      // already has a name and a place: Move to… on the category it is in.
      final repo = FakeCategoriesRepository([category('a', name: 'Chairs')]);
      await tester.pumpWidget(harness(
        repo,
        products: FakeCategoryProductsRepository({}),
        width: 1000,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Uncategorized'));
      await tester.pumpAndSettle();

      expect(find.text('Nothing in here yet'), findsOneWidget);
      expect(find.text('Add products'), findsNothing);
    });
  });

  group('the create row, under the app\'s own theme', () {
    // The bug this locks down: the theme gives every button
    // `minimumSize: Size(double.infinity, 48)` for the full-width CTA shape,
    // and a content-width button inherited it. As a non-flexible Row child —
    // exactly what "Add" is, beside an Expanded field — the infinite minimum
    // stays infinite, layout throws, and the whole screen paints nothing. The
    // other harness uses Flutter's default theme and cannot see it.
    for (final scale in const [1.0, 1.3]) {
      testWidgets('lays out and aligns at ${scale}x text', (tester) async {
        final errors = <String>[];
        final prior = FlutterError.onError;
        FlutterError.onError = (details) => errors.add(details.exceptionAsString());
        addTearDown(() => FlutterError.onError = prior);

        await tester.pumpWidget(MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: harness(
            FakeCategoriesRepository([category('a', name: 'Chairs')]),
            theme: AppTheme.dark,
          ),
        ));
        await tester.pumpAndSettle();

        expect(errors, isEmpty);
        // The button sits on the row the user is typing in — not below the
        // field's label, which is where a hard-coded offset used to put it.
        final field = find.ancestor(
          of: find.text('New category'),
          matching: find.byType(TextFormField),
        );
        final add = find.widgetWithText(ElevatedButton, 'Add');
        expect(tester.getTopLeft(add).dy, tester.getTopLeft(field).dy);
      });
    }
  });

  testWidgets('says once, quietly, that this order is what customers see',
      (tester) async {
    final repo = FakeCategoriesRepository([
      category('a', name: 'Chairs', position: 0),
    ]);
    await tester.pumpWidget(harness(repo));
    await tester.pumpAndSettle();

    expect(
      find.text('Your public catalog shows categories in this order.'),
      findsOneWidget,
    );
  });
}

/// The screen at a REAL viewport, unwrapped.
///
/// [harness] centres the screen inside a `SizedBox`, which is a bounded box of
/// the test's choosing. That is the wrong shape for asking whether the layout
/// fits a device: it has to be the whole surface, at the size and text scale
/// the device actually hands it.
Widget deviceHarness(
  FakeCategoriesRepository categories, {
  FakeCategoryProductsRepository? products,
  double textScale = 1.0,
}) =>
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_StubAuth.new),
        catalogRepositoryProvider.overrideWithValue(categories),
        catalogProductsRepositoryProvider.overrideWithValue(
          products ?? FakeCategoryProductsRepository({}),
        ),
      ],
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: const CategoryManagerScreen(),
        ),
      ),
    );

/// Layout regressions, at the sizes and text scales a phone really uses.
///
/// The bug this locks down: the empty state is a 96px circle over four stacked
/// text runs, and it sat in an `Expanded` — a TIGHT height — with
/// `fillsViewport: false`, which is the mode for a block that is already inside
/// something scrollable. In a tight slot it could not scroll and could not
/// shrink, so opening the manager with no categories yet overflowed the column
/// and threw. Every assertion here is about the FIRST thing the user sees on a
/// screen they have not populated yet.
void layoutTests() {
  for (final size in const [
    Size(320, 640), // the smallest phone still worth supporting
    Size(360, 800), // the common Android
    Size(1280, 800), // master/detail
  ]) {
    for (final scale in const [1.0, 1.3]) {
      for (final empty in const [true, false]) {
        testWidgets(
            'lays out at ${size.width.toInt()}x${size.height.toInt()}, '
            '${scale}x text, empty=$empty', (tester) async {
          final errors = <String>[];
          final prior = FlutterError.onError;
          FlutterError.onError = (details) =>
              errors.add(details.exceptionAsString());
          addTearDown(() => FlutterError.onError = prior);

          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          await tester.pumpWidget(deviceHarness(
            FakeCategoriesRepository(empty
                ? []
                : [
                    category('a', name: 'Chairs', position: 0, productCount: 2),
                    category('b', name: 'Tables', position: 1),
                  ]),
            textScale: scale,
          ));
          await tester.pumpAndSettle();

          expect(errors, isEmpty, reason: errors.join(' | '));
          // The create field is the point of the empty screen: with no
          // categories there must still be a way to make one.
          expect(find.text('New category'), findsOneWidget);
        });
      }
    }
  }
}
