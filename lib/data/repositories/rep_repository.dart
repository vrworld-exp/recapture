// lib/data/repositories/rep_repository.dart
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/catalog_product.dart';
import '../../domain/entities/product_type.dart';
import '../../domain/entities/qr_code_preflight.dart';
import 'catalog_products_repository.dart' show ProductImageSlot;
import '../../domain/entities/rep_activation.dart';
import '../remote/api_client.dart';
import 'catalog_failure.dart';

/// Data access for `/rep` — the acting-on-behalf-of surface.
///
/// Mirrors [CatalogProductsRepository] exactly, including the error boundary:
/// every method throws [CatalogFailure], never a [DioException], so notifiers
/// and screens never touch Dio. The failure carries the envelope's `code`, and
/// the screens read THAT — never the message — so no backend sentence, proxy
/// HTML or upstream 502 body can reach a rep standing in a restaurant.
abstract interface class RepRepository {
  /// Is this standee usable? One request, before the rep types anything else.
  ///
  /// Throws [CatalogFailure] with [RepErrorCodes.codeNotFound] for a code that
  /// is not ours.
  Future<QrCodePreflight> preflight(String code);

  /// Turns a standee into a live catalog owned by the restaurant.
  ///
  /// A `409` becomes [RepErrorCodes.codeUnavailable] — a TYPED failure, so the
  /// screen can offer "scan another" rather than showing a generic error and
  /// leaving the rep to guess.
  Future<RepActivation> activate(RepActivationRequest request);

  /// The catalogs this rep may currently act on.
  Future<List<RepCatalogSummary>> catalogs();

  /// One delegated catalog's dishes.
  Future<List<CatalogProduct>> products(String catalogId);

  /// Attaches a replacement standee to a catalog the rep holds.
  ///
  /// The catalog's public URL does NOT move — that is the whole point of the
  /// resolver — so nothing here returns a new one to show.
  /// Authors one dish on the restaurant's behalf.
  ///
  /// THE OWNERSHIP HERE IS THE WHOLE TRICK, and it is worth knowing about from
  /// the client side too. A 3D dish carries [sourceModelId] — a model from a
  /// capture the REP shot, so the Project belongs to the rep while the catalog
  /// belongs to the restaurant. `/rep/catalogs/:id/products` widens model
  /// ownership by exactly the calling rep to let those meet; the product that
  /// comes back is owned by the restaurant and identical to one the owner would
  /// have made.
  ///
  /// An image-only dish carries [imageKey] instead, and the upload therefore
  /// comes FIRST — [uploadImageBytes] or [createImageSlot], then this.
  Future<CatalogProduct> createProduct(
    String catalogId, {
    required ProductType type,
    required String name,
    String? description,
    double? price,
    String? sourceModelId,
    String? imageKey,
  });

  /// Uploads an image through the API and returns its committed key.
  ///
  /// The ONE upload path that works on every target. The presigned alternative
  /// ([createImageSlot]) needs a cross-origin PUT to a bucket that serves no
  /// CORS policy, so the browser build cannot use it — see
  /// `catalog_products_repository.dart` for the same split on the owner side.
  Future<String> uploadImageBytes(
    String catalogId,
    Uint8List bytes, {
    required String contentType,
  });

  /// Mints a presigned PUT slot. NATIVE ONLY — kept because it keeps image
  /// bytes off our API where the platform allows it.
  Future<ProductImageSlot> createImageSlot(
    String catalogId, {
    required String contentType,
  });

  Future<void> attachCode(String catalogId, String code);

  /// Takes one standee out of service.
  Future<void> retireCode(String code);
}

/// Envelope codes the `/rep` endpoints return that a screen branches on.
///
/// Only the ones with a distinct thing to SAY are named; anything else keeps
/// its raw code on [CatalogFailure.code] and falls through to the generic copy.
/// Same rule as [CatalogErrorCodes] — a decidable switch, not a mirror of the
/// backend that goes stale.
abstract final class RepErrorCodes {
  /// The code is not one of ours — a typo, or a sticker from somewhere else.
  static const codeNotFound = 'CODE_NOT_FOUND';

  /// Already activated on another restaurant, or retired. The rep needs a
  /// different standee; nothing they typed was wrong.
  static const codeUnavailable = 'CODE_UNAVAILABLE';

  /// Repointing a code away from a restaurant that has already published would
  /// leave that restaurant's printed URL resolving to nothing.
  static const sourceCatalogPublished = 'SOURCE_CATALOG_PUBLISHED';

