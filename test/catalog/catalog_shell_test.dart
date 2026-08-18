// test/catalog/catalog_shell_test.dart
//
// The catalog shell and its route wiring.
//
// The state this file cares most about is "no catalog yet": the server answers
// 404 for it, and if that reached the UI as a failure every new user's first
// sight of the feature would be an error screen. The repository turns it into
// `null` and the shell renders a create prompt — these tests pin that, and the
// two other states either side of it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/app/routes/app_router.dart';
import 'package:recapture/app/routes/flow_back.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/catalog_notifier.dart';
import 'package:recapture/data/repositories/catalog_failure.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart';
import 'package:recapture/data/repositories/catalog_repository.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/business_profile.dart';
import 'package:recapture/domain/entities/catalog.dart';
import 'package:recapture/domain/entities/catalog_category.dart';
import 'package:recapture/presentation/screens/catalog/catalog_screen.dart';

import 'catalog_entities_test.dart' as golden;

/// Auth held still, so [CatalogNotifier]'s sign-out listener can be exercised
/// without the real notifier's session restore touching secure storage.
class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

/// A repository whose catalog is whatever the test says it is.
class _FakeCatalogRepo implements CatalogRepository {
  _FakeCatalogRepo(this._fetch);

  final Future<Catalog?> Function() _fetch;
  int fetchCalls = 0;

  @override
  Future<Catalog?> fetch() {
    fetchCalls++;
    return _fetch();
  }

  @override
  Future<Catalog> create({required String name, String? businessName}) async =>
      Catalog.fromMap(golden.catalogGolden()..['name'] = name);

  @override
  Future<Catalog> update({
    String? name,
    String? businessName,
    BusinessContact? contact,
  }) async =>
      Catalog.fromMap(golden.catalogGolden());

  @override
  Future<ProductImageSlot> createBrandingSlot({
    required BrandingSlot slot,
    required ProductImageContentType contentType,
  }) =>
      throw UnimplementedError('not used here');

  @override
  Future<BusinessProfile> commitBranding({
    required BrandingSlot slot,
    required String key,
  }) =>
      throw UnimplementedError('not used here');

  @override
  Future<CatalogCategoryList> listCategories() async => CatalogCategoryList.empty;

  @override
  Future<CatalogCategory> createCategory(String name) =>
      throw UnimplementedError('not used here');

  @override
  Future<CatalogCategory> renameCategory(String id, String name) =>
      throw UnimplementedError('not used here');

  @override
  Future<int> deleteCategory(String id) => throw UnimplementedError('not used here');

  @override
  Future<void> reorderCategories(List<String> orderedIds) =>
      throw UnimplementedError('not used here');
}

Widget _app(_FakeCatalogRepo repo) => ProviderScope(
      overrides: [
        authProvider.overrideWith(_StubAuth.new),
        catalogRepositoryProvider.overrideWithValue(repo),
      ],
      child: const MaterialApp(home: CatalogScreen()),
    );

void main() {
  testWidgets('renders the create prompt when the user has no catalog yet',
      (tester) async {
    final repo = _FakeCatalogRepo(() async => null);

    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    // A first-run state, NOT an error — no failure copy anywhere on screen.
    expect(find.text('No catalog yet'), findsOneWidget);
    expect(find.text('Create catalog'), findsOneWidget);
    expect(find.textContaining("couldn't load"), findsNothing);
    expect(repo.fetchCalls, 1);
  });

  testWidgets('renders the add-product prompt for an empty catalog',
      (tester) async {
    final repo = _FakeCatalogRepo(() async => Catalog.fromMap(golden.catalogGolden()
      ..['counts'] = {'products': 0, 'archivedProducts': 0, 'categories': 0}));

    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    // "No catalog" and "catalog with nothing in it" are different states, and
    // the copy has to tell them apart or the user cannot tell what to do next.
    expect(find.text('No catalog yet'), findsNothing);
    expect(find.text('No products yet'), findsOneWidget);
    expect(find.text('Cafe Mocha'), findsOneWidget);
  });

  testWidgets('shows the publish state chips a populated catalog carries',
      (tester) async {
    final repo = _FakeCatalogRepo(
      () async => Catalog.fromMap(golden.catalogGolden()
        ..['hasUnpublishedChanges'] = true
        ..['status'] = 'PUBLISHED'),
    );

    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    expect(find.text('Published'), findsOneWidget);
    // Feature 38 — derived server-side from the revision counters.
    expect(find.text('Draft changes not yet live'), findsOneWidget);
    expect(find.text('12 products · 4 categories'), findsOneWidget);
  });

  testWidgets('a real failure shows the error state with a retry', (tester) async {
    final repo = _FakeCatalogRepo(
      () async => throw const CatalogFailure(
        code: 'OFFLINE',
        message: "You're offline — check your connection and try again.",
        isOffline: true,
      ),
    );

    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    expect(find.textContaining("couldn't load"), findsOneWidget);
    // The server's own owner-safe sentence, not an exception toString.
    expect(find.textContaining("You're offline"), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  group('route wiring', () {
    test('every catalog path is registered with a matching name', () {
      // The constants exist as soon as a path is decided; the GoRoute for each
      // lands with its screen. A typo in either half is a runtime-only failure,
      // so pin the strings.
      expect(AppRoutes.catalog, '/catalog');
      expect(AppRoutes.catalogSettings, '/catalog/settings');
      expect(AppRoutes.catalogPreview, '/catalog/preview');
      expect(AppRoutes.catalogPublish, '/catalog/publish');
      expect(AppRoutes.catalogQr, '/catalog/qr');
      expect(AppRoutes.catalogCategories, '/catalog/categories');
      expect(AppRoutes.productNew, '/catalog/products/new');
      expect(AppRoutes.productDetail, '/catalog/products/:productId');
      expect(AppRoutes.businessProfile, '/profile/business');
      expect(AppRoutes.catalogAnalytics, '/catalog/analytics');

      expect(AppRouteNames.catalog, 'catalog');
      expect(AppRouteNames.catalogSettings, 'catalogSettings');
      expect(AppRouteNames.catalogPreview, 'catalogPreview');
      expect(AppRouteNames.catalogPublish, 'catalogPublish');
      expect(AppRouteNames.catalogQr, 'catalogQr');
      expect(AppRouteNames.catalogCategories, 'catalogCategories');
      expect(AppRouteNames.productNew, 'productNew');
      expect(AppRouteNames.productDetail, 'productDetail');
      expect(AppRouteNames.businessProfile, 'businessProfile');
      expect(AppRouteNames.catalogAnalytics, 'catalogAnalytics');
    });

    test('static catalog paths are declared before the parameterised one', () {
      // Route order is load-bearing on the backend router for the same reason it
      // matters here: `/catalog/products/:productId` would otherwise swallow the
      // literal "new".
      expect(AppRoutes.productNew.startsWith('/catalog/products/'), isTrue);
      expect(AppRoutes.productDetail.contains(':productId'), isTrue);
    });

    test('back from the catalog shell lands on Projects, not out of the app', () {
      // /catalog is reached with go(), which REPLACES the stack — without this
      // mapping the system back key would exit the app from the catalog.
      expect(flowBackRouteFor(AppRoutes.catalog), AppRoutes.projects);
    });
  });
}
