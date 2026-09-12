// test/rep/rep_category_manager_test.dart
//
// The rep's category manager and the dish list's drag-reorder — the two things
// a rep could not do on a restaurant they had signed up: arrange the sections
// (rename, reorder, delete with reassignment, move dishes between them) and
// arrange the dishes inside the list.
//
// Both write through the DELEGATED repository and nothing else. The fake here
// is in-memory so the screens can be driven end to end: a create shows up as a
// row, a delete with a destination moves first and deletes second, and a drag
// the server refuses snaps back.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/qr_download_file.dart';
import 'package:recapture/application/rep/rep_catalogs_notifier.dart';
import 'package:recapture/application/rep/rep_category_products_notifier.dart';
import 'package:recapture/application/rep/rep_restaurant_notifier.dart';
import 'package:recapture/data/repositories/admin_standee_repository.dart'
    show StandeeQrFormat;
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart'
    show BulkProductAction, ProductImageSlot, kCatalogUnchanged;
import 'package:recapture/data/repositories/rep_repository.dart';
import 'package:recapture/domain/catalog/catalog_error_copy.dart';
import 'package:recapture/domain/catalog/publish_request_result.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/catalog.dart';
import 'package:recapture/domain/entities/catalog_category.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/product_food_type.dart';
import 'package:recapture/domain/entities/product_type.dart';
import 'package:recapture/domain/entities/qr_code_preflight.dart';
import 'package:recapture/domain/entities/qr_standee.dart';
import 'package:recapture/domain/entities/rep_activation.dart';
import 'package:recapture/presentation/screens/rep/rep_catalog_detail_screen.dart';
import 'package:recapture/presentation/screens/rep/rep_category_manager_screen.dart';

import '../catalog/catalog_entities_test.dart' as golden;
import 'rep_repo_catalog_defaults.dart';

const String kCatalogId = '6a83dd464aea89d1d2d28d50';

CatalogCategory category(
  String id, {
  required String name,
  required int position,
  int productCount = 0,
}) =>
    CatalogCategory(
      id: id,
      name: name,
      position: position,
      productCount: productCount,
    );

CatalogProduct dish(
  String id, {
  required String name,
  String? categoryId,
  int position = 0,
}) =>
    CatalogProduct.fromMap({
      ...golden.productGolden(),
      'id': id,
      'type': 'IMAGE_ONLY',
      'name': name,
      'categoryId': categoryId,
      'position': position,
      'glbUrl': null,
      'usdzUrl': null,
      'sourceModelId': null,
      'modelStatus': 'NONE',
    });

class BulkCall {
  const BulkCall(this.action, this.ids, this.categoryId);
  final BulkProductAction action;
  final List<String> ids;
  final Object? categoryId;
}

/// An in-memory delegated restaurant: sections and dishes that the writes
/// really change, so a screen re-reading after a write sees the result.
class FakeRepo with RepRepoCatalogDefaults implements RepRepository {
  FakeRepo({
    List<CatalogCategory> categories = const [],
    List<CatalogProduct> dishes = const [],
  })  : storedCategories = [...categories],
        storedDishes = [...dishes];

  List<CatalogCategory> storedCategories;
  List<CatalogProduct> storedDishes;

  final List<String> created = [];
  final List<String> deletes = [];
  final List<List<String>> categoryReorders = [];
  final List<List<String>> dishReorders = [];
  final List<BulkCall> bulkCalls = [];

  String? createFailureCode;
  CatalogFailure? dishReorderFailure;
  CatalogFailure? bulkFailure;

  int catalogCalls = 0;

  int get _uncategorized =>
      storedDishes.where((d) => d.categoryId == null).length;

  @override
  Future<Catalog> catalog(String catalogId) async {
    catalogCalls++;
    return Catalog.fromMap({...golden.catalogGolden(), 'id': catalogId});
  }

  @override
  Future<CatalogCategoryList> categories(String catalogId) async =>
      CatalogCategoryList(
        categories: [
          for (final c in storedCategories)
            c.copyWith(
              productCount:
                  storedDishes.where((d) => d.categoryId == c.id).length,
            ),
        ],
        uncategorizedCount: _uncategorized,
      );

