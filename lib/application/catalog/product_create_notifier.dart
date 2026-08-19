// lib/application/catalog/product_create_notifier.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_products_repository.dart';
import '../../domain/entities/catalog_product.dart';
import '../../domain/entities/product_availability.dart';
import '../../domain/entities/product_type.dart';
import 'catalog_notifier.dart';

/// Which leg of a create is running. Exposed because an image create is TWO
/// round trips and the slow one is the upload: a single "Creating…" spinner
/// over a 5 MiB upload on a phone connection looks like a hang, so the button
/// says which half it is on.
enum ProductCreateStep {
  idle,

  /// Bytes on the wire. Only ever reached by the image-only path.
  uploadingImage,

  /// `POST /catalog/products`.
  creating,
}

/// Creates catalog products (features 6, 7, 11, 12, 13).
///
/// Owns the ORDER the two-step image create has to run in, which is the only
/// real logic here: the image is uploaded FIRST and the product is created with
/// the resulting key, because the server refuses an image-only product that has
/// no image (a card with nothing on it can never publish, so it is rejected
/// while the user is still looking at the form rather than at publish time).
///
/// [submit] THROWS on failure — a [CatalogFailure] carrying the backend's own
/// owner-safe sentence — rather than parking the error in state. The form keeps
/// the failure next to the fields the user typed in, exactly like the
/// create-catalog dialog, and a failed create must not blank anything.
class ProductCreateNotifier extends AutoDisposeNotifier<ProductCreateStep> {
  @override
  ProductCreateStep build() => ProductCreateStep.idle;

  bool get isSubmitting => state != ProductCreateStep.idle;

  /// Creates one product and returns it.
  ///
  /// Exactly one of [imageBytes] / [sourceModelId] is meaningful, chosen by
  /// [type] — the server enforces the pairing and rejects the other field, so
  /// this does not re-validate it.
  Future<CatalogProduct> submit({
    required ProductType type,
    required String name,
    String? description,
    double? price,
    ProductAvailability? availability,
    bool? featured,
    String? sourceModelId,
    Uint8List? imageBytes,
    String? imageContentType,
  }) async {
    final repo = ref.read(catalogProductsRepositoryProvider);

    String? imageKey;
    if (type == ProductType.imageOnly) {
      state = ProductCreateStep.uploadingImage;
      try {
        // No productId: the product does not exist yet, so the server stages
        // the object under a fresh slot and the key is bound by the create
        // below. A create that then fails leaves one orphaned object, which the
        // next commit's prefix sweep collects — the alternative, creating the
        // product first, would leave a product that can never publish.
        imageKey = await repo.uploadImageBytes(
          imageBytes!,
          contentType: imageContentType!,
        );
      } catch (_) {
        state = ProductCreateStep.idle;
        rethrow;
      }
    }

    state = ProductCreateStep.creating;
    final CatalogProduct product;
    try {
      product = await repo.create(
        type: type,
        name: name,
        description: description,
        price: price,
        availability: availability,
        featured: featured,
        sourceModelId: sourceModelId,
        imageKey: imageKey,
      );
    } catch (_) {
      state = ProductCreateStep.idle;
      rethrow;
    }

    // The catalog header shows server-derived product counts and the
    // "Draft changes not yet live" badge, and this write moved both. Refresh
    // rather than incrementing locally: `hasUnpublishedChanges` is recomputed
    // server-side, and guessing it is how the badge ends up claiming edits are
    // live when they are not.
    //
    // Awaited but not fatal — the product IS created, and a failed refresh must
    // not turn a success into an error the user sees.
    try {
      await ref.read(catalogProvider.notifier).refresh();
    } catch (_) {/* the next pull-to-refresh reconciles it */}

    state = ProductCreateStep.idle;
    return product;
  }
}

/// The add-product form's create action. Auto-disposed with the screen, so a
/// half-finished step never leaks into the next visit.
final productCreateProvider =
    AutoDisposeNotifierProvider<ProductCreateNotifier, ProductCreateStep>(
  ProductCreateNotifier.new,
);
