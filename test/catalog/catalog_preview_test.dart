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
import 'package:recapture/domain/entities/product_type.dart';
import 'package:recapture/presentation/screens/catalog/catalog_preview_screen.dart';
import 'package:recapture/presentation/widgets/catalog/preview_product_card.dart';
import 'catalog_repo_analytics_defaults.dart';
import 'catalog_repo_publish_defaults.dart';

import 'catalog_entities_test.dart' as golden;
import 'product_grid_test.dart' show FakeProductsRepository, ListCall, pageOf, product;

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
    with CatalogRepoPublishDefaults, CatalogRepoAnalyticsDefaults
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
      // blocking a publish it is not part of.
      expect(preview.gates, isEmpty);
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

      expect(preview.gates.length, 2);
      expect(preview.productsWithWarnings, 1);
      expect(preview.gatesByProduct['p1'], hasLength(2));
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
          (_) async => pageOf([product('p1', thumbnailUrl: 'https://cdn/a.jpg')]),
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
      expect(find.textContaining('"Broken" has no 3D model yet'), findsOneWidget);
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

    testWidgets('an empty catalog previews the BRANDED page a customer gets',
        (tester) async {
      await tester.pumpWidget(harness(
        catalogRepo: FakePreviewCatalogRepo(catalog: catalogNamed('Cafe Mocha')),
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
}