  @override
  Future<CatalogCategory> createCategory(String catalogId, String name) async {
    if (createFailureCode case final code?) {
      throw CatalogFailure(code: code, message: 'nope');
    }
    created.add(name);
    final row = category(
      'cat_${storedCategories.length + 1}',
      name: name,
      position: storedCategories.length,
    );
    storedCategories = [...storedCategories, row];
    return row;
  }

  @override
  Future<CatalogCategory> renameCategory(
    String catalogId,
    String categoryId,
    String name,
  ) async {
    final renamed = storedCategories
        .firstWhere((c) => c.id == categoryId)
        .copyWith(name: name);
    storedCategories = [
      for (final c in storedCategories)
        if (c.id == categoryId) renamed else c,
    ];
    return renamed;
  }

  @override
  Future<int> deleteCategory(String catalogId, String categoryId) async {
    deletes.add(categoryId);
    final moved = storedDishes.where((d) => d.categoryId == categoryId).length;
    storedDishes = [
      for (final d in storedDishes)
        if (d.categoryId == categoryId) d.copyWith(categoryId: null) else d,
    ];
    storedCategories = [
      for (final c in storedCategories)
        if (c.id != categoryId) c,
    ];
    return moved;
  }

  @override
  Future<void> reorderCategories(
    String catalogId,
    List<String> orderedIds,
  ) async {
    categoryReorders.add(orderedIds);
    storedCategories = [
      for (final id in orderedIds)
        storedCategories.firstWhere((c) => c.id == id),
    ];
  }

  @override
  Future<List<CatalogProduct>> products(String catalogId) async =>
      [...storedDishes];

  @override
  Future<void> reorderProducts(
    String catalogId,
    List<String> orderedIds,
  ) async {
    dishReorders.add(orderedIds);
    if (dishReorderFailure != null) throw dishReorderFailure!;
    storedDishes = [
      for (var i = 0; i < orderedIds.length; i++)
        storedDishes
            .firstWhere((d) => d.id == orderedIds[i])
            .copyWith(position: i),
    ];
  }

  @override
  Future<int> bulkProducts(
    String catalogId, {
    required BulkProductAction action,
    required List<String> ids,
    Object? categoryId = kCatalogUnchanged,
  }) async {
    bulkCalls.add(BulkCall(action, ids, categoryId));
    if (bulkFailure != null) throw bulkFailure!;
    var affected = 0;
    storedDishes = [
      for (final d in storedDishes)
        if (ids.contains(d.id))
          (() {
            affected++;
            return d.copyWith(categoryId: categoryId);
          })()
        else
          d,
    ];
    return affected;
  }

  // ── Unexercised ───────────────────────────────────────────────────────────

  @override
  Future<QrCodePreflight> preflight(String code) => throw UnimplementedError();

  @override
  Future<RepActivation> activate(RepActivationRequest request) =>
      throw UnimplementedError();

  @override
  Future<List<RepCatalogSummary>> catalogs() async => const [];

  @override
  Future<CatalogProduct> createProduct(
    String catalogId, {
    required ProductType type,
    required String name,
    String? description,
    double? price,
    String? sourceModelId,
    String? imageKey,
    String? categoryId,
  ProductFoodType? foodType,
  }) =>
      throw UnimplementedError();

  @override
  Future<String> uploadImageBytes(
    String catalogId,
    Uint8List bytes, {
    required String contentType,
    String? productId,
  }) =>
      throw UnimplementedError();

  @override
  Future<ProductImageSlot> createImageSlot(
    String catalogId, {
    required String contentType,
  }) =>
      throw UnimplementedError();

