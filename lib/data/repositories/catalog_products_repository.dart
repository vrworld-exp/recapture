// lib/data/repositories/catalog_products_repository.dart
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/catalog_json.dart';
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

/// One presigned upload slot: where to PUT the bytes, and the key to send back
/// at commit.
///
/// [url] is a WRITE bearer credential for exactly that key until [expiresAt].
/// It belongs in a PUT and nowhere else — never a log line, never analytics.
class ProductImageSlot {
  const ProductImageSlot({
    required this.key,
    required this.url,
    required this.expiresAt,
  });

  final String key;
  final String url;
  final DateTime? expiresAt;

  factory ProductImageSlot.fromMap(Map<String, dynamic> map) => ProductImageSlot(
        key: (map['key'] ?? '').toString(),
        url: (map['url'] ?? '').toString(),
        expiresAt: catalogDate(map['expiresAt']),
      );
}

/// The image content types the backend will presign. Sending anything else is a
/// 400: the type is baked into the signature, so this set also fixes what can
/// ever be stored.
enum ProductImageContentType { jpeg, png, webp }

extension ProductImageContentTypeX on ProductImageContentType {
  String get apiValue => switch (this) {
        ProductImageContentType.jpeg => 'image/jpeg',
        ProductImageContentType.png => 'image/png',
        ProductImageContentType.webp => 'image/webp',
      };
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
  /// The two types need different things and the server enforces both:
  ///   • 3D REQUIRES [sourceModelId] — a finished model the caller owns — and
  ///     must not carry [imageKey]; its card image is the model's generated
  ///     preview. The asset URLs are copied server-side and frozen on the
  ///     product, so a later regeneration cannot change what is published.
  ///   • image-only REQUIRES [imageKey] — an already-uploaded object. The upload
  ///     therefore comes FIRST: [createImageSlot] with no product id, PUT the
  ///     bytes, then create with the key. A product with no image could never
  ///     publish, which is why it is refused up front rather than at publish.
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
    String? imageKey,
  });

  /// Patches editable fields, replaces the backing asset, or converts the type.
  ///
  /// A conversion must carry the asset its new type needs IN THE SAME call —
  /// [type] `threeD` with [sourceModelId], or [type] `imageOnly` with
  /// [imageKey]. That is what stops a one-word patch leaving a product typed for
  /// an asset it does not have; the server returns 400 otherwise.
  ///
  /// [categoryId] and [price] use a sentinel so that passing null explicitly
  /// means "move to Uncategorized" / "clear the price", distinct from omitting
  /// them. Both are nullable on the server schema, and both are things a user
  /// genuinely does: an unpriced product is a normal catalog entry, and a price
  /// that cannot be REMOVED once typed is a field with a one-way door in it.
  ///
  /// The sentinel defaults are declared HERE as well as on the implementation,
  /// and that is load-bearing: a call site resolves defaults from the STATIC
  /// type, which is this interface. Without them, `update(id, name: 'x')`
  /// through this type passes `categoryId: null` — an explicit "move to
  /// Uncategorized" nobody asked for, on every patch that does not mention the
  /// category.
  Future<CatalogProduct> update(
    String id, {
    String? name,
    String? description,
    Object? price = kCatalogUnchanged,
    Object? categoryId = kCatalogUnchanged,
    List<String>? tags,
    ProductAvailability? availability,
    bool? featured,
    ProductType? type,
    String? sourceModelId,
    String? imageKey,
  });

  /// Mints a presigned slot to upload a product image into.
  ///
  /// Omit [productId] when the product does not exist yet (the image-only create
  /// flow); pass it when replacing an existing product's image.
  Future<ProductImageSlot> createImageSlot({
    required ProductImageContentType contentType,
    String? productId,
  });

  /// Uploads image bytes in ONE call and returns the key they landed on. Feed
  /// that key to [create] (image-only) or [commitImage] (replace) exactly as if
  /// it had come from [createImageSlot].
  ///
  /// THIS is the path the app actually uses. The presigned three-step flow
  /// above cannot work in the BROWSER build — the PUT is cross-origin to the
  /// artifacts bucket, which serves no CORS policy — and the avatar feature hit
  /// the identical wall and resolved it the identical way. One path for web and
  /// native beats two that diverge, so [createImageSlot] is kept for native
  /// callers that want the bytes off our API but is not what the add-product
  /// screen calls.
  ///
  /// [contentType] must have been sniffed from the bytes themselves; the server
  /// sniffs them again and derives the stored type from ITS answer, so a
  /// mislabelled body cannot store a lie.
  Future<String> uploadImageBytes(
    Uint8List bytes, {
    required String contentType,
    String? productId,
  });

  /// Binds an uploaded object to a product (feature 16). Call it only after the
  /// PUT to the slot's url has succeeded — the server checks the object exists.
  Future<CatalogProduct> commitImage(String productId, String key);

  /// Duplicates a product (feature 18). The copy is auto-renamed unless [name]
  /// is given, because Mirage keys items by name within a restaurant.
  Future<CatalogProduct> duplicate(String id, {String? name});

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
    Object? categoryId = kCatalogUnchanged,
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
    String? imageKey,
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
            if (imageKey != null) 'imageKey': imageKey,
          },
        );
        return _productFrom(res.data);
      });

  @override
  Future<CatalogProduct> update(
    String id, {
    String? name,
    String? description,
    Object? price = kCatalogUnchanged,
    Object? categoryId = kCatalogUnchanged,
    List<String>? tags,
    ProductAvailability? availability,
    bool? featured,
    ProductType? type,
    String? sourceModelId,
    String? imageKey,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.patch<Map<String, dynamic>>(
          '/catalog/products/$id',
          data: {
            if (name != null) 'name': name,
            if (description != null) 'description': description,
            // Explicit null is meaningful for both of these — it CLEARS the
            // price and moves the product to Uncategorized — so the sentinel,
            // not null, is what marks "unchanged".
            if (!identical(price, kCatalogUnchanged)) 'price': price,
            if (!identical(categoryId, kCatalogUnchanged)) 'categoryId': categoryId,
            if (tags != null) 'tags': tags,
            if (availability != null) 'availability': availability.apiValue,
            if (featured != null) 'featured': featured,
            // `unknown` is this build's fallback for a value it does not
            // recognise; sending it would be a 400 on a strict enum.
            if (type != null && type != ProductType.unknown) 'type': type.apiValue,
            if (sourceModelId != null) 'sourceModelId': sourceModelId,
            if (imageKey != null) 'imageKey': imageKey,
          },
        );
        return _productFrom(res.data);
      });

  @override
  Future<ProductImageSlot> createImageSlot({
    required ProductImageContentType contentType,
    String? productId,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/catalog/products/image/upload-url',
          data: {
            'contentType': contentType.apiValue,
            if (productId != null) 'productId': productId,
          },
        );
        final body = res.data;
        if (body == null || body['key'] is! String || body['url'] is! String) {
          throw const CatalogFailure(
            code: 'MALFORMED_RESPONSE',
            message: 'Something went wrong. Please try again.',
          );
        }
        return ProductImageSlot.fromMap(body);
      });

  @override
  Future<String> uploadImageBytes(
    Uint8List bytes, {
    required String contentType,
    String? productId,
  }) =>
      mapCatalogErrors(() async {
        // The raw image IS the body — not multipart, not JSON. The app Dio is
        // right (unlike the direct-to-S3 PUT this replaces): the endpoint is
        // ours and needs the Bearer token.
        final res = await _dio.post<Map<String, dynamic>>(
          '/catalog/products/image/bytes',
          data: Stream.value(bytes),
          queryParameters: {if (productId != null) 'productId': productId},
          options: Options(
            headers: {
              Headers.contentTypeHeader: contentType,
              Headers.contentLengthHeader: bytes.length,
            },
          ),
        );

        final key = res.data?['key'];
        if (key is! String || key.isEmpty) {
          throw const CatalogFailure(
            code: 'MALFORMED_RESPONSE',
            message: 'Something went wrong. Please try again.',
          );
        }
        return key;
      });

  @override
  Future<CatalogProduct> commitImage(String productId, String key) =>
      mapCatalogErrors(() async {
        final res = await _dio.put<Map<String, dynamic>>(
          '/catalog/products/$productId/image',
          data: {'key': key},
        );
        return _productFrom(res.data);
      });

  @override
  Future<CatalogProduct> duplicate(String id, {String? name}) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/catalog/products/$id/duplicate',
          data: {if (name != null) 'name': name},
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
    Object? categoryId = kCatalogUnchanged,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/catalog/products/bulk',
          data: {
            'action': action.apiValue,
            'ids': ids,
            // SET_CATEGORY needs the key even when the value is null
            // (Uncategorized); every other action is rejected if it is present.
            if (!identical(categoryId, kCatalogUnchanged)) 'categoryId': categoryId,
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
///
/// PUBLIC, and it has to be: `price` and `categoryId` are nullable on the server
/// and null MEANS something (clear the price, move to Uncategorized), so every
/// layer that forwards one of them — notifier, editor — must be able to say
/// "unchanged" in the same word this file compares against. A second sentinel
/// somewhere up the stack would not be `identical` to this one, and would be
/// serialised into the request body as a bare Object.
const Object kCatalogUnchanged = Object();

/// Most product ids `POST /catalog/products/bulk` accepts in one call.
///
/// Mirrors the backend Zod bound exactly. A caller with more than this many —
/// emptying a large category, a select-all over a long list — must CHUNK, and
/// must know that a run of chunks can therefore fail halfway.
const int kBulkProductIdLimit = 200;

/// App-wide catalog products repository.
final catalogProductsRepositoryProvider = Provider<CatalogProductsRepository>(
  (ref) => RemoteCatalogProductsRepository(ref.watch(dioProvider)),
);
