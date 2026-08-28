// test/catalog/session_scope_test.dart
//
// The catalog surfaces are session-scoped caches, and this file pins the half
// of that contract that used to be missing.
//
// Sign-OUT was always handled: the catalog blanked to `AsyncData(null)`, the
// categories to an empty list. Nothing handled the sign-IN after it. Because
// these providers live for the whole app run, the next session opened the
// catalog screen onto those reset values — which are exactly the "no catalog
// yet" and "no categories" first-run states — with no request in flight, and
// therefore no loading UI either. The catalog was only revealed by pressing
// Create, whose endpoint is idempotent and hands back the existing catalog.
//
// So: a new session must RE-FETCH, and it must be visibly loading while it
// does. A token-refresh rotation must not, because it is the same session.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/catalog_categories_notifier.dart';
import 'package:recapture/application/catalog/catalog_notifier.dart';
import 'package:recapture/application/catalog/catalog_products_notifier.dart';
import 'package:recapture/data/repositories/catalog_products_repository.dart';
import 'package:recapture/data/repositories/catalog_repository.dart';
import 'package:recapture/domain/entities/auth_session.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/catalog.dart';
import 'package:recapture/domain/entities/catalog_category.dart';

import 'product_grid_test.dart' show FakeCatalogRepository, pageOf, product;

/// Auth the test drives by hand. Starts held at [AuthRestoring] like the other
/// catalog tests, so nothing touches secure storage.
class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();

  void emit(AuthState next) => state = next;
}

/// [FakeCatalogRepository] with the call counts these tests assert on.
class _CountingCatalogRepo extends FakeCatalogRepository {
  _CountingCatalogRepo() : super(categories: const <CatalogCategory>[]);

  int fetchCalls = 0;
  int listCategoriesCalls = 0;

  @override
  Future<Catalog?> fetch() {
    fetchCalls++;
    return super.fetch();
  }

  @override
  Future<CatalogCategoryList> listCategories() {
    listCategoriesCalls++;
    return super.listCategories();
  }
}

class _CountingProductsRepo implements CatalogProductsRepository {
  int listCalls = 0;

  @override
  Future<CatalogProductPage> list({
    int limit = 20,
    String? cursor,
    String? categoryId,
    Object? type,
    Object? availability,
    String? query,
    bool includeArchived = false,
  }) async {
    listCalls++;
    return pageOf([product('p1')]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

AuthSession _session({String userId = 'u1'}) => AuthSession(
      accessToken: 'a',
      refreshToken: 'r',
      accessTokenExpiry: DateTime.now().toUtc().add(const Duration(hours: 1)),
      userId: userId,
    );

/// Lets the microtasks a rebuild schedules land.
Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _CountingCatalogRepo catalogRepo;
  late _CountingProductsRepo productsRepo;
  late ProviderContainer container;

  setUp(() {
    catalogRepo = _CountingCatalogRepo();
    productsRepo = _CountingProductsRepo();
    container = ProviderContainer(
      overrides: [
        authProvider.overrideWith(_StubAuth.new),
        catalogRepositoryProvider.overrideWithValue(catalogRepo),
        catalogProductsRepositoryProvider.overrideWithValue(productsRepo),
      ],
    );
    addTearDown(container.dispose);
  });

  _StubAuth auth() => container.read(authProvider.notifier) as _StubAuth;

  test('sign-out blanks the catalog without fetching for a signed-out user',
      () async {
    container.listen(catalogProvider, (_, __) {}, fireImmediately: true);
    await _settle();
    expect(container.read(catalogProvider).valueOrNull, isNotNull);
    expect(catalogRepo.fetchCalls, 1);

    auth().emit(const AuthUnauthenticated());
    await _settle();

    expect(container.read(catalogProvider).valueOrNull, isNull);
    expect(catalogRepo.fetchCalls, 1, reason: 'no token, no request');
  });

  test('the next sign-in re-fetches the catalog, loading state and all',
      () async {
    container.listen(catalogProvider, (_, __) {}, fireImmediately: true);
    await _settle();
    auth().emit(const AuthUnauthenticated());
    await _settle();

    auth().emit(AuthAuthenticated(_session(userId: 'u2')));

    // The regression: this used to stay AsyncData(null) — the create prompt —
    // with nothing in flight behind it.
    expect(container.read(catalogProvider).isLoading, isTrue);

    await _settle();
    expect(container.read(catalogProvider).valueOrNull, isNotNull);
    expect(catalogRepo.fetchCalls, 2);
  });

  test('a refresh rotation is the same session and does not re-fetch',
      () async {
    final session = _session();
    auth().emit(AuthAuthenticated(session));
    container.listen(catalogProvider, (_, __) {}, fireImmediately: true);
    await _settle();
    expect(catalogRepo.fetchCalls, 1);

    auth().emit(AuthRefreshing(session));
    await _settle();
    auth().emit(AuthAuthenticated(_session()));
    await _settle();

    expect(catalogRepo.fetchCalls, 1);
    expect(container.read(catalogProvider).valueOrNull, isNotNull);
  });

  test('categories reload on the next sign-in', () async {
    container.listen(catalogCategoriesProvider, (_, __) {},
        fireImmediately: true);
    await _settle();
    expect(catalogRepo.listCategoriesCalls, 1);

    auth().emit(const AuthUnauthenticated());
    await _settle();
    expect(catalogRepo.listCategoriesCalls, 1);

    auth().emit(AuthAuthenticated(_session(userId: 'u2')));
    expect(container.read(catalogCategoriesProvider).isLoading, isTrue);
    await _settle();

    expect(catalogRepo.listCategoriesCalls, 2);
  });

  test('the product grid drops the previous session and reloads with skeletons',
      () async {
    container.listen(catalogProductsProvider, (_, __) {}, fireImmediately: true);
    await _settle();
    expect(productsRepo.listCalls, 1);
    expect(container.read(catalogProductsProvider).items, hasLength(1));

    auth().emit(const AuthUnauthenticated());
    await _settle();

    final signedOut = container.read(catalogProductsProvider);
    expect(signedOut.items, isEmpty, reason: "the next user's grid, not this one");
    expect(signedOut.isLoading, isFalse, reason: 'nothing is in flight');
    expect(productsRepo.listCalls, 1);

    auth().emit(AuthAuthenticated(_session(userId: 'u2')));
    // isLoading with no items is what the shell renders as the skeleton grid.
    final signingIn = container.read(catalogProductsProvider);
    expect(signingIn.isLoading, isTrue);
    expect(signingIn.items, isEmpty);

    await _settle();
    expect(productsRepo.listCalls, 2);
    expect(container.read(catalogProductsProvider).items, hasLength(1));
  });
}
