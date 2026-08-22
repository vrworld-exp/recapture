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
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/catalog_categories_notifier.dart';
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

/// One recorded bulk call.
class BulkCall {
  BulkCall(this.action, this.ids, this.categoryId);

  final BulkProductAction action;
  final List<String> ids;
  final Object? categoryId;
}

/// A catalog repository whose category list the test drives.
class FakeCategoriesRepository implements CatalogRepository {
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

  @override
  Future<CatalogProductPage> list({
    int limit = 20,
    String? cursor,
    String? categoryId,
    ProductType? type,
    ProductAvailability? availability,
    String? query,
    bool includeArchived = false,
  }) async =>
      CatalogProductPage(items: byCategory[categoryId] ?? const []);

  @override
  Future<int> bulk({
    required BulkProductAction action,
    required List<String> ids,
    Object? categoryId,
  }) async {
    bulkCalls.add(BulkCall(action, ids, categoryId));
    return ids.length;
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
        find.text('A category with that name already exists in your catalog.'),
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
