// test/rep/rep_draft_badge_test.dart
//
// The rep's half of feature 38: "this is not live yet", on a restaurant the rep
// does not own.
//
// THE ASYMMETRY THAT MAKES THIS ITS OWN SUITE. On the owner surface the flag
// lives on `catalogProvider` — one app-wide document, refreshed by whoever
// wrote. A rep has no catalog of their own, so the same flag arrives on
// `repCatalogDocumentProvider(catalogId)`, a family keyed by restaurant, and the
// rule for the OWNER provider is the exact opposite: a delegated write must
// never touch it, because for a rep it is a different restaurant or none at
// all. That "never touch it" was doing too much work — a delegated write ended
// up refreshing NOTHING, and the rep's own banner went on insisting the menu was
// fully published while their edit sat in draft.
//
// So each test here pins one of two things:
//   • a delegated write re-reads the DELEGATED document, and
//   • it leaves the owner's alone.
//
// Hermetic: the rep repository is a fake, the clock is `Future.delayed`.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/catalog/business_profile_notifier.dart';
import 'package:recapture/application/rep/rep_catalogs_notifier.dart';
import 'package:recapture/application/rep/rep_restaurant_notifier.dart';
import 'package:recapture/application/common/pending_poll_loop.dart';
import 'package:recapture/data/repositories/catalog_repository.dart' show BrandingSlot;
import 'package:recapture/data/repositories/rep_repository.dart';
import 'package:recapture/domain/catalog/catalog_scope.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/business_profile.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/domain/entities/product_model_status.dart';
import 'package:recapture/domain/entities/product_type.dart';

import 'rep_restaurant_editing_test.dart' show FakeRepRepository, kDishId;

const String _catalogId = 'cat_delegated_1';

/// [FakeRepRepository] with a scriptable dish list.
///
/// The shared fake answers `products` with one fixed dish, which is exactly
/// right for the editor tests and useless for a poll loop — the loop is entirely
/// about the list CHANGING under it.
class _PollingRepo extends FakeRepRepository {
  _PollingRepo(this._pages);

  /// One entry per call; the last repeats once exhausted.
  final List<List<CatalogProduct>> _pages;
  int productCalls = 0;

  @override
  Future<List<CatalogProduct>> products(String catalogId) async {
    productCalls++;
    return _pages[(productCalls - 1).clamp(0, _pages.length - 1)];
  }
}

CatalogProduct _dish(ProductModelStatus status) => CatalogProduct(
      id: kDishId,
      type: ProductType.threeD,
      name: 'masala_dosa',
      currency: 'INR',
      position: 0,
      modelStatus: status,
      glbUrl: status == ProductModelStatus.ready ? 'https://cdn/d.glb' : null,
    );

/// Auth held still — [BusinessProfileNotifier] is session-scoped, and the real
/// notifier would reach for secure storage.
class _StubAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

ProviderContainer _container(RepRepository repo) {
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith(_StubAuth.new),
      sessionIdentityProvider.overrideWithValue('session-1'),
      repRepositoryProvider.overrideWithValue(repo),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Keeps [repCatalogDocumentProvider] alive and re-reading.
///
/// It is autoDispose, and an invalidate is deliberately a NO-OP for a family key
/// nobody is watching — which is the behaviour the production code relies on. A
/// test asserting the re-read therefore has to be the watcher the real screen
/// would be.
void _watchDocument(ProviderContainer container) =>
    container.listen(repCatalogDocumentProvider(_catalogId), (_, __) {},
        fireImmediately: true);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('a delegated profile write', () {
    test('re-reads the restaurant the rep is standing in', () async {
      final repo = FakeRepRepository();
      final container = _container(repo);
      _watchDocument(container);
      await _settle();
      final before = repo.catalogCalls;

      await container
          .read(businessProfileFor(const CatalogScope.delegated(_catalogId))
              .notifier)
          .save(
            name: 'Cafe Mocha',
            businessName: 'Mocha Foods',
            contact: const BusinessContact(),
          );
      await _settle();

      expect(repo.profilePatches, hasLength(1));
      // THE ASSERTION. The rep's own "nothing here is live yet" banner reads
      // this document; leaving it stale is how a rep is told there is nothing
      // waiting to publish immediately after they changed something.
      expect(repo.catalogCalls, before + 1);
    });

    test('a branding commit does too — a cover photo is a draft change',
        () async {
      final repo = FakeRepRepository();
      final container = _container(repo);
      _watchDocument(container);
      await _settle();
      final before = repo.catalogCalls;

      final bound = await container
          .read(businessProfileFor(const CatalogScope.delegated(_catalogId))
              .notifier)
          .uploadBranding(
            BrandingSlot.cover,
            Uint8List.fromList(const [1, 2, 3]),
            contentType: 'image/jpeg',
          );
      await _settle();

      expect(bound, isTrue);
      expect(repo.catalogCalls, before + 1);
    });

    test('never reaches for the OWNER catalog', () async {
      // `catalogProvider` is the signed-in user's own, and for a rep that is a
      // different restaurant or none at all. Building it here would fire a read
      // this session has no business making — and would put the wrong
      // restaurant's draft state behind the banner.
      final repo = FakeRepRepository();
      final container = _container(repo);
      _watchDocument(container);
      await _settle();

      await container
          .read(businessProfileFor(const CatalogScope.delegated(_catalogId))
              .notifier)
          .save(
            name: 'Cafe Mocha',
            businessName: null,
            contact: const BusinessContact(),
          );
      await _settle();

      // No override for the owner repository is installed, so a read of it
      // would have thrown rather than quietly succeeded.
      expect(repo.profilePatches, hasLength(1));
    });
  });

  group("the rep's dish list", () {
    test('a landed model re-reads the catalog document', () async {
      final repo = _PollingRepo([
        [_dish(ProductModelStatus.processing)],
        [_dish(ProductModelStatus.ready)],
      ]);
      final container = _container(repo);
      _watchDocument(container);
      container.read(repCatalogProductsProvider(_catalogId));
      await _settle();

      expect(
        container.read(repCatalogProductsProvider(_catalogId).notifier).isPolling,
        isTrue,
      );
      final before = repo.catalogCalls;

      await Future<void>.delayed(
        kPendingPollInitialInterval + const Duration(milliseconds: 50),
      );

      expect(
        container.read(repCatalogProductsProvider(_catalogId)).value!.single
            .modelStatus,
        ProductModelStatus.ready,
      );
      // The promotion that turned this dish 3D bumped `draftRevision` on the
      // server. The rep is watching it happen and navigating nowhere, so no
      // route return will re-read the document for them — without this the
      // publish bar goes on saying the menu is fully published.
      expect(repo.catalogCalls, before + 1);
    });

    test('a tick where the model is still generating does not', () async {
      final repo = _PollingRepo([
        [_dish(ProductModelStatus.processing)],
      ]);
      final container = _container(repo);
      _watchDocument(container);
      container.read(repCatalogProductsProvider(_catalogId));
      await _settle();
      final before = repo.catalogCalls;

      await Future<void>.delayed(
        kPendingPollInitialInterval + const Duration(milliseconds: 50),
      );

      // Nothing settled, so nothing moved server-side either. Re-fetching the
      // document on every tick would double the request rate for the whole
      // length of a generation, on a rep's mobile data.
      expect(repo.catalogCalls, before);
    });
  });
}
