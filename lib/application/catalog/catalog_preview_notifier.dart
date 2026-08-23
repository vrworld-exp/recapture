// lib/application/catalog/catalog_preview_notifier.dart
//
// Loads the whole draft for the preview screen (feature 5, task T-026).
//
// SELF-CONTAINED rather than composed out of the grid's state, and that is the
// point of the file. The grid holds ONE PAGE of a FILTERED query — the preview
// has to show every live product, in catalog order, whatever the user last
// typed into the search box. Reading the grid's items would produce a preview
// that silently changes shape depending on which screen the user came from.
//
// Everything here is a ReCapture read. Mirage is never consulted: it does not
// have the draft, which is the whole reason a pre-publish preview exists
// (feature 57).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/business_profile_repository.dart';
import '../../data/repositories/catalog_failure.dart';
import '../../data/repositories/catalog_products_repository.dart';
import '../../data/repositories/catalog_repository.dart';
import '../../domain/catalog/catalog_preview.dart';
import '../../domain/entities/catalog_product.dart';

/// Products per request while reading the whole catalog. The backend hard-caps
/// `limit` at 100, so this is the fewest round trips the API allows.
const int kPreviewPageSize = 100;

/// Most pages one preview load will read.
///
/// A ceiling, not a target: 20 pages is 2,000 products, far past anything this
/// product is scoped for, and it exists so a cursor the server never retires
/// cannot spin this loop forever. Hitting it truncates the preview rather than
/// hanging the screen — the catalog still renders, just not all of it.
const int kPreviewMaxPages = 20;

/// The composed draft, or an error.
///
/// `AsyncData` always carries a real [CatalogPreview]: the "no catalog yet"
/// state cannot reach this screen (there is nothing to preview and no way to
/// navigate here), so it is reported as a failure rather than modelled as a
/// third success case.
class CatalogPreviewNotifier extends AutoDisposeAsyncNotifier<CatalogPreview> {
  /// Set once the provider is gone. Four awaited reads run inside one refresh,
  /// and the user can leave at any point in them — writing `state` after that
  /// throws, which would surface as an unhandled async error rather than as
  /// the nothing it should be.
  bool _disposed = false;

  @override
  Future<CatalogPreview> build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    return _load();
  }

  /// Re-reads everything, keeping the current page on screen while it happens.
  /// Pull-to-refresh, and the return from a product the user went off to fix.
  Future<void> refresh() async {
    try {
      final preview = await _load();
      if (_disposed) return;
      state = AsyncData(preview);
    } catch (error, stack) {
      if (_disposed) return;
      // A failed background refresh must not blank a preview the user is
      // reading — only surface it when there is nothing behind it.
      if (state.valueOrNull == null) state = AsyncError(error, stack);
    }
  }

  Future<CatalogPreview> _load() async {
    final catalogRepo = ref.read(catalogRepositoryProvider);
    final productsRepo = ref.read(catalogProductsRepositoryProvider);
    final profileRepo = ref.read(businessProfileRepositoryProvider);

    // Started together, awaited together: four independent reads, and the
    // screen needs all of them before it can render one honest page.
    final catalogFuture = catalogRepo.fetch();
    final categoriesFuture = catalogRepo.listCategories();
    final productsFuture = _allProducts(productsRepo);
    // Branding is the ONLY optional part: a header without a logo is still a
    // truthful preview, so a failed profile read degrades rather than taking
    // the screen down with it.
    final profileFuture =
        profileRepo.fetch().onError<Object>((_, __) => null);

    final catalog = await catalogFuture;
    final categories = await categoriesFuture;
    final products = await productsFuture;
    final profile = await profileFuture;

    if (catalog == null) {
      // There is nothing to preview and no way to have navigated here. Reported
      // as a failure rather than an empty page, because an empty BRANDED page
      // is a legitimate preview state and these two must not look alike.
      throw const CatalogFailure(
        code: CatalogErrorCodes.noCatalog,
        message: 'Create your catalog before previewing it.',
      );
    }

    return CatalogPreview.compose(
      catalog: catalog,
      profile: profile,
      categories: categories.categories,
      products: products,
    );
  }

  /// Reads every page of products, unfiltered and unarchived.
  ///
  /// `includeArchived` stays false: an archived product is not on the public
  /// page and is removed from Mirage at the next publish, so previewing one
  /// would show a page that will never exist. [CatalogPreview.compose] filters
  /// again defensively — the server is the authority, not this flag.
  Future<List<CatalogProduct>> _allProducts(
    CatalogProductsRepository repo,
  ) async {
    final all = <CatalogProduct>[];
    String? cursor;

    for (var page = 0; page < kPreviewMaxPages; page++) {
      final result = await repo.list(limit: kPreviewPageSize, cursor: cursor);
      all.addAll(result.items);
      cursor = result.nextCursor;
      if (cursor == null) break;
    }

    return all;
  }
}

/// The preview's composed draft.
///
/// autoDispose, deliberately: a preview is a snapshot of the moment it was
/// opened, and a kept-alive one would show the second visitor a page the user
/// has since edited — on the one screen whose entire job is to be current.
final catalogPreviewProvider =
    AutoDisposeAsyncNotifierProvider<CatalogPreviewNotifier, CatalogPreview>(
  CatalogPreviewNotifier.new,
);