  @override
  Future<PublishRequestResult> publish(
    String catalogId, {
    String? idempotencyKey,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> attachCode(String catalogId, String code) =>
      throw UnimplementedError();

  @override
  Future<void> retireCode(String code) => throw UnimplementedError();

  @override
  Future<List<RepStandee>> standees() async => const [];

  @override
  Future<QrDownloadFile> standeeFile(
    String code, {
    StandeeQrFormat format = StandeeQrFormat.pdf,
    int? size,
  }) =>
      throw UnimplementedError();
}

class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

Widget harness(
  FakeRepo repo,
  Widget child, {
  double width = 500,
  double height = 900,
}) =>
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_StubAuth.new),
        repRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(
        home: Center(
          child: SizedBox(width: width, height: height, child: child),
        ),
      ),
    );

Widget manager(FakeRepo repo, {double width = 500}) => harness(
      repo,
      const RepCategoryManagerScreen(catalogId: kCatalogId),
      width: width,
    );

Widget dishes(FakeRepo repo, {double width = 500}) => harness(
      repo,
      const RepCatalogDetailScreen(catalogId: kCatalogId),
      width: width,
    );

/// Focuses the row whose name is [name], so a keyboard shortcut reaches it.
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
  group('the door from the dish list', () {
    testWidgets('the dish list offers Categories beside Preview and Details',
        (tester) async {
      final repo = FakeRepo(dishes: [dish('d1', name: 'Dal')]);
      await tester.pumpWidget(dishes(repo));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('rep_categories')), findsOneWidget);
      expect(find.byTooltip('Categories'), findsOneWidget);
    });
  });

  group('sections on a delegated restaurant', () {
    testWidgets('renders the sections, the bucket, and the order sentence',
        (tester) async {
      final repo = FakeRepo(
        categories: [
          category('a', name: 'Starters', position: 0),
          category('b', name: 'Mains', position: 1),
        ],
        dishes: [dish('d1', name: 'Papad', categoryId: 'a')],
      );
      await tester.pumpWidget(manager(repo));
      await tester.pumpAndSettle();

      expect(find.text('Starters'), findsOneWidget);
      expect(find.text('Mains'), findsOneWidget);
      expect(find.text('1 dish'), findsOneWidget);
      expect(
          find.byKey(const ValueKey('rep_uncategorized_row')), findsOneWidget);
      expect(
        find.text("The restaurant's menu shows categories in this order."),
        findsOneWidget,
      );
      // One handle per real section, none on the bucket.
      expect(find.byIcon(Icons.drag_indicator), findsNWidgets(2));
    });

    testWidgets('creates through the delegated repository and clears the field',
        (tester) async {
      final repo = FakeRepo();
      await tester.pumpWidget(manager(repo));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('rep_new_category_field')),
        'Desserts',
      );
      await tester.tap(find.byKey(const ValueKey('rep_new_category_add')));
      await tester.pumpAndSettle();

      expect(repo.created, ['Desserts']);
      expect(find.text('Desserts'), findsOneWidget);
      expect(find.textContaining('added.'), findsOneWidget);
    });

    testWidgets('a duplicate name lands beside the field', (tester) async {
      final repo = FakeRepo()..createFailureCode = 'DUPLICATE_NAME';
      await tester.pumpWidget(manager(repo));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('rep_new_category_field')),
        'Starters',
      );
      await tester.tap(find.byKey(const ValueKey('rep_new_category_add')));
      await tester.pumpAndSettle();

      expect(
        find.text(catalogErrorSentence('DUPLICATE_NAME')),
        findsOneWidget,
      );
    });

    testWidgets('renames in place', (tester) async {
      final repo = FakeRepo(
        categories: [category('a', name: 'Starters', position: 0)],
      );
      await tester.pumpWidget(manager(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('rep_category_menu_a')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('rep_rename_category_field')),
        'Small plates',
      );
      await tester.tap(find.byKey(const ValueKey('rep_rename_category_save')));
      await tester.pumpAndSettle();

      expect(repo.storedCategories.single.name, 'Small plates');
      expect(find.textContaining('Renamed to'), findsOneWidget);
    });

    testWidgets('Alt + arrow reorders and sends the FULL ordered id list',
        (tester) async {
      final repo = FakeRepo(
        categories: [
          category('a', name: 'Starters', position: 0),
          category('b', name: 'Mains', position: 1),
        ],
      );
      await tester.pumpWidget(manager(repo));
      await tester.pumpAndSettle();

      focusRow(tester, 'Mains');
      await tester.pump();
      await pressAlt(tester, LogicalKeyboardKey.arrowUp);

      expect(repo.categoryReorders.single, ['b', 'a']);
      expect(find.textContaining('Mains moved.'), findsOneWidget);
    });

    testWidgets('an empty section deletes with no destination to choose',
        (tester) async {
      final repo = FakeRepo(
        categories: [category('a', name: 'Starters', position: 0)],
      );
      await tester.pumpWidget(manager(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('rep_category_menu_a')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.text('Move and delete'), findsNothing);
      await tester
          .tap(find.byKey(const ValueKey('rep_delete_category_confirm')));
      await tester.pumpAndSettle();

      expect(repo.deletes, ['a']);
      expect(repo.bulkCalls, isEmpty);
      expect(find.text('Starters deleted.'), findsOneWidget);
    });

    testWidgets('reassigning to another section moves FIRST, then deletes',
        (tester) async {
      // The endpoint has exactly one behaviour — everything to Uncategorized —
      // so a chosen destination has to be honoured while the section still
      // exists, and through the rep's own bulk door.
      final repo = FakeRepo(
        categories: [
          category('a', name: 'Starters', position: 0),
          category('b', name: 'Mains', position: 1),
        ],
        dishes: [
          dish('d1', name: 'Papad', categoryId: 'a'),
          dish('d2', name: 'Soup', categoryId: 'a'),
          dish('d3', name: 'Dal', categoryId: 'b'),
        ],
      );
      await tester.pumpWidget(manager(repo));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('rep_category_menu_a')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.textContaining('The 2 dishes in this category will move'),
          findsOneWidget);
      await tester.tap(find.text('Mains').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move and delete'));
      await tester.pumpAndSettle();

      expect(repo.bulkCalls.single.action, BulkProductAction.setCategory);
      expect(repo.bulkCalls.single.ids, ['d1', 'd2']);
      expect(repo.bulkCalls.single.categoryId, 'b');
      expect(repo.deletes, ['a']);
      expect(
        repo.storedDishes.where((d) => d.categoryId == 'b').length,
        3,
      );
      expect(find.textContaining('2 dishes moved to Mains'), findsOneWidget);
    });

    testWidgets('multi-select and Move to… bulk-writes the destination',
        (tester) async {
      final repo = FakeRepo(
        categories: [
          category('a', name: 'Starters', position: 0),
          category('b', name: 'Mains', position: 1),
        ],
        dishes: [
          dish('d1', name: 'Papad', categoryId: 'a'),
          dish('d2', name: 'Soup', categoryId: 'a'),
        ],
      );
      // Wide enough for master/detail, so the pane is beside the list.
      await tester.pumpWidget(manager(repo, width: 1000));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('rep_category_row_a')));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('rep_category_move_to')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mains').last);
      await tester.pumpAndSettle();

      expect(repo.bulkCalls.single.ids, ['d1']);
      expect(repo.bulkCalls.single.categoryId, 'b');
      expect(find.textContaining('1 dish moved to Mains'), findsOneWidget);
    });

    testWidgets(
        'an empty section offers the picker, which leaves out what is '
        'already in it', (tester) async {
      final repo = FakeRepo(
        categories: [
          category('a', name: 'Starters', position: 0),
          category('b', name: 'Mains', position: 1),
        ],
        dishes: [
          dish('d1', name: 'Papad', categoryId: 'a'),
          dish('d2', name: 'Dal', categoryId: 'b'),
          dish('d3', name: 'Lassi'),
        ],
      );
      await tester.pumpWidget(manager(repo, width: 1000));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('rep_category_row_a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rep_category_add_dishes')));
      await tester.pumpAndSettle();

      // Papad is already in Starters; Dal (in Mains) and Lassi (nowhere) are.
      // Scoped to the SHEET: the pane behind it renders Papad's row under the
      // same key, and that one is the section's own list, not the picker's.
      Finder inSheet(String key) => find.descendant(
            of: find.byType(BottomSheet),
            matching: find.byKey(ValueKey(key)),
          );
      expect(find.text('Add to Starters'), findsOneWidget);
      expect(inSheet('rep_category_dish_d1'), findsNothing);
      expect(inSheet('rep_category_dish_d2'), findsOneWidget);
      expect(inSheet('rep_category_dish_d3'), findsOneWidget);
      expect(find.textContaining('in Mains'), findsOneWidget);
      expect(find.textContaining('in Uncategorized'), findsOneWidget);

      await tester.tap(inSheet('rep_category_dish_d3'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('rep_add_dishes_confirm')));
      await tester.pumpAndSettle();

      expect(repo.bulkCalls.single.ids, ['d3']);
      expect(repo.bulkCalls.single.categoryId, 'a');
      expect(find.textContaining('1 dish added to Starters'), findsOneWidget);
    });
  });

  group('the dishes drag', () {
    testWidgets('every row carries a handle and the order sentence is said',
        (tester) async {
      final repo = FakeRepo(dishes: [
        dish('d1', name: 'Dal', position: 0),
        dish('d2', name: 'Naan', position: 1),
      ]);
      await tester.pumpWidget(dishes(repo));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('rep_dish_handle_d1')), findsOneWidget);
      expect(find.byKey(const ValueKey('rep_dish_handle_d2')), findsOneWidget);
      expect(find.textContaining('Drag the handle'), findsOneWidget);
    });

    testWidgets('Alt + arrow moves a dish and sends the FULL ordered list',
        (tester) async {
      final repo = FakeRepo(dishes: [
        dish('d1', name: 'Dal', position: 0),
        dish('d2', name: 'Naan', position: 1),
        dish('d3', name: 'Rice', position: 2),
      ]);
      await tester.pumpWidget(dishes(repo));
      await tester.pumpAndSettle();

      focusRow(tester, 'Naan');
      await tester.pump();
      await pressAlt(tester, LogicalKeyboardKey.arrowUp);

      expect(repo.dishReorders.single, ['d2', 'd1', 'd3']);
      expect(find.textContaining('Naan moved.'), findsOneWidget);
      // The document behind the publish bar is re-read: a reorder is a draft
      // change, and the bar must not go on claiming everything is live.
      expect(repo.catalogCalls, greaterThan(1));
    });

    testWidgets('a refused order snaps back and says why', (tester) async {
      final repo = FakeRepo(dishes: [
        dish('d1', name: 'Dal', position: 0),
        dish('d2', name: 'Naan', position: 1),
      ])
        ..dishReorderFailure = const CatalogFailure(
          code: 'ID_SET_MISMATCH',
          message: 'nope',
        );
      await tester.pumpWidget(dishes(repo));
      await tester.pumpAndSettle();

      focusRow(tester, 'Naan');
      await tester.pump();
      await pressAlt(tester, LogicalKeyboardKey.arrowUp);

      expect(repo.dishReorders.single, ['d2', 'd1']);
      expect(
          find.textContaining('That order could not be saved'), findsOneWidget);
      // Back where it was: the fake never applied the write.
      final rows = tester
          .widgetList<InkWell>(find.byWidgetPredicate(
            (w) =>
                w is InkWell &&
                w.key is ValueKey<String> &&
                (w.key as ValueKey<String>).value.startsWith('rep_dish_row_'),
          ))
          .map((w) => (w.key as ValueKey<String>).value)
          .toList();
      expect(rows, ['rep_dish_row_d1', 'rep_dish_row_d2']);
    });

    test('the notifier reorders optimistically and rolls back on failure',
        () async {
      final repo = FakeRepo(dishes: [
        dish('d1', name: 'Dal', position: 0),
        dish('d2', name: 'Naan', position: 1),
        dish('d3', name: 'Rice', position: 2),
      ]);
      final container = ProviderContainer(overrides: [
        authProvider.overrideWith(_StubAuth.new),
        repRepositoryProvider.overrideWithValue(repo),
      ]);
      addTearDown(container.dispose);
      final provider = repCatalogProductsProvider(kCatalogId);
      await container.read(provider.future);

      // ReorderableListView's convention: 0 → 2 is "move the first one after
      // the second". Landed on index 1.
      final landed = await container.read(provider.notifier).reorder(0, 2);
      expect(landed, 1);
      expect(repo.dishReorders.single, ['d2', 'd1', 'd3']);
      expect(
        container.read(provider).value!.map((d) => d.id),
        ['d2', 'd1', 'd3'],
      );

      // A drag that ended where it started is not a write.
      expect(await container.read(provider.notifier).reorder(1, 2), isNull);
      expect(repo.dishReorders, hasLength(1));

      repo.dishReorderFailure =
          const CatalogFailure(code: 'ID_SET_MISMATCH', message: 'nope');
      await expectLater(
        container.read(provider.notifier).reorder(2, 0),
        throwsA(isA<CatalogFailure>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(provider).value!.map((d) => d.id),
        ['d2', 'd1', 'd3'],
      );
    });
  });

  group('the section pane reads the delegated menu, narrowed', () {
    test('filters by section, and null is the Uncategorized bucket', () async {
      final repo = FakeRepo(dishes: [
        dish('d1', name: 'Dal', categoryId: 'a'),
        dish('d2', name: 'Naan'),
        dish('d3', name: 'Rice', categoryId: 'a'),
      ]);
      final container = ProviderContainer(overrides: [
        authProvider.overrideWith(_StubAuth.new),
        repRepositoryProvider.overrideWithValue(repo),
      ]);
      addTearDown(container.dispose);

      final inA = repCategoryProductsProvider(
        const RepCategoryKey(catalogId: kCatalogId, categoryId: 'a'),
      );
      final bucket = repCategoryProductsProvider(
        const RepCategoryKey(catalogId: kCatalogId, categoryId: null),
      );
      final pinA = container.listen(inA, (_, __) {});
      final pinB = container.listen(bucket, (_, __) {});
      addTearDown(pinA.close);
      addTearDown(pinB.close);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(inA).items.map((d) => d.id), ['d1', 'd3']);
      expect(container.read(bucket).items.map((d) => d.id), ['d2']);
    });

    test('draining a section moves everything and re-reads the surroundings',
        () async {
      final repo = FakeRepo(
        categories: [
          category('a', name: 'Starters', position: 0),
          category('b', name: 'Mains', position: 1),
        ],
        dishes: [
          dish('d1', name: 'Dal', categoryId: 'a'),
          dish('d2', name: 'Naan', categoryId: 'a'),
        ],
      );
      final container = ProviderContainer(overrides: [
        authProvider.overrideWith(_StubAuth.new),
        repRepositoryProvider.overrideWithValue(repo),
      ]);
      addTearDown(container.dispose);

      final provider = repCategoryProductsProvider(
        const RepCategoryKey(catalogId: kCatalogId, categoryId: 'a'),
      );
      final pin = container.listen(provider, (_, __) {});
      addTearDown(pin.close);
      // The section counts the manager renders, held so the refresh lands.
      final counts = container.listen(
        repCategoriesProvider(kCatalogId),
        (_, __) {},
      );
      addTearDown(counts.close);
      await container.read(repCategoriesProvider(kCatalogId).future);

      final moved = await container.read(provider.notifier).moveAllTo('b');
      await Future<void>.delayed(Duration.zero);

      expect(moved, 2);
      expect(repo.bulkCalls.single.ids, ['d1', 'd2']);
      expect(repo.bulkCalls.single.categoryId, 'b');
      expect(container.read(provider).items, isEmpty);
      expect(
        container
            .read(repCategoriesProvider(kCatalogId))
            .value!
            .categories
            .firstWhere((c) => c.id == 'b')
            .productCount,
        2,
      );
    });
  });
}
