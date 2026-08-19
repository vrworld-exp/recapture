// lib/application/catalog/product_detail_notifier.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_products_repository.dart';
import '../../domain/entities/catalog_product.dart';

/// ONE product, fetched by id.
///
/// Exists so a screen reached by a COLD DEEP LINK (a browser reload on
/// `/catalog/products/:id/model`) can resolve the product itself instead of
/// depending on something handed to it through `extra`, which a reload does not
/// carry. The route parameter is the only input.
///
/// Auto-disposed and family-keyed: the fetch dies with the screen, and two
/// products never share a slot. Throws whatever the repository throws — a
/// [CatalogFailure] with the backend's own owner-safe copy, including the
/// indistinguishable NOT_FOUND that a stale or foreign id produces.
final productDetailProvider =
    FutureProvider.autoDispose.family<CatalogProduct, String>(
  (ref, productId) =>
      ref.read(catalogProductsRepositoryProvider).get(productId),
);
