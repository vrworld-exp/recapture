// test/catalog/draft_badge_refresh_test.dart
//
// Feature 38, from the client side: "Draft changes not yet live" must appear
// after EVERY authoring write, not just the ones somebody remembered.
//
// THE SHAPE OF THIS BUG, and why it needs its own suite. The flag is server-
// derived — `draftRevision > publishedRevision` — and the backend is scrupulous
// about the increment: products, categories, branding, the profile and an
// automatic model promotion all bump it. The client half is where it goes
// wrong, because the flag arrives on the CATALOG document and most writes here
// return something else (a product, a category, a profile). A write whose
// caller forgets to re-read the catalog leaves the badge dark over a catalog
// that genuinely has unpublished changes — and dark is the dangerous direction:
// it tells a café owner their edit is live on the table-top QR when it is not.
//
// So every test below is the same assertion in a different place: the write
// landed, and the catalog document was re-read. `FakeCatalogRepository.fetchCalls`
// is the whole instrument.
//
// The two paths that had no route-return to save them are the ones worth
// naming, because nothing else would have caught them:
//   • REORDER — a drag on the grid, and the user never leaves the screen.
//   • A MODEL LANDING — the poll loop turns a card 3D while the user watches,
//     and the promotion that did it bumped the revision server-side.
//
// Hermetic: fake repositories, `Future.delayed` for the clock, no HTTP.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/catalog_categories_notifier.dart';
import 'package:recapture/application/catalog/catalog_notifier.dart';
import 'package:recapture/application/catalog/catalog_products_notifier.dart';
import 'package:recapture/application/common/pending_poll_loop.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart';
import 'package:recapture/data/repositories/catalog_repository.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/catalog_category.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/product_model_status.dart';
import 'package:recapture/domain/entities/product_type.dart';

import 'product_grid_test.dart'
    show FakeCatalogRepository, FakeProductsRepository, pageOf, product;

/// [FakeCatalogRepository] with the category writes filled in.
///
/// The shared fake leaves them `UnimplementedError` because the grid tests only
/// ever READ categories. This suite writes them, and the point of every write is
/// what happens to `fetchCalls` afterwards — which is inherited, not re-stated.
class _CategoryWritingRepo extends FakeCatalogRepository {
  _CategoryWritingRepo();

  final List<String> created = [];
  final List<List<String>> reorders = [];
  int renames = 0;
  int deletes = 0;

  CatalogCategory _category(String id, String name, int position) =>
      CatalogCategory(
        id: id,
        name: name,
        position: position,
        productCount: 0,
      );

  @override
  Future<CatalogCategoryList> listCategories() async => CatalogCategoryList(
        categories: [
          _category('c1', 'Starters', 0),
          _category('c2', 'Mains', 1),
        ],
        uncategorizedCount: 0,
      );

  @override
  Future<CatalogCategory> createCategory(String name) async {
    created.add(name);
    return _category('c3', name, 2);
  }

  @override
  Future<CatalogCategory> renameCategory(String id, String name) async {
    renames++;
    return _category(id, name, 0);
  }

  @override
  Future<int> deleteCategory(String id) async {
    deletes++;
    return 3;
  }

  @override
  Future<void> reorderCategories(List<String> orderedIds) async =>
      reorders.add(orderedIds);
}

class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

