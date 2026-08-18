// lib/data/repositories/catalog_products_repository.dart
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/catalog_product.dart';
import '../../domain/entities/product_availability.dart';
import '../../domain/entities/product_type.dart';
import '../remote/api_client.dart';
import 'catalog_failure.dart';

/// One page of products plus the cursor for the next one.
///
/// Cursor paging, not offset: the grid is reorderable and the server's cursor is
/// `(position, _id)`, so an offset page would skip or repeat rows the moment
/// anything moved.
class CatalogProductPage {
  const CatalogProductPage({required this.items, this.nextCursor});

  final List<CatalogProduct> items;

  /// Opaque — pass it back verbatim. Null means this was the last page.
  final String? nextCursor;

  bool get hasMore => nextCursor != null;

  static const empty = CatalogProductPage(items: <CatalogProduct>[]);
}

/// The bulk actions `POST /catalog/products/bulk` accepts (feature 30).
enum BulkProductAction { archive, restore, delete, setCategory }

extension BulkProductActionX on BulkProductAction {
  /// Must match the backend `BULK_PRODUCT_ACTIONS` exactly.
  String get apiValue => switch (this) {
        BulkProductAction.archive => 'ARCHIVE',
        BulkProductAction.restore => 'RESTORE',
        BulkProductAction.delete => 'DELETE',
        BulkProductAction.setCategory => 'SET_CATEGORY',
      };
}

/// Data access for catalog products.
///
/// Every method throws [CatalogFailure] on failure — never a [DioException].
/// Nothing here reaches customers: these are authoring writes against the draft,
/// and the live catalog only moves on an explicit publish (feature 57).
abstract interface class CatalogProductsRepository {
  /// One page of products.
  ///
  /// [categoryId] accepts a real id, or the literal `'none'` for Uncategorized —
  /// null means "no category filter at all", which is a third, different thing.
  /// [query] is a case-insensitive substring match on the name.
  Future<CatalogProductPage> list({
    int limit,
    String? cursor,
    String? categoryId,
    ProductType? type,
    ProductAvailability? availability,
    String? query,
    bool includeArchived,
  });

  Future<CatalogProduct> get(String id);

  /// Creates a product.
  ///
  /// A 3D product REQUIRES [sourceModelId] — a finished model the caller owns —
  /// and an image-only product must not carry one; the server enforces both. The
  /// asset URLs are copied server-side from that model and frozen on the product.
  Future<CatalogProduct> create({
    required ProductType type,
    required String name,
    String? description,
    double? price,
    String? categoryId,
    List<String>? tags,
    ProductAvailability? availability,
    bool? featured,
    String? sourceModelId,
  });

  /// Patches editable fields. `type` is deliberately NOT patchable: converting
  /// image-only → 3D forces a delete-and-recreate on Mirage (the product gets a
  /// new public link), so it needs its own deliberate flow.
  ///
  /// [categoryId] uses a sentinel so that passing null explicitly means "move to
  /// Uncategorized", distinct from omitting it.
  Future<CatalogProduct> update(
    String id, {
    String? name,
    String? description,
    double? price,
    Object? categoryId,
    List<String>? tags,
    ProductAvailability? availability,
    bool? featured,
  });

  /// Archive (feature 19) — hides the product and removes it from the public
  /// catalog on the next publish, reversibly.
  Future<CatalogProduct> archive(String id);

  /// Restore an archived product (feature 20).
  Future<CatalogProduct> restore(String id);

  /// Permanent delete (feature 21). Not reversible.
  Future<void> delete(String id);

  /// Writes a new product order. Send the FULL ordered id list — a partial set
  /// is rejected with ID_SET_MISMATCH rather than guessed at.
  ///
  /// ⚠ Ordering is ReCapture-only: the public catalog sorts by creation date.
  Future<void> reorder(List<String> orderedIds);

  /// Applies one action to many products and returns how many were affected.
  /// [categoryId] is required by [BulkProductAction.setCategory] (null =
  /// Uncategorized) and rejected for every other action.
  Future<int> bulk({
    required BulkProductAction action,
    required List<String> ids,
    Object? categoryId,
  });
}

/// Concrete [CatalogProductsRepository] over the app Dio.
class RemoteCatalogProductsRepository implements CatalogProductsRepository {
  const RemoteCatalogProductsRepository(this._dio);

  final Dio _dio;