  /// The deployment has no public resolver host, so an activation now would
  /// freeze a broken URL onto the catalog forever. An operator problem.
  static const resolverNotConfigured = 'RESOLVER_NOT_CONFIGURED';

  /// Too many activations from this rep in the window.
  static const rateLimited = 'RATE_LIMITED';

  /// The catalog is not delegated to this rep — indistinguishable from one that
  /// does not exist, by design on the server side.
  static const catalogNotFound = 'CATALOG_NOT_FOUND';
}

/// Whether a failure means "this standee cannot be used, try another".
extension RepFailureX on CatalogFailure {
  bool get isCodeUnavailable => code == RepErrorCodes.codeUnavailable;
  bool get isCodeNotFound => code == RepErrorCodes.codeNotFound;
  bool get isRateLimited => code == RepErrorCodes.rateLimited;
  bool get isSourceCatalogPublished =>
      code == RepErrorCodes.sourceCatalogPublished;
}

class RemoteRepRepository implements RepRepository {
  const RemoteRepRepository(this._dio);

  final Dio _dio;

  @override
  Future<QrCodePreflight> preflight(String code) => mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>('/rep/codes/$code');
        return QrCodePreflight.fromMap(res.data ?? const {});
      });

  @override
  Future<RepActivation> activate(RepActivationRequest request) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/rep/activations',
          data: request.toJson(),
        );
        return RepActivation.fromMap(res.data ?? const {});
      });

  @override
  Future<List<RepCatalogSummary>> catalogs() => mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>('/rep/catalogs');
        final raw = res.data?['catalogs'];
        if (raw is! List) return const <RepCatalogSummary>[];
        return [
          for (final item in raw)
            if (item is Map<String, dynamic>) RepCatalogSummary.fromMap(item),
        ];
      });

  @override
  Future<List<CatalogProduct>> products(String catalogId) =>
      mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/rep/catalogs/$catalogId/products',
        );
        final raw = res.data?['items'];
        if (raw is! List) return const <CatalogProduct>[];
        return [
          for (final item in raw)
            if (item is Map<String, dynamic>) CatalogProduct.fromMap(item),
        ];
      });

  @override
  Future<CatalogProduct> createProduct(
    String catalogId, {
    required ProductType type,
    required String name,
    String? description,
    double? price,
    String? sourceModelId,
    String? imageKey,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/rep/catalogs/$catalogId/products',
          data: {
            'type': type.apiValue,
            'name': name,
            if (description != null) 'description': description,
            if (price != null) 'price': price,
            if (sourceModelId != null) 'sourceModelId': sourceModelId,
            if (imageKey != null) 'imageKey': imageKey,
          },
        );
        final product = res.data?['product'];
        if (product is! Map<String, dynamic>) {
          throw const CatalogFailure(
            code: 'MALFORMED_RESPONSE',
            message: 'Something went wrong. Please try again.',
          );
        }
        return CatalogProduct.fromMap(product);
      });

  @override
  Future<String> uploadImageBytes(
    String catalogId,
    Uint8List bytes, {
    required String contentType,
  }) =>
      mapCatalogErrors(() async {
        // The raw image IS the body — not multipart, not JSON. The app Dio is
        // right: the endpoint is ours and needs the Bearer token.
        final res = await _dio.post<Map<String, dynamic>>(
          '/rep/catalogs/$catalogId/products/image/bytes',
          data: Stream.value(bytes),
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
  Future<ProductImageSlot> createImageSlot(
    String catalogId, {
    required String contentType,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/rep/catalogs/$catalogId/products/image/upload-url',
          data: {'contentType': contentType},
        );
        final slot = res.data?['slot'];
        if (slot is! Map<String, dynamic>) {
          throw const CatalogFailure(
            code: 'MALFORMED_RESPONSE',
            message: 'Something went wrong. Please try again.',
          );
        }
        return ProductImageSlot.fromMap(slot);
      });

  @override
  Future<void> attachCode(String catalogId, String code) =>
      mapCatalogErrors(() async {
        await _dio.post<Map<String, dynamic>>(
          '/rep/catalogs/$catalogId/qr-codes',
          data: {'code': code},
        );
      });

  @override
  Future<void> retireCode(String code) => mapCatalogErrors(() async {
        await _dio.post<Map<String, dynamic>>('/rep/qr-codes/$code/retire');
      });
}

/// The `/rep` data source. Overridden with a fake in tests.
final repRepositoryProvider = Provider<RepRepository>(
  (ref) => RemoteRepRepository(ref.watch(dioProvider)),
);
