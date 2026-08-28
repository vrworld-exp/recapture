// lib/application/catalog/product_detail_notifier.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_products_repository.dart';
import '../../domain/entities/catalog_product.dart';
import '../../domain/entities/product_availability.dart';
import '../../domain/entities/product_type.dart';
import 'catalog_notifier.dart';
import 'catalog_products_notifier.dart';

/// Which leg of a save is running.
///
/// Exposed for the same reason the create form exposes its own steps: replacing
/// an image is TWO round trips and the slow one is the upload. One
/// undifferentiated spinner over a 5 MiB body on a phone connection reads as a
/// hang, and the two halves fail for different reasons and retry differently.
enum ProductSaveStep {
  idle,

  /// Bytes on the wire.
  uploadingImage,

  /// Binding the uploaded object to the product (`PUT .../image`).
  committingImage,

  /// `PATCH /catalog/products/:id`.
  saving,
}

/// ONE product, fetched by id — the editor's state, and the resolver for any
/// screen reached by a COLD DEEP LINK.
///
/// A browser reload on `/catalog/products/:id` or `.../model` carries nothing in
/// `extra`, so the route parameter is the only input and the product is fetched
/// here rather than handed in. Auto-disposed and family-keyed: the fetch dies
/// with the screen, and two products never share a slot.
///
/// Invariants:
///   - No HTTP here — everything goes through [CatalogProductsRepository].
///   - Every write returns the SERVER's product and that is what lands in state.
///     Nothing is guessed locally: `syncStatus`, `position` and `updatedAt` are
///     all server-derived, and a locally-patched copy would disagree with the
///     grid the moment either is read.
///   - A failed write throws and leaves state untouched — the editor keeps the
///     failure next to the fields the user typed in, and never blanks the form.
class ProductDetailNotifier
    extends AutoDisposeFamilyAsyncNotifier<CatalogProduct, String> {
  CatalogProductsRepository get _repo =>
      ref.read(catalogProductsRepositoryProvider);

  /// Which leg of a save is running. Not part of [state] because it is not the
  /// product: an `AsyncValue` that flipped to loading mid-save would blank the
  /// form the user is looking at.
  final ValueNotifier<ProductSaveStep> step =
      ValueNotifier(ProductSaveStep.idle);

  /// An image that uploaded successfully but whose COMMIT failed.
  ///
  /// Held so the retry is a commit, not a second upload: the bytes are already
  /// in the bucket under this key, and asking a café owner to re-send 5 MiB
  /// because our second call failed is charging them for our problem.
  String? _uncommittedImageKey;

  String? get uncommittedImageKey => _uncommittedImageKey;

  @override
  Future<CatalogProduct> build(String arg) async {
    ref.onDispose(step.dispose);
    return _repo.get(arg);
  }

  /// Re-reads the product from the server.
  Future<void> refresh() async {
    state = AsyncData(await _repo.get(arg));
  }

  /// Patches the editable fields.
  ///
  /// [price] and [categoryId] take the repository's sentinel semantics: pass
  /// null to CLEAR (no price / Uncategorized), omit to leave alone. Nothing else
  /// distinguishes "clear this" from "I did not touch it", and both are ordinary
  /// things a user does.
  Future<CatalogProduct> save({
    String? name,
    String? description,
    Object? price = kCatalogUnchanged,
    Object? categoryId = kCatalogUnchanged,
    List<String>? tags,
    ProductAvailability? availability,
    bool? featured,
  }) async {
    step.value = ProductSaveStep.saving;
    try {
      final updated = await _repo.update(
        arg,
        name: name,
        description: description,
        price: price,
        categoryId: categoryId,
        tags: tags,
        availability: availability,
        featured: featured,
      );
      _adopt(updated);
      return updated;
    } finally {
      step.value = ProductSaveStep.idle;
    }
  }

  /// Replaces the product's image (feature 16): upload the bytes, then bind the
  /// key to the product.
  ///
  /// If the upload succeeds and the commit fails, the key is kept and
  /// [retryCommitImage] finishes the job without re-uploading. The presigned URL
  /// that a native caller might use for this never appears here and is never
  /// logged — it is a write credential, not a diagnostic.
  Future<CatalogProduct> replaceImage(
    Uint8List bytes, {
    required String contentType,
  }) async {
    step.value = ProductSaveStep.uploadingImage;
    final String key;
    try {
      key = await _repo.uploadImageBytes(
        bytes,
        contentType: contentType,
        productId: arg,
      );
    } catch (_) {
      step.value = ProductSaveStep.idle;
      rethrow;
    }

    _uncommittedImageKey = key;
    return _commit(key);
  }

  /// Finishes an image replacement whose commit failed. No-op when there is
  /// nothing pending.
  Future<CatalogProduct?> retryCommitImage() async {
    final key = _uncommittedImageKey;
    if (key == null) return null;
    return _commit(key);
  }

  Future<CatalogProduct> _commit(String key) async {
    step.value = ProductSaveStep.committingImage;
    try {
      final updated = await _repo.commitImage(arg, key);
      _uncommittedImageKey = null;
      _adopt(updated);
      return updated;
    } finally {
      step.value = ProductSaveStep.idle;
    }
  }

  /// Converts the product to [type], carrying the asset the new type needs.
  ///
  /// The asset travels in the SAME request because the server refuses a
  /// conversion without it — that is what stops a product ending up typed for an
  /// asset it does not have.
  Future<CatalogProduct> convert({
    required ProductType type,
    String? sourceModelId,
    String? imageKey,
  }) async {
    step.value = ProductSaveStep.saving;
    try {
      final updated = await _repo.update(
        arg,
        type: type,
        sourceModelId: sourceModelId,
        imageKey: imageKey,
      );
      _adopt(updated);
      return updated;
    } finally {
      step.value = ProductSaveStep.idle;
    }
  }

  /// Duplicates the product (feature 18) and returns the COPY.
  ///
  /// Server-side, and auto-renamed there: Mirage keys items by name within a
  /// restaurant, so two products sharing a name would collide at publish — long
  /// after the user pressed Duplicate and stopped thinking about it. The copy
  /// gets "(copy)", "(copy 2)" and so on, which is also why duplicating a
  /// product already called "… (copy)" is not a special case here.
  Future<CatalogProduct> duplicate() async {
    step.value = ProductSaveStep.saving;
    try {
      final copy = await _repo.duplicate(arg);
      // The grid is a page of products and the copy belongs in it; a refresh is
      // how it gets there in the right position rather than guessed onto the
      // end.
      await _refreshSurroundings();
      return copy;
    } finally {
      step.value = ProductSaveStep.idle;
    }
  }

  /// Adopts a server-returned product and tells the surfaces that show it.
  void _adopt(CatalogProduct updated) {
    state = AsyncData(updated);
    // The grid holds a snapshot from whenever its page was fetched; replacing
    // the row by id is cheaper and less jarring than re-paginating.
    ref.read(catalogProductsProvider.notifier).replace(updated);
    _refreshCatalogHeader();
  }

  Future<void> _refreshSurroundings() async {
    await ref.read(catalogProductsProvider.notifier).refresh();
    _refreshCatalogHeader();
  }

  /// The header's counts and its "Draft changes not yet live" badge are both
  /// SERVER-derived, and every write here moves the draft revision. Refresh
  /// rather than incrementing locally — guessing that flag is how the badge ends
  /// up claiming edits are live when they are not.
  ///
  /// Best-effort: the write has already succeeded, and a failed refresh must not
  /// turn it into an error the user sees.
  void _refreshCatalogHeader() {
    ref.read(catalogProvider.notifier).refresh().catchError((_) {});
  }
}

/// ONE product by id.
///
/// Still named `productDetailProvider` and still read as an `AsyncValue`, so the
/// change-model screen's `watch` and `invalidate` are unchanged — it grew a
/// notifier underneath rather than a second provider beside it, because two
/// providers fetching the same product is two answers to "what is this product
/// now".
final productDetailProvider = AsyncNotifierProvider.autoDispose
    .family<ProductDetailNotifier, CatalogProduct, String>(
  ProductDetailNotifier.new,
);