ProviderContainer _container({
  required FakeProductsRepository products,
  required FakeCatalogRepository catalog,
}) {
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith(_StubAuth.new),
      // A real session, so the catalog and the grid both LOAD rather than
      // resting on their signed-out empty states.
      sessionIdentityProvider.overrideWithValue('session-1'),
      catalogProductsRepositoryProvider.overrideWithValue(products),
      catalogRepositoryProvider.overrideWithValue(catalog),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Lets the microtask-scheduled first loads land.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

CatalogProduct _dish(String id, ProductModelStatus status) => CatalogProduct(
      id: id,
      type: ProductType.threeD,
      name: 'Dish $id',
      currency: 'INR',
      position: 0,
      modelStatus: status,
      glbUrl: status == ProductModelStatus.ready ? 'https://cdn/$id.glb' : null,
    );

void main() {
  group('a product write re-reads the catalog', () {
    test('reorder does — nobody leaves the screen to make it happen', () async {
      final products = FakeProductsRepository(
        (_) async => pageOf([
          product('p1', position: 0),
          product('p2', position: 1),
          product('p3', position: 2),
        ]),
      );
      final catalog = FakeCatalogRepository();
      final container = _container(products: products, catalog: catalog);

      container.read(catalogProductsProvider);
      container.read(catalogProvider);
      await _settle();
      final before = catalog.fetchCalls;

      await container.read(catalogProductsProvider.notifier).reorder(2, 0);
      await _settle();

      expect(products.reorders.single, ['p3', 'p1', 'p2']);
      // THE ASSERTION. A drag is an authoring write like any other; the server
      // bumped `draftRevision` for it, and the header has to be told. Every
      // other product write is followed by a route return that re-reads this —
      // a drag is not, which is why it was the one that was missing.
      expect(catalog.fetchCalls, before + 1);
    });

    test('a failed reorder does NOT — nothing moved', () async {
      final products = FakeProductsRepository(
        (_) async => pageOf([product('p1', position: 0), product('p2', position: 1)]),
      );
      final catalog = FakeCatalogRepository();
      final container = _container(products: products, catalog: catalog);

      container.read(catalogProductsProvider);
      container.read(catalogProvider);
      await _settle();
      final before = catalog.fetchCalls;

      products.reorderFailure = const CatalogFailure(
        code: 'ID_SET_MISMATCH',
        message: 'One or more products could not be reordered.',
      );
      await expectLater(
        container.read(catalogProductsProvider.notifier).reorder(1, 0),
        throwsA(isA<CatalogFailure>()),
      );
      await _settle();

      // The server rejects a mismatched set wholesale. The revision did not
      // move, so re-reading would only put a request on the wire to be told so.
      expect(catalog.fetchCalls, before);
    });
  });

  group('a model landing re-reads the catalog', () {
    test('a promotion moves the header, not just the card', () async {
      var call = 0;
      final products = FakeProductsRepository((_) async {
        call++;
        return pageOf([
          _dish('a', call == 1 ? ProductModelStatus.processing : ProductModelStatus.ready),
        ]);
      });
      final catalog = FakeCatalogRepository();
      final container = _container(products: products, catalog: catalog);

      container.read(catalogProductsProvider);
      container.read(catalogProvider);
      await _settle();
      expect(
        container.read(catalogProductsProvider.notifier).isPollingModels,
        isTrue,
      );
      final before = catalog.fetchCalls;

      await Future<void>.delayed(
        kPendingPollInitialInterval + const Duration(milliseconds: 50),
      );

      expect(
        container.read(catalogProductsProvider).items.single.modelStatus,
        ProductModelStatus.ready,
      );
      // WHAT THIS IS REALLY ABOUT. The backend PROMOTED the product when its
      // model finished, and that promotion bumped `draftRevision`. The user is
      // sitting on the grid watching it happen, so no route return will re-read
      // the catalog for them: without this the card turns 3D while the badge
      // stays dark, which reads as "this is already live".
      expect(catalog.fetchCalls, before + 1);
    });

    test('a tick where nothing settled does not', () async {
      final products = FakeProductsRepository(
        (_) async => pageOf([_dish('a', ProductModelStatus.processing)]),
      );
      final catalog = FakeCatalogRepository();
      final container = _container(products: products, catalog: catalog);

      container.read(catalogProductsProvider);
      container.read(catalogProvider);
      await _settle();
      final before = catalog.fetchCalls;

      await Future<void>.delayed(
        kPendingPollInitialInterval + const Duration(milliseconds: 50),
      );

      // Still generating. Nothing moved server-side either, and a second
      // request on the poll's own cadence — for the whole length of a
      // generation — is exactly what the cadence exists to avoid.
      expect(catalog.fetchCalls, before);
    });
  });

  group('a category write re-reads the catalog', () {
    late _CategoryWritingRepo catalog;
    late ProviderContainer container;

    setUp(() async {
      catalog = _CategoryWritingRepo();
      container = _container(
        products: FakeProductsRepository((_) async => pageOf([])),
        catalog: catalog,
      );
      container.read(catalogCategoriesProvider);
      container.read(catalogProvider);
      await _settle();
    });

    // SECTIONS ARE PART OF THE PUBLISHED PAGE, so the backend bumps
    // `draftRevision` for all four of these. The category manager is pushed over
    // the catalog screen, and that screen deliberately refreshes nothing on
    // return — the chips and the picker share the notifier — so if the write
    // does not re-read the catalog, nothing ever will.
    test('create does', () async {
      final before = catalog.fetchCalls;
      await container.read(catalogCategoriesProvider.notifier).create('Desserts');
      await _settle();

      expect(catalog.created, ['Desserts']);
      expect(catalog.fetchCalls, greaterThan(before));
    });

    test('rename does', () async {
      final before = catalog.fetchCalls;
      await container
          .read(catalogCategoriesProvider.notifier)
          .rename('c1', 'Small plates');
      await _settle();

      expect(catalog.renames, 1);
      expect(catalog.fetchCalls, greaterThan(before));
    });

    test('delete does', () async {
      final before = catalog.fetchCalls;
      await container.read(catalogCategoriesProvider.notifier).delete('c1');
      await _settle();

      expect(catalog.deletes, 1);
      expect(catalog.fetchCalls, greaterThan(before));
    });

    test('reorder does', () async {
      final before = catalog.fetchCalls;
      await container.read(catalogCategoriesProvider.notifier).reorder(1, 0);
      await _settle();

      expect(catalog.reorders.single, ['c2', 'c1']);
      expect(catalog.fetchCalls, greaterThan(before));
    });
  });
}