  @override
  Future<CatalogProductPage> list({
    int limit = 20,
    String? cursor,
    String? categoryId,
    ProductType? type,
    ProductAvailability? availability,
    String? query,
    bool includeArchived = false,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/catalog/products',
          queryParameters: {
            'limit': limit,
            if (cursor != null) 'cursor': cursor,
            if (categoryId != null) 'categoryId': categoryId,
            // `unknown` is a local fallback for a value this build does not
            // recognise; sending it would be a 400, so it is never a filter.
            if (type != null && type != ProductType.unknown) 'type': type.apiValue,
            if (availability != null && availability != ProductAvailability.unknown)
              'availability': availability.apiValue,
            if (query != null && query.trim().isNotEmpty) 'q': query.trim(),
            // The query schema is `.strict()` and parses this as a string enum.
            'includeArchived': includeArchived ? 'true' : 'false',
          },
        );

        final items = res.data?['items'];
        final next = res.data?['nextCursor'];
        return CatalogProductPage(
          items: [
            if (items is List)
              for (final item in items)
                if (item is Map<String, dynamic>) CatalogProduct.fromMap(item),
          ],
          nextCursor: next is String && next.isNotEmpty ? next : null,
        );
      });

  @override
  Future<CatalogProduct> get(String id) => mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>('/catalog/products/$id');
        return _productFrom(res.data);
      });

  @override
  Future<CatalogProduct> create({
    required ProductType type,
    required String name,
    String? description,
    double? price,
    String? categoryId,
    List<String>? tags,
    ProductAvailability? availability,
    bool? featured,
    String? sourceModelId,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/catalog/products',
          data: {
            'type': type.apiValue,
            'name': name,
            if (description != null) 'description': description,
            if (price != null) 'price': price,
            if (categoryId != null) 'categoryId': categoryId,
            if (tags != null) 'tags': tags,
            if (availability != null) 'availability': availability.apiValue,
            if (featured != null) 'featured': featured,
            if (sourceModelId != null) 'sourceModelId': sourceModelId,
          },
        );
        return _productFrom(res.data);
      });

  @override
  Future<CatalogProduct> update(
    String id, {
    String? name,
    String? description,
    double? price,
    Object? categoryId = _unset,
    List<String>? tags,
    ProductAvailability? availability,
    bool? featured,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.patch<Map<String, dynamic>>(
          '/catalog/products/$id',
          data: {
            if (name != null) 'name': name,
            if (description != null) 'description': description,
            if (price != null) 'price': price,
            // Explicit null is meaningful — it moves the product to
            // Uncategorized — so the sentinel, not null, marks "unchanged".
            if (!identical(categoryId, _unset)) 'categoryId': categoryId,
            if (tags != null) 'tags': tags,
            if (availability != null) 'availability': availability.apiValue,
            if (featured != null) 'featured': featured,
          },
        );
        return _productFrom(res.data);
      });

  @override
  Future<CatalogProduct> archive(String id) => _setArchived(id, 'archive');

  @override
  Future<CatalogProduct> restore(String id) => _setArchived(id, 'restore');

  Future<CatalogProduct> _setArchived(String id, String verb) =>
      mapCatalogErrors(() async {
        final res =
            await _dio.post<Map<String, dynamic>>('/catalog/products/$id/$verb');
        return _productFrom(res.data);
      });

  @override
  Future<void> delete(String id) => mapCatalogErrors(() async {
        await _dio.delete<Map<String, dynamic>>('/catalog/products/$id');
      });

  @override
  Future<void> reorder(List<String> orderedIds) => mapCatalogErrors(() async {
        await _dio.post<Map<String, dynamic>>(
          '/catalog/products/reorder',
          data: {'ids': orderedIds},
        );
      });

  @override
  Future<int> bulk({
    required BulkProductAction action,
    required List<String> ids,
    Object? categoryId = _unset,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/catalog/products/bulk',
          data: {
            'action': action.apiValue,
            'ids': ids,
            // SET_CATEGORY needs the key even when the value is null
            // (Uncategorized); every other action is rejected if it is present.
            if (!identical(categoryId, _unset)) 'categoryId': categoryId,
          },
        );
        final affected = res.data?['affected'];
        return affected is num && affected >= 0 ? affected.toInt() : 0;
      });

  /// Unwraps `{status:"success", product:{...}}`. A 2xx without the payload is a
  /// broken contract, not an empty result.
  CatalogProduct _productFrom(Map<String, dynamic>? body) {
    final product = body?['product'];
    if (product is! Map<String, dynamic>) {
      throw const CatalogFailure(
        code: 'MALFORMED_RESPONSE',
        message: 'Something went wrong. Please try again.',
      );
    }
    return CatalogProduct.fromMap(product);
  }
}

/// Sentinel for "argument not supplied" where null is itself a valid value.
const Object _unset = Object();

/// App-wide catalog products repository.
final catalogProductsRepositoryProvider = Provider<CatalogProductsRepository>(
  (ref) => RemoteCatalogProductsRepository(ref.watch(dioProvider)),
);
