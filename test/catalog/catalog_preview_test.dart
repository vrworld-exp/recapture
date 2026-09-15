// test/catalog/catalog_preview_test.dart
//
// The catalog preview (feature 5, task T-026).
//
// What this file exists to catch, in order of how badly the alternative goes:
//   • A preview that reads the LIVE page instead of the draft. Mirage does not
//     have the draft, so such a preview would show the last publish and call it
//     "your catalog" — the single worst thing this screen could do. Pinned by
//     asserting the composition takes its products from the ReCapture products
//     repository and nothing else, and that it reads EVERY page of them.
//   • A gate rule that disagrees with the server's. The client set has to be a
//     strict SUBSET of the backend's `evaluatePublishGates`; the cases below
//     mirror `gateProduct` and `gateDuplicateNames` one for one.
//   • A preview that shows authoring-only state (sync pills, out-of-stock,
//     featured) inside the page frame, teaching the user that customers see it.
//   • An archived product previewed onto a page it will never appear on.
//
// Hermetic: every repository is faked. No HTTP, no Hive.
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/data/repositories/business_profile_repository.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart';
import 'package:recapture/data/repositories/catalog_repository.dart';
import 'package:recapture/domain/catalog/catalog_preview.dart';
import 'package:recapture/domain/catalog/publish_gate.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/business_profile.dart';
import 'package:recapture/domain/entities/catalog.dart';
import 'package:recapture/domain/entities/catalog_category.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/product_food_type.dart';
import 'package:recapture/domain/entities/product_type.dart';
import 'package:recapture/presentation/screens/catalog/catalog_preview_screen.dart';
import 'package:recapture/presentation/widgets/catalog/preview_product_card.dart';
import 'catalog_repo_analytics_defaults.dart';
import 'catalog_repo_delete_defaults.dart';
import 'catalog_repo_publish_defaults.dart';

import 'catalog_entities_test.dart' as golden;
import 'product_grid_test.dart'
    show FakeProductsRepository, ListCall, pageOf, product;

/// A category, differing from the golden only where a test says so.
CatalogCategory category(String id, {required String name, int position = 0}) =>
    CatalogCategory.fromMap(
      golden.categoryGolden()
        ..['id'] = id
        ..['name'] = name
        ..['position'] = position,
    );

CatalogProduct inCategory(CatalogProduct base, String? categoryId) =>
    CatalogProduct.fromMap(base.toMap()..['categoryId'] = categoryId);

CatalogProduct withGlb(CatalogProduct base, String? glbUrl) =>
    CatalogProduct.fromMap(base.toMap()..['glbUrl'] = glbUrl);

Catalog catalogNamed(String name) =>
    Catalog.fromMap(golden.catalogGolden()..['name'] = name);

class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

/// A catalog repository the preview tests drive directly.
class FakePreviewCatalogRepo
    with
        CatalogRepoPublishDefaults,
        CatalogRepoAnalyticsDefaults,
        CatalogRepoDeleteDefaults
    implements CatalogRepository {
  FakePreviewCatalogRepo({
    Catalog? catalog,
    this.categories = const <CatalogCategory>[],
  }) : catalog = catalog ?? Catalog.fromMap(golden.catalogGolden());

  /// The first-run state: the account has no catalog at all.
  FakePreviewCatalogRepo.none({this.categories = const <CatalogCategory>[]})
      : catalog = null;

  Catalog? catalog;
  List<CatalogCategory> categories;
  int fetchCalls = 0;

  @override
  Future<Catalog?> fetch() async {
    fetchCalls++;
    return catalog;
  }

  @override
  Future<CatalogCategoryList> listCategories() async => CatalogCategoryList(
        categories: categories,
        uncategorizedCount: 0,
      );

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

class FakePreviewProfileRepo implements BusinessProfileRepository {
  FakePreviewProfileRepo({this.profile, this.failure});

  BusinessProfile? profile;

  /// Set to fail the read — the preview must degrade, not die.
  Object? failure;

  @override
  Future<BusinessProfile?> fetch() async {
    if (failure != null) throw failure!;
    return profile ?? BusinessProfile.fromMap(golden.profileGolden());
  }

  @override
  Future<BusinessProfile> update({
    String? name,
    String? businessName,
    BusinessContact? contact,
  }) =>
      throw UnimplementedError();
}

Widget harness({
  required FakePreviewCatalogRepo catalogRepo,
  required FakeProductsRepository productsRepo,
  FakePreviewProfileRepo? profileRepo,
  Size size = const Size(400, 900),
}) =>
    ProviderScope(
      overrides: [
        authProvider.overrideWith(_StubAuth.new),
        catalogRepositoryProvider.overrideWithValue(catalogRepo),
        catalogProductsRepositoryProvider.overrideWithValue(productsRepo),
        businessProfileRepositoryProvider
            .overrideWithValue(profileRepo ?? FakePreviewProfileRepo()),
      ],
      child: MaterialApp(
        home: Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: const CatalogPreviewScreen(),
          ),
        ),
      ),
    );

