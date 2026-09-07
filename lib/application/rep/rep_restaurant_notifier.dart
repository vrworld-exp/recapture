// lib/application/rep/rep_restaurant_notifier.dart
//
// The delegated RESTAURANT, as opposed to the dishes on it: the catalog
// document, its sections, and the composed preview of the page a publish would
// produce.
//
// WHY THE PREVIEW IS HERE AND NOT REUSED FROM [catalogPreviewProvider]. That
// provider composes from four OWNER reads, each of which resolves "my catalog"
// from the token. A rep has no catalog of their own — usually none at all — so
// pointing it at a restaurant would mean threading a scope through four owner
// repositories and every one of their call sites. The composition itself is the
// part worth sharing, and it already is: [CatalogPreview.compose] holds every
// ordering, grouping and gate rule, and both providers hand it the same four
// arguments. What differs is only where the four came from.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_failure.dart';
import '../../data/repositories/rep_repository.dart';
import '../../domain/catalog/catalog_preview.dart';
import '../../domain/entities/business_profile.dart';
import '../../domain/entities/catalog.dart';
import '../../domain/entities/catalog_category.dart';
import '../catalog/business_profile_notifier.dart';
import '../../domain/catalog/catalog_scope.dart';

/// The catalog DOCUMENT behind one delegated restaurant.
///
/// Read for its `hasUnpublishedChanges` — the server-derived flag every
/// "nothing here is live yet" line on the rep surface hangs off — and for the
/// counts and name the details screen shows. Never recomputed locally: an edit
/// bumps `draftRevision` on the server and this reads the result.
///
/// autoDispose: it is a header, not a session fact, and a stale one would tell a
/// rep their edits were published when they were not.
final repCatalogDocumentProvider =
    FutureProvider.autoDispose.family<Catalog, String>(
  (ref, catalogId) => ref.read(repRepositoryProvider).catalog(catalogId),
);

/// The sections the restaurant's public page will have.
///
/// Read-only on this surface, which is the server's rule too — there is no
/// delegated route that creates, renames or reorders a category. A rep files a
/// dish into a section the owner made, and never reshapes the page itself.
final repCategoriesProvider =
    FutureProvider.autoDispose.family<CatalogCategoryList, String>(
  (ref, catalogId) => ref.read(repRepositoryProvider).categories(catalogId),
);

/// The composed draft of one delegated restaurant's public page.
///
/// autoDispose, deliberately, for the same reason the owner's preview is: a
/// preview is a snapshot of the moment it was opened, and a kept-alive one would
/// show a rep the page as it was before the dish they just fixed — on the one
/// screen whose entire job is to be current.
class RepPreviewNotifier
    extends AutoDisposeFamilyAsyncNotifier<CatalogPreview, String> {
  /// Set once the provider is gone. Four awaited reads run inside one refresh
  /// and the rep can leave at any point in them — writing `state` after that
  /// throws, which would surface as an unhandled async error rather than as the
  /// nothing it should be.
  bool _disposed = false;

  @override
  Future<CatalogPreview> build(String arg) {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    return _load();
  }

  /// Re-reads everything, keeping the current page on screen while it happens.
  /// Pull-to-refresh, and the return from a dish the rep went off to fix.
  Future<void> refresh() async {
    try {
      final preview = await _load();
      if (_disposed) return;
      state = AsyncData(preview);
    } catch (error, stack) {
      if (_disposed) return;
      // A failed background refresh must not blank a preview the rep is
      // reading — only surface it when there is nothing behind it.
      if (state.valueOrNull == null) state = AsyncError(error, stack);
    }
  }

  Future<CatalogPreview> _load() async {
    final repo = ref.read(repRepositoryProvider);

    // Started together, awaited together: four independent reads, and the
    // screen needs all of them before it can render one honest page.
    final catalogFuture = repo.catalog(arg);
    final categoriesFuture = repo.categories(arg);
    final productsFuture = repo.products(arg);
    // Branding is the ONLY optional part: a header without a logo is still a
    // truthful preview, so a failed profile read degrades rather than taking the
    // screen down with it.
    // Widened to nullable BEFORE the recovery, so "we could not read the
    // branding" is expressible at all — `profile()` itself never answers null.
    final Future<BusinessProfile?> profileFuture = repo
        .profile(arg)
        .then<BusinessProfile?>((profile) => profile)
        .onError<Object>((_, __) => null);

    final catalog = await catalogFuture;
    final categories = await categoriesFuture;
    final products = await productsFuture;
    final profile = await profileFuture;

    return CatalogPreview.compose(
      catalog: catalog,
      profile: profile,
      categories: categories.categories,
      products: products,
    );
  }
}

/// One delegated restaurant's preview, keyed by catalog id.
final repPreviewProvider = AsyncNotifierProvider.autoDispose
    .family<RepPreviewNotifier, CatalogPreview, String>(
  RepPreviewNotifier.new,
);

/// The restaurant's business profile, for the rep's details screen.
///
/// A named alias for the delegated instance of [businessProfileFor], so the rep
/// screens read the same word the owner ones do rather than assembling a scope
/// at each call site. Same provider, same state, same notifier — the scope IS
/// the difference.
AsyncNotifierFamilyProvider<BusinessProfileNotifier, BusinessProfile?,
        CatalogScope>
    repProfileProvider(String catalogId) =>
        businessProfileFor(CatalogScope.delegated(catalogId));

/// Whether a delegated read failed because the delegation is gone.
///
/// The server answers a revoked delegation and a nonexistent catalog with the
/// SAME 404 (see routes/rep.ts), which is deliberate — a rep must not be able to
/// probe for catalogs they do not hold. It also means this is the one code the
/// screens can act on: the restaurant is no longer theirs to edit, and the
/// honest move is to send them back to the list rather than offer a retry that
/// will fail identically.
bool isDelegationGone(Object error) =>
    error is CatalogFailure && error.code == RepErrorCodes.catalogNotFound;
