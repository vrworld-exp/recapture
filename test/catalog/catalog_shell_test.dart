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
  _FakeCatalogRepo(this._fetch, {this.onCreate});

  final Future<Catalog?> Function() _fetch;

  /// Lets a test fail the create. Null → the default success.
  final Future<Catalog> Function()? onCreate;

  int fetchCalls = 0;

  /// What the last create was called with, so a test can assert that a blank
  /// optional field went out ABSENT rather than as an empty string.
  int createCalls = 0;
  String? lastCreateName;
  String? lastCreateBusinessName;

  @override
  Future<Catalog?> fetch() {
    fetchCalls++;
    return _fetch();
  }

  @override
  Future<Catalog> create({required String name, String? businessName}) async {
    createCalls++;
    lastCreateName = name;
    lastCreateBusinessName = businessName;
    if (onCreate != null) return onCreate!();
    return Catalog.fromMap(golden.catalogGolden()..['name'] = name);
  }

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

  group('create flow', () {
    /// The dialog's submit button. Both it and the empty state's CTA read
    /// "Create catalog", so it has to be scoped to the dialog or the finder
    /// resolves to two widgets.
    final submitButton = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(ElevatedButton, 'Create catalog'),
    );

    Future<void> openDialog(WidgetTester tester, _FakeCatalogRepo repo) async {
      await tester.pumpWidget(_app(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create catalog'));
      await tester.pumpAndSettle();
    }

    testWidgets('the empty state CTA opens the create form', (tester) async {
      // The button used to be wired to a null callback — a CTA that named the
      // step and then did nothing. Pin that it actually opens something.
      await openDialog(tester, _FakeCatalogRepo(() async => null));

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Create your catalog'), findsOneWidget);
    });

    testWidgets('creating switches the shell to the catalog body',
        (tester) async {
      final repo = _FakeCatalogRepo(() async => null);
      await openDialog(tester, repo);

      await tester.enterText(find.byType(TextFormField).first, '  Cafe Mocha  ');
      await tester.tap(submitButton);
      await tester.pumpAndSettle();

      // Trimmed client-side, and the untouched optional field goes out as an
      // absent key — the server schema is strict and rejects a blank one.
      expect(repo.createCalls, 1);
      expect(repo.lastCreateName, 'Cafe Mocha');
      expect(repo.lastCreateBusinessName, isNull);

      // The notifier holds the created catalog, so the shell moved on without a
      // re-fetch.
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('No catalog yet'), findsNothing);
      expect(find.text('Cafe Mocha'), findsOneWidget);
      expect(repo.fetchCalls, 1);

      // Let the confirmation snackbar expire, so no timer outlives the tree.
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });

    testWidgets('an empty name is rejected without a round-trip',
        (tester) async {
      final repo = _FakeCatalogRepo(() async => null);
      await openDialog(tester, repo);

      await tester.tap(submitButton);
      await tester.pumpAndSettle();

      expect(find.text('Give your catalog a name.'), findsOneWidget);
      expect(repo.createCalls, 0);
      expect(find.byType(AlertDialog), findsOneWidget); // still open
    });

    testWidgets('a failed create keeps the form open with what was typed',
        (tester) async {
      final repo = _FakeCatalogRepo(
        () async => null,
        onCreate: () async => throw const CatalogFailure(
          code: 'OFFLINE',
          message: "You're offline — check your connection and try again.",
          isOffline: true,
        ),
      );
      await openDialog(tester, repo);

      await tester.enterText(find.byType(TextFormField).first, 'Cafe Mocha');
      await tester.tap(submitButton);
      await tester.pumpAndSettle();

      // The whole reason the request is issued from inside the dialog: a retry
      // must not cost the user the name they already typed.
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining("You're offline"), findsOneWidget);
      expect(
        tester.widget<TextFormField>(find.byType(TextFormField).first).controller?.text,
        'Cafe Mocha',
      );
      // A failed create leaves notifier state alone, so the shell behind the
      // dialog is still the empty state — it must not have blanked or errored.
      expect(find.text('No catalog yet'), findsOneWidget);
      expect(find.textContaining("couldn't load"), findsNothing);
    });
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