/// Pumps [widget] on a surface as tall as the harness box.
///
/// The box alone is not enough: the ROOT stays at the default 800x600, and a
/// chip laid out below that is off the render tree's bounds — every tap on it
/// misses, whatever the box around it measures.
Future<void> pumpTall(WidgetTester tester, Widget widget) async {
  tester.view.physicalSize = const Size(400, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(widget);
}

/// Taps the Sort / Show chip with [key], scrolling its row to it first: the
/// rows scroll sideways, and the later chips start past a phone's right edge.
Future<void> tapChip(WidgetTester tester, String key) async {
  final chip = find.byKey(ValueKey(key));
  await tester.ensureVisible(chip);
  await tester.tap(chip);
  await tester.pumpAndSettle();
}

void main() {
  group('draft gates mirror the server rules', () {
    test('a 3D product with no model and no preview trips BOTH', () {
      final broken = withGlb(
        product('p1', name: 'Chair', thumbnailUrl: null),
        null,
      );

      final gates = evaluateDraftGates(
        catalogName: 'Cafe',
        products: [broken],
      );

      expect(
        gates.map((g) => g.code),
        containsAll([
          PublishGateCode.productAssetMissing,
          PublishGateCode.productThumbnailMissing,
        ]),
      );
      // Every product gate names the product, so the preview can put it on the
      // right card and the publish checklist can deep-link to it.
      expect(gates.every((g) => g.productId == 'p1'), isTrue);
    });

    test('an image-only product needs only its photo', () {
      final gates = evaluateDraftGates(
        catalogName: 'Cafe',
        products: [
          product('p1', type: ProductType.imageOnly, thumbnailUrl: null),
        ],
      );

      expect(gates.map((g) => g.code), [PublishGateCode.productAssetMissing]);
      expect(gates.single.message, contains('no photo'));
    });

    test('a complete product trips nothing', () {
      expect(
        evaluateDraftGates(
          catalogName: 'Cafe',
          products: [product('p1', thumbnailUrl: 'https://cdn/x.jpg')],
        ),
        isEmpty,
      );
    });

    test('duplicate names flag EVERY row involved, case-insensitively', () {
      final gates = evaluateDraftGates(
        catalogName: 'Cafe',
        products: [
          product('p1', name: 'Chair', thumbnailUrl: 'https://cdn/a.jpg'),
          product('p2', name: '  chair ', thumbnailUrl: 'https://cdn/b.jpg'),
          product('p3', name: 'Table', thumbnailUrl: 'https://cdn/c.jpg'),
        ],
      );

      final duplicates = [
        for (final gate in gates)
          if (gate.code == PublishGateCode.productNameDuplicate) gate.productId,
      ];
      // Both rows, not just the second — the user cannot know which one the
      // publish would have dropped.
      expect(duplicates, unorderedEquals(['p1', 'p2']));
    });

    test('an empty catalog and a blank name are catalog-level gates', () {
      final gates = evaluateDraftGates(catalogName: '   ', products: const []);

      expect(
        gates.map((g) => g.code),
        containsAll([
          PublishGateCode.catalogEmpty,
          PublishGateCode.catalogNameMissing,
        ]),
      );
      expect(gates.every((g) => g.productId == null), isTrue);
    });

    test('gates the client cannot decide are ABSENT, never guessed', () {
      // PRODUCT_MODEL_NOT_READY needs the source ProjectModel's status, which
      // is not on the product DTO. Under-reporting is the safe direction: the
      // publish endpoint re-runs the full set.
      final gates = evaluateDraftGates(
        catalogName: 'Cafe',
        products: [product('p1', thumbnailUrl: 'https://cdn/a.jpg')],
      );
      expect(
        gates.map((g) => g.code),
        isNot(contains(PublishGateCode.productModelNotReady)),
      );
    });
  });

  group('composition', () {
    CatalogPreview compose({
      List<CatalogCategory> categories = const [],
      List<CatalogProduct> products = const [],
      String name = 'Cafe Mocha',
    }) =>
        CatalogPreview.compose(
          catalog: catalogNamed(name),
          profile: null,
          categories: categories,
          products: products,
        );

    test('sections follow category position, Uncategorized last', () {
      final preview = compose(
        categories: [
          category('c2', name: 'Mains', position: 1),
          category('c1', name: 'Starters', position: 0),
        ],
        products: [
          inCategory(product('p1', thumbnailUrl: 'https://cdn/a.jpg'), 'c2'),
          inCategory(product('p2', thumbnailUrl: 'https://cdn/b.jpg'), 'c1'),
          inCategory(product('p3', thumbnailUrl: 'https://cdn/c.jpg'), null),
        ],
      );

      expect(
        preview.sections.map((s) => s.title),
        ['Starters', 'Mains', 'Uncategorized'],
      );
      expect(preview.sections.last.isUncategorized, isTrue);
    });

    test('an empty category gets no section — the public page has no tab', () {
      final preview = compose(
        categories: [
          category('c1', name: 'Starters', position: 0),
          category('c2', name: 'Nothing here', position: 1),
        ],
        products: [
          inCategory(product('p1', thumbnailUrl: 'https://cdn/a.jpg'), 'c1'),
        ],
      );

      expect(preview.sections.map((s) => s.title), ['Starters']);
    });

    test('but the empty one is still NAMED, so it cannot look like it vanished',
        () {
      // The other half of the rule above. Dropping the section is right — the
      // public page will not render a heading with nothing under it — but
      // saying nothing at all reads as "the section I just made did not save".
      final preview = compose(
        categories: [
          category('c1', name: 'Starters', position: 0),
          category('c2', name: 'Drinks', position: 1),
          category('c3', name: 'Desserts', position: 2),
        ],
        products: [
          inCategory(product('p1', thumbnailUrl: 'https://cdn/a.jpg'), 'c1'),
        ],
      );

      expect(preview.sections.map((s) => s.title), ['Starters']);
      // In their set order, like the sections themselves.
      expect(preview.emptySectionTitles, ['Drinks', 'Desserts']);
    });

    test('a category with products is never named as empty', () {
      final preview = compose(
        categories: [category('c1', name: 'Starters', position: 0)],
        products: [
          inCategory(product('p1', thumbnailUrl: 'https://cdn/a.jpg'), 'c1'),
        ],
      );

      expect(preview.emptySectionTitles, isEmpty);
    });

    test('archived products are not previewed onto a page they never reach',
        () {
      final preview = compose(
        products: [
          product('p1', thumbnailUrl: 'https://cdn/a.jpg'),
          product('p2', archived: true, thumbnailUrl: null),
        ],
      );

      expect(preview.products.map((p) => p.id), ['p1']);
      // ...and therefore an archived product with no image is not reported as
      // blocking a publish it is not part of. (The catalog-level "no
      // categories" row is about the draft, not about p2, and is not a product
      // gate.)
      expect(preview.gatesByProduct, isEmpty);
      expect(
        preview.gates.map((g) => g.code),
        [PublishGateCode.catalogNoCategories],
      );
    });

    test('a product whose category is missing still appears on the page', () {
      // A category deleted on another device, or a list read a moment before a
      // rename. The product is not uncategorized and matches no section — and
      // dropping it would make the preview disagree with the catalog about how
      // many products there are, silently, in the one screen whose whole job is
      // to show the user everything.
      final preview = compose(
        categories: [category('c1', name: 'Starters', position: 0)],
        products: [
          inCategory(product('p1', thumbnailUrl: 'https://cdn/a.jpg'), 'gone'),
        ],
      );

      expect(preview.products, hasLength(1));
      expect(preview.sections.single.title, 'Uncategorized');
      expect(preview.sections.single.products.single.id, 'p1');
    });

    test('warnings are counted per PRODUCT, not per rule', () {
      final preview = compose(
        products: [
          // One product, two failing rules.
          withGlb(product('p1', name: 'Chair', thumbnailUrl: null), null),
          product('p2', thumbnailUrl: 'https://cdn/b.jpg'),
        ],
      );

      expect(preview.gates.where((g) => g.isAboutProduct).length, 2);
      expect(preview.productsWithWarnings, 1);
      expect(preview.gatesByProduct['p1'], hasLength(2));
    });

    // ── The no-uncategorized rule, mirrored ─────────────────────────────────
    //
    // A product in no category reached the live page as a tab called
    // "uncategorized". The preview's pre-flight now says so BEFORE Publish
    // does, in the same two shapes the server uses.

    test('products with no categories at all trip ONE catalog-level gate', () {
      final preview = compose(
        products: [
          product('p1', thumbnailUrl: 'https://cdn/a.jpg'),
          product('p2', thumbnailUrl: 'https://cdn/b.jpg'),
        ],
      );

      final codes = preview.gates.map((g) => g.code).toList();
      // One row, not one per product — forty rows saying the same thing would
      // bury the one instruction that helps.
      expect(codes.where((c) => c == PublishGateCode.catalogNoCategories),
          hasLength(1));
      expect(codes, isNot(contains(PublishGateCode.productUncategorized)));
      expect(preview.catalogGates.single.code,
          PublishGateCode.catalogNoCategories);
      expect(PublishGateCode.catalogNoCategories.fixLabel, 'Create a category');
    });

    test('a stray under a catalog WITH categories is flagged on its card', () {
      final preview = compose(
        categories: [category('c1', name: 'Starters', position: 0)],
        products: [
          inCategory(product('p1', thumbnailUrl: 'https://cdn/a.jpg'), 'c1'),
          inCategory(product('p2', thumbnailUrl: 'https://cdn/b.jpg'), null),
        ],
      );

      expect(preview.gatesByProduct['p1'], isNull);
      expect(preview.gatesByProduct['p2']?.single.code,
          PublishGateCode.productUncategorized);
      expect(
        preview.gates.map((g) => g.code),
        isNot(contains(PublishGateCode.catalogNoCategories)),
      );
    });

    test('a category the catalog no longer has is flagged too', () {
      final preview = compose(
        categories: [category('c1', name: 'Starters', position: 0)],
        products: [
          inCategory(product('p1', thumbnailUrl: 'https://cdn/a.jpg'), 'gone'),
        ],
      );

      expect(preview.gatesByProduct['p1']?.single.code,
          PublishGateCode.productCategoryUnknown);
    });

    test('an empty catalog has nothing to file, so no category gate', () {
      final preview = compose();

      expect(
        preview.gates.map((g) => g.code),
        isNot(contains(PublishGateCode.catalogNoCategories)),
      );
    });

    test('a caller that did not read categories is not told there are none',
        () {
      // Null is "did not look"; only an empty LIST is "there are none".
      final gates = evaluateDraftGates(
        catalogName: 'Cafe',
        products: [product('p1', thumbnailUrl: 'https://cdn/a.jpg')],
      );

      expect(gates, isEmpty);
    });
  });

  group('loading the draft', () {
    testWidgets('reads EVERY page of products, unarchived and unfiltered',
        (tester) async {
      final calls = <ListCall>[];
      final productsRepo = FakeProductsRepository((call) async {
        calls.add(call);
        return call.cursor == null
            ? pageOf(
                [product('p1', thumbnailUrl: 'https://cdn/a.jpg')],
                next: 'cursor-2',
              )
            : pageOf([product('p2', thumbnailUrl: 'https://cdn/b.jpg')]);
      });

      await tester.pumpWidget(harness(
        catalogRepo: FakePreviewCatalogRepo(),
        productsRepo: productsRepo,
      ));
      await tester.pumpAndSettle();

      expect(calls, hasLength(2));
      expect(calls[1].cursor, 'cursor-2');
      // The grid's filters must not leak in: a preview is the WHOLE draft.
      expect(calls.every((c) => c.query == null), isTrue);
      expect(calls.every((c) => c.categoryId == null), isTrue);
      expect(calls.every((c) => !c.includeArchived), isTrue);
    });

    testWidgets('a failed branding read degrades — the products still render',
        (tester) async {
      final productsRepo = FakeProductsRepository(
        (_) async => pageOf([
          product('p1', name: 'Walnut Chair', thumbnailUrl: 'https://cdn/a.jpg')
        ]),
      );

      await tester.pumpWidget(harness(
        catalogRepo: FakePreviewCatalogRepo(),
        productsRepo: productsRepo,
        profileRepo: FakePreviewProfileRepo(
          failure: const CatalogFailure(code: 'UNKNOWN', message: 'nope'),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Walnut Chair'), findsOneWidget);
    });

    testWidgets('no catalog is an error state, not a blank page',
        (tester) async {
      await tester.pumpWidget(harness(
        catalogRepo: FakePreviewCatalogRepo.none(),
        productsRepo: FakeProductsRepository((_) async => pageOf([])),
      ));
      await tester.pumpAndSettle();

      expect(find.text("We couldn't build your preview"), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  });

  group('the screen', () {
    testWidgets('says it is a preview and an approximation', (tester) async {
      await tester.pumpWidget(harness(
        catalogRepo: FakePreviewCatalogRepo(),
        productsRepo: FakeProductsRepository(
          (_) async =>
              pageOf([product('p1', thumbnailUrl: 'https://cdn/a.jpg')]),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Preview of your draft'), findsOneWidget);
      expect(
        find.textContaining('approximation of your public page'),
        findsOneWidget,
      );
      // ...and never claims to be live.
      expect(find.textContaining('nothing here is live'), findsOneWidget);
    });

    testWidgets('flags a failing product on its own card', (tester) async {
      await tester.pumpWidget(harness(
        catalogRepo: FakePreviewCatalogRepo(),
        productsRepo: FakeProductsRepository(
          (_) async => pageOf([
            product('p1', name: 'Fine', thumbnailUrl: 'https://cdn/a.jpg'),
            withGlb(product('p2', name: 'Broken', thumbnailUrl: null), null),
          ]),
        ),
      ));
      await tester.pumpAndSettle();

      // The headline counts products, not rules — "Broken" trips two.
      expect(find.textContaining("1 of 2 products won't publish yet"),
          findsOneWidget);
      expect(
          find.textContaining('"Broken" has no 3D model yet'), findsOneWidget);
      // The clean product carries no strip.
      final cards = tester.widgetList<PreviewProductCard>(
        find.byType(PreviewProductCard),
      );
      expect(
        {for (final card in cards) card.product.id: card.gates.length},
        {'p1': 0, 'p2': 2},
      );
    });

    testWidgets('renders one block per non-empty category, in their set order',
        (tester) async {
      await tester.pumpWidget(harness(
        catalogRepo: FakePreviewCatalogRepo(categories: [
          category('c2', name: 'Mains', position: 1),
          category('c1', name: 'Starters', position: 0),
        ]),
        productsRepo: FakeProductsRepository(
          (_) async => pageOf([
            inCategory(
                product('p1', name: 'Soup', thumbnailUrl: 'https://cdn/a.jpg'),
                'c1'),
            inCategory(
                product('p2', name: 'Steak', thumbnailUrl: 'https://cdn/b.jpg'),
                'c2'),
          ]),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Starters'), findsWidgets);
      expect(find.text('Mains'), findsWidgets);
      expect(find.text('Soup'), findsOneWidget);
      expect(find.text('Steak'), findsOneWidget);
    });

    testWidgets('names a section that exists but has nothing in it yet',
        (tester) async {
      await tester.pumpWidget(harness(
        catalogRepo: FakePreviewCatalogRepo(categories: [
          category('c1', name: 'Starters', position: 0),
          category('c2', name: 'Drinks', position: 1),
        ]),
        productsRepo: FakeProductsRepository(
          (_) async => pageOf([
            inCategory(
                product('p1', name: 'Soup', thumbnailUrl: 'https://cdn/a.jpg'),
                'c1'),
          ]),
        ),
      ));
      await tester.pumpAndSettle();

      // Not rendered as a section — the public page has no heading for it...
      expect(find.text('Starters'), findsWidgets);
      // ...but named, so somebody who just created it can see it saved.
      expect(
          find.byKey(const ValueKey('preview_empty_sections')), findsOneWidget);
    });

    testWidgets('an empty catalog previews the BRANDED page a customer gets',
        (tester) async {
      await tester.pumpWidget(harness(
        catalogRepo:
            FakePreviewCatalogRepo(catalog: catalogNamed('Cafe Mocha')),
        productsRepo: FakeProductsRepository((_) async => pageOf([])),
      ));
      await tester.pumpAndSettle();

      // The branding is still there — this is the page, not an empty state.
      expect(find.text('Cafe Mocha'), findsOneWidget);
      expect(find.text('Nothing on the menu yet'), findsOneWidget);
      expect(
        find.textContaining('exactly what a customer would see'),
        findsOneWidget,
      );
    });

    testWidgets('a contact field the SERVER does not publish is not previewed',
        (tester) async {
      // Which fields reach Mirage is the publish worker's property, shipped as
      // `publicFields`. Hardcoding that list here — or previewing everything —
      // would tell a business their email is on their public page when it is
      // not.
      final profile = BusinessProfile.fromMap(
        golden.profileGolden()..['publicFields'] = <String>['name'],
      );

      await tester.pumpWidget(harness(
        catalogRepo: FakePreviewCatalogRepo(),
        productsRepo: FakeProductsRepository((_) async => pageOf([])),
        profileRepo: FakePreviewProfileRepo(profile: profile),
      ));
      await tester.pumpAndSettle();

      expect(find.text('+91 90000 00000'), findsNothing);
      expect(find.text('12 Market Road, Pune'), findsNothing);
    });

    testWidgets('authoring-only state never reaches the customer view',
        (tester) async {
      await tester.pumpWidget(harness(
        catalogRepo: FakePreviewCatalogRepo(),
        productsRepo: FakeProductsRepository(
          (_) async => pageOf([
            product(
              'p1',
              name: 'Walnut Chair',
              thumbnailUrl: 'https://cdn/a.jpg',
            ),
          ]),
        ),
      ));
      await tester.pumpAndSettle();

      // The golden product is featured, in stock and SYNCED. None of those is
      // a thing a customer can see, so none of them may appear here.
      expect(find.text('Live'), findsNothing);
      expect(find.text('Featured'), findsNothing);
      expect(find.text('Out of stock'), findsNothing);
    });

    test('a narrow viewport gets the phone card rhythm, a tall one is capped',
        () {
      // Decided from the VIEWPORT, never from kIsWeb — the same rule as the
      // product grid's column count.
      expect(previewCardHeight(800), (800 - 180) / 2);
      expect(previewCardHeight(300), 200);
      expect(previewCardHeight(2000), 420);
    });
  });

  // ── Sorting and filtering ────────────────────────────────────────────────
  //
  // THE ASSERTION THAT CARRIES THIS GROUP is that the frame stops calling
  // itself the customer's page the moment a lens is on. Everything else here is
  // ordinary list behaviour; that one line is the whole reason sorting a
  // PREVIEW is allowed at all, and a regression would quietly teach authors
  // that customers see their dishes newest-first.
  group('the author lens', () {
    /// A product with the fields the sorts actually read.
    CatalogProduct dish(
      String id, {
      required String name,
      required double? price,
      required DateTime created,
      ProductType type = ProductType.threeD,
      String? glbUrl = 'https://cdn/m.glb',
      ProductFoodType foodType = ProductFoodType.veg,
    }) =>
        CatalogProduct.fromMap(
          golden.productGolden()
            ..['id'] = id
            ..['name'] = name
            ..['type'] = type.apiValue
            ..['price'] = price
            ..['thumbnailUrl'] = 'https://cdn/$id.jpg'
            ..['glbUrl'] = glbUrl
            ..['foodType'] = foodType.apiValue
            ..['createdAt'] = created.toIso8601String(),
        );

    final oldest = dish(
      'p1',
      name: 'Alpha',
      price: 300,
      created: DateTime.utc(2026, 1, 1),
    );
    final middle = dish(
      'p2',
      name: 'Charlie',
      price: 100,
      created: DateTime.utc(2026, 6, 1),
      type: ProductType.imageOnly,
      glbUrl: null,
      foodType: ProductFoodType.nonVeg,
    );
    final newest = dish(
      'p3',
      name: 'Bravo',
      price: 200,
      created: DateTime.utc(2026, 9, 1),
    );

    Widget lensHarness() => harness(
          catalogRepo: FakePreviewCatalogRepo(),
          productsRepo: FakeProductsRepository(
            (_) async => pageOf([oldest, middle, newest]),
          ),
          // Tall enough that every card is laid out, so ordering can be read
          // off the render tree rather than off a scroll position.
          size: const Size(400, 2400),
        );

    /// The card names in the order they are painted.
    List<String> ordered(WidgetTester tester) => tester
        .widgetList<PreviewProductCard>(find.byType(PreviewProductCard))
        .map((card) => card.product.displayName)
        .toList();

    testWidgets('defaults to menu order and claims the customer view',
        (tester) async {
      await pumpTall(tester, lensHarness());
      await tester.pumpAndSettle();

      expect(ordered(tester), ['Alpha', 'Charlie', 'Bravo']);
      expect(find.text('WHAT A CUSTOMER SEES'), findsOneWidget);
      // No lens, nothing to say and nothing to reset.
      expect(find.byKey(const ValueKey('preview_view_notice')), findsNothing);
    });

    testWidgets('newest and oldest reorder the page', (tester) async {
      await pumpTall(tester, lensHarness());
      await tester.pumpAndSettle();

      await tapChip(tester, 'preview_sort_newest');
      expect(ordered(tester), ['Bravo', 'Charlie', 'Alpha']);

      await tapChip(tester, 'preview_sort_oldest');
      expect(ordered(tester), ['Alpha', 'Charlie', 'Bravo']);
    });

    testWidgets('price and name sorts', (tester) async {
      await pumpTall(tester, lensHarness());
      await tester.pumpAndSettle();

      await tapChip(tester, 'preview_sort_priceHigh');
      expect(ordered(tester), ['Alpha', 'Bravo', 'Charlie']);

      await tapChip(tester, 'preview_sort_nameAz');
      expect(ordered(tester), ['Alpha', 'Bravo', 'Charlie']);
    });

    testWidgets('the frame STOPS claiming the customer view under a lens',
        (tester) async {
      await pumpTall(tester, lensHarness());
      await tester.pumpAndSettle();

      await tapChip(tester, 'preview_sort_newest');

      // The one assertion this whole feature hangs on.
      expect(find.text('WHAT A CUSTOMER SEES'), findsNothing);
      expect(find.text('YOUR VIEW OF THE DRAFT'), findsOneWidget);
      expect(find.byKey(const ValueKey('preview_view_notice')), findsOneWidget);
      // And it says what customers actually get instead.
      expect(
          find.textContaining('Customers get the menu order'), findsOneWidget);
    });

    testWidgets('Reset puts the page back and the claim with it',
        (tester) async {
      await pumpTall(tester, lensHarness());
      await tester.pumpAndSettle();

      await tapChip(tester, 'preview_sort_newest');
      await tester.tap(find.byKey(const ValueKey('preview_view_reset')));
      await tester.pumpAndSettle();

      expect(ordered(tester), ['Alpha', 'Charlie', 'Bravo']);
      expect(find.text('WHAT A CUSTOMER SEES'), findsOneWidget);
    });

    testWidgets('filters narrow the set and count what is hidden',
        (tester) async {
      await pumpTall(tester, lensHarness());
      await tester.pumpAndSettle();

      await tapChip(tester, 'preview_filter_photo');

      // Only the image-only dish survives "Photo only".
      expect(ordered(tester), ['Charlie']);
      expect(find.textContaining('2 products hidden'), findsOneWidget);

      await tapChip(tester, 'preview_filter_threeD');
      expect(ordered(tester), ['Alpha', 'Bravo']);

      await tapChip(tester, 'preview_filter_nonVeg');
      expect(ordered(tester), ['Charlie']);
    });

    testWidgets('a filter that matches nothing is not a branded empty page',
        (tester) async {
      await pumpTall(
        tester,
        harness(
          catalogRepo: FakePreviewCatalogRepo(),
          productsRepo: FakeProductsRepository(
            // Every dish is veg, so "Non-veg" matches none of them.
            (_) async => pageOf([oldest, newest]),
          ),
          size: const Size(400, 2400),
        ),
      );
      await tester.pumpAndSettle();

      await tapChip(tester, 'preview_filter_nonVeg');

      expect(find.byKey(const ValueKey('preview_no_matches')), findsOneWidget);
      // "This is exactly what a customer would see" would be a lie about a
      // draft the author has merely narrowed.
      expect(find.text('Nothing on the menu yet'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('preview_no_matches_reset')));
      await tester.pumpAndSettle();
      expect(ordered(tester), ['Alpha', 'Bravo']);
    });

    testWidgets('the counts above the frame describe the DRAFT, not the view',
        (tester) async {
      await pumpTall(tester, lensHarness());
      await tester.pumpAndSettle();
      expect(find.text('3 products'), findsOneWidget);

      await tapChip(tester, 'preview_filter_photo');

      // Still three products in the catalog; one of them is on screen. A
      // summary that moved with the filter would be answering the wrong
      // question right above a banner explaining the filter.
      expect(find.text('3 products'), findsOneWidget);
    });
  });

  group('the category tabs', () {
    Widget tabsHarness() => harness(
          catalogRepo: FakePreviewCatalogRepo(categories: [
            category('c1', name: 'Starters', position: 0),
            category('c2', name: 'Mains', position: 1),
          ]),
          productsRepo: FakeProductsRepository(
            (_) async => pageOf([
              inCategory(
                  product('p1',
                      name: 'Soup', thumbnailUrl: 'https://cdn/a.jpg'),
                  'c1'),
              inCategory(
                  product('p2',
                      name: 'Steak', thumbnailUrl: 'https://cdn/b.jpg'),
                  'c2'),
              inCategory(
                  product('p3',
                      name: 'Cake', thumbnailUrl: 'https://cdn/c.jpg'),
                  null),
            ]),
          ),
          size: const Size(400, 2400),
        );

    List<String> ordered(WidgetTester tester) => tester
        .widgetList<PreviewProductCard>(find.byType(PreviewProductCard))
        .map((card) => card.product.displayName)
        .toList();

    testWidgets('All comes first and is the whole page', (tester) async {
      await pumpTall(tester, tabsHarness());
      await tester.pumpAndSettle();

      expect(
          find.byKey(const ValueKey('preview_category_all')), findsOneWidget);
      expect(ordered(tester), ['Soup', 'Steak', 'Cake']);
    });

    testWidgets('a category tab narrows the page to that category',
        (tester) async {
      await pumpTall(tester, tabsHarness());
      await tester.pumpAndSettle();

      await tapChip(tester, 'preview_category_c2');
      expect(ordered(tester), ['Steak']);
      // A tab is what a customer has too, so the frame keeps its claim.
      expect(find.text('WHAT A CUSTOMER SEES'), findsOneWidget);

      // The Uncategorized bucket is a tab like any other.
      await tapChip(tester, 'preview_category_');
      expect(ordered(tester), ['Cake']);

      await tapChip(tester, 'preview_category_all');
      expect(ordered(tester), ['Soup', 'Steak', 'Cake']);
    });
  });
}
