// lib/data/repositories/rep_repository.dart
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/business_profile.dart';
import '../../domain/entities/catalog.dart';
import '../../domain/entities/catalog_category.dart';
import '../../domain/entities/catalog_product.dart';
import '../../domain/entities/product_availability.dart';
import '../../domain/entities/product_type.dart';
import '../../domain/catalog/publish_gate.dart';
import '../../application/catalog/qr_download_file.dart';
import '../../domain/entities/qr_code_preflight.dart';
import '../../domain/entities/qr_standee.dart';
import 'admin_standee_repository.dart' show StandeeQrFormat;
import 'bytes_response.dart';
import 'catalog_repository.dart' show BrandingSlot, BrandingSlotX;
import 'catalog_products_repository.dart'
    show ProductImageSlot, kCatalogUnchanged;
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

  /// Puts the restaurant's menu online, on their behalf.
  ///
  /// THE ONE ACTION THAT MAKES THE STANDEE WORK. Activating binds a code; it
  /// does not publish. Before this existed, a restaurant whose dishes were all
  /// photo-only had nothing that would ever publish it — no model to finish, no
  /// owner in the room — and the standee stayed dead after the rep left.
  ///
  /// A publish already running is a SUCCESS ([RepPublishOutcome.alreadyRunning]),
  /// not a failure: a rep who taps twice, or taps while a finished 3D dish is
  /// already publishing, is in the state they were asking for.
  ///
  /// Throws [RepPublishBlocked] — carrying every failing gate, not the first —
  /// when the catalog is not ready.
  Future<RepPublishResult> publish(String catalogId);

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
  ///
  /// [productId] groups the stored object under the dish it belongs to, exactly
  /// as the owner repository does. Omit it while AUTHORING — the dish does not
  /// exist yet, so there is nothing to group under — and pass it when REPLACING
  /// an existing dish's photo, so the sweep that cleans up after a delete can
  /// find the object from the product alone.
  Future<String> uploadImageBytes(
    String catalogId,
    Uint8List bytes, {
    required String contentType,
    String? productId,
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

  /// The stock this rep is carrying — every standee an admin handed them.
  ///
  /// Usable codes first (see the backend's ordering), so the top of the list is
  /// what can go on a table right now.
  Future<List<RepStandee>> standees();

  /// The printable sheet for one of THIS rep's standees.
  ///
  /// A code the rep does not hold answers [RepErrorCodes.codeNotFound] —
  /// identical to a code that does not exist, so the endpoint cannot be used to
  /// discover what has been minted.
  Future<QrDownloadFile> standeeFile(
    String code, {
    StandeeQrFormat format,
    int? size,
  });

  // ── The restaurant behind the dishes ──────────────────────────────────────
  //
  // Everything below reads or writes the CATALOG DOCUMENT rather than a product
  // on it. All of it is delegated: the server resolves the same
  // `resolveDelegatedCatalog` gate the product routes use and then hands the
  // work to the owner service with the RESTAURANT's userId, so a rep's edit is
  // byte-identical to the owner's own.

  /// The catalog document itself — counts, slug, draft revision.
  ///
  /// Not the same thing as the row in [catalogs]: that is a picker line (name,
  /// status) sized for a list, this is what the preview and the details screens
  /// need. Both exist so neither has to carry the other's weight.
  Future<Catalog> catalog(String catalogId);

  /// The restaurant's sections, in their set order.
  ///
  /// READ-ONLY on this surface by design — a rep previews and files dishes into
  /// the sections the owner made, and never reshapes the page itself.
  Future<CatalogCategoryList> categories(String catalogId);

  /// The restaurant's business profile: name, contact block, branding urls.
  Future<BusinessProfile> profile(String catalogId);

  /// Edits it.
  ///
  /// [contact] REPLACES the whole contact block — the server's own semantics, so
  /// callers pass the FULL block built from every field, never a delta. That is
  /// also what makes "clear the website" expressible at all.
  Future<BusinessProfile> updateProfile(
    String catalogId, {
    String? name,
    String? businessName,
    BusinessContact? contact,
  });

  /// Uploads a logo or cover through the API and returns its committed key.
  ///
  /// The ONE upload path that works on every target, for the reason
  /// [uploadImageBytes] documents: the presigned alternative needs a
  /// cross-origin PUT to a bucket that serves no CORS policy.
  Future<String> uploadBrandingBytes(
    String catalogId,
    Uint8List bytes, {
    required BrandingSlot slot,
    required String contentType,
  });

  /// Binds an uploaded object as the logo or cover, and answers the updated
  /// profile.
  ///
  /// SEPARATE from the upload so a commit that fails after the bytes have landed
  /// can be retried on its own — a rep on restaurant wifi must not be made to
  /// send the same logo twice.
  Future<BusinessProfile> commitBranding(
    String catalogId, {
    required BrandingSlot slot,
    required String key,
  });

  /// ONE dish, by id.
  ///
  /// The dish editor is reached from a list that already holds the product, so
  /// this is not how it usually gets one — it is how the screen survives a
  /// BROWSER RELOAD, where the two ids in the URL are all that is left.
  Future<CatalogProduct> product(String catalogId, String productId);

  /// Edits a dish on the restaurant's behalf.
  ///
  /// [price] and [categoryId] take the same sentinel semantics the owner
  /// repository uses: pass null to CLEAR (no price / Uncategorized), omit to
  /// leave alone. Nothing else can tell "clear this" from "I did not touch it",
  /// and both are ordinary things a rep does at a table.
  ///
  /// `sourceModelId` is deliberately absent. Re-pointing a dish at a different
  /// capture cannot succeed through the delegated route — see the note on
  /// `PATCH /rep/catalogs/:id/products/:productId` — so the method does not
  /// offer an argument the server would answer 404 to.
  Future<CatalogProduct> updateProduct(
    String catalogId,
    String productId, {
    String? name,
    String? description,
    Object? price = kCatalogUnchanged,
    Object? categoryId = kCatalogUnchanged,
    ProductAvailability? availability,
    String? imageKey,
  });
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

  /// The menu cannot go live yet. Carries a gate list — see [RepPublishBlocked].
  static const publishBlocked = 'PUBLISH_BLOCKED';

  /// A publish is already running for this catalog. Handled as an OUTCOME
  /// rather than an error; see [RepRepository.publish].
  static const publishInProgress = 'PUBLISH_IN_PROGRESS';
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
    String? productId,
  }) =>
      mapCatalogErrors(() async {
        // The raw image IS the body — not multipart, not JSON. The app Dio is
        // right: the endpoint is ours and needs the Bearer token.
        final res = await _dio.post<Map<String, dynamic>>(
          '/rep/catalogs/$catalogId/products/image/bytes',
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
  Future<Catalog> catalog(String catalogId) => mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/rep/catalogs/$catalogId',
        );
        final catalog = res.data?['catalog'];
        if (catalog is! Map<String, dynamic>) throw _malformed;
        return Catalog.fromMap(catalog);
      });

  @override
  Future<CatalogCategoryList> categories(String catalogId) =>
      mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/rep/catalogs/$catalogId/categories',
        );
        final raw = res.data?['categories'];
        return CatalogCategoryList(
          categories: [
            if (raw is List)
              for (final item in raw)
                if (item is Map<String, dynamic>) CatalogCategory.fromMap(item),
          ],
          uncategorizedCount: switch (res.data?['uncategorizedCount']) {
            final num n when n >= 0 => n.toInt(),
            _ => 0,
          },
        );
      });

  @override
  Future<BusinessProfile> profile(String catalogId) =>
      mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/rep/catalogs/$catalogId/profile',
        );
        return _profileFrom(res.data);
      });

  @override
  Future<BusinessProfile> updateProfile(
    String catalogId, {
    String? name,
    String? businessName,
    BusinessContact? contact,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.patch<Map<String, dynamic>>(
          '/rep/catalogs/$catalogId/profile',
          data: {
            // The schema is `.strict()` and refuses an empty patch, so an
            // omitted field must be an absent KEY rather than a null.
            if (name != null) 'name': name,
            if (businessName != null) 'businessName': businessName,
            if (contact != null) 'contact': contact.toMap(),
          },
        );
        return _profileFrom(res.data);
      });

  @override
  Future<String> uploadBrandingBytes(
    String catalogId,
    Uint8List bytes, {
    required BrandingSlot slot,
    required String contentType,
  }) =>
      mapCatalogErrors(() async {
        // The raw image IS the body — not multipart, not JSON. The app Dio is
        // right: the endpoint is ours and needs the Bearer token.
        final res = await _dio.post<Map<String, dynamic>>(
          '/rep/catalogs/$catalogId/logo/bytes',
          data: Stream.value(bytes),
          queryParameters: {'slot': slot.apiValue},
          options: Options(
            headers: {
              Headers.contentTypeHeader: contentType,
              Headers.contentLengthHeader: bytes.length,
            },
          ),
        );
        final key = res.data?['key'];
        if (key is! String || key.isEmpty) throw _malformed;
        return key;
      });

  @override
  Future<BusinessProfile> commitBranding(
    String catalogId, {
    required BrandingSlot slot,
    required String key,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.put<Map<String, dynamic>>(
          '/rep/catalogs/$catalogId/logo',
          data: {'slot': slot.apiValue, 'key': key},
        );
        return _profileFrom(res.data);
      });

  @override
  Future<CatalogProduct> product(String catalogId, String productId) =>
      mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/rep/catalogs/$catalogId/products/$productId',
        );
        return _productFrom(res.data);
      });

  @override
  Future<CatalogProduct> updateProduct(
    String catalogId,
    String productId, {
    String? name,
    String? description,
    Object? price = kCatalogUnchanged,
    Object? categoryId = kCatalogUnchanged,
    ProductAvailability? availability,
    String? imageKey,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.patch<Map<String, dynamic>>(
          '/rep/catalogs/$catalogId/products/$productId',
          data: {
            if (name != null) 'name': name,
            if (description != null) 'description': description,
            // An explicit null is MEANINGFUL for both of these — it clears the
            // price and moves the dish to Uncategorized — so the sentinel, not
            // null, is what means "untouched".
            if (!identical(price, kCatalogUnchanged)) 'price': price,
            if (!identical(categoryId, kCatalogUnchanged))
              'categoryId': categoryId,
            if (availability != null) 'availability': availability.apiValue,
            if (imageKey != null) 'imageKey': imageKey,
          },
        );
        return _productFrom(res.data);
      });

  BusinessProfile _profileFrom(Map<String, dynamic>? body) {
    final profile = body?['profile'];
    if (profile is! Map<String, dynamic>) throw _malformed;
    return BusinessProfile.fromMap(profile);
  }

  CatalogProduct _productFrom(Map<String, dynamic>? body) {
    final product = body?['product'];
    if (product is! Map<String, dynamic>) throw _malformed;
    return CatalogProduct.fromMap(product);
  }

  /// The one failure for a 2xx whose body is not the shape we asked for. Its
  /// code is deliberately not a `RepErrorCodes` value: nothing branches on it,
  /// and the screens fall through to their generic sentence.
  static const _malformed = CatalogFailure(
    code: 'MALFORMED_RESPONSE',
    message: 'Something went wrong. Please try again.',
  );

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

  @override
  Future<List<RepStandee>> standees() => mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>('/rep/standees');
        final raw = res.data?['standees'];
        if (raw is! List) return const <RepStandee>[];
        return raw
            .whereType<Map<String, dynamic>>()
            .map(RepStandee.fromMap)
            .toList(growable: false);
      });

  @override
  Future<QrDownloadFile> standeeFile(
    String code, {
    StandeeQrFormat format = StandeeQrFormat.pdf,
    int? size,
  }) async {
    // NOT mapCatalogErrors, and the reason is the same one documented on
    // RemoteAdminStandeeRepository._bytes: `responseType: bytes` applies to
    // FAILURES too, so without withDecodedBody a 409 CODE_RETIRED arrives as an
    // undecodable byte array and collapses into a generic sentence.
    try {
      final res = await _dio.get<List<int>>(
        '/rep/standees/$code/qr',
        queryParameters: {
          'format': format.apiValue,
          if (size != null) 'size': size,
        },
        options: Options(responseType: ResponseType.bytes),
      );

      final data = res.data;
      if (data == null || data.isEmpty) {
        throw const CatalogFailure(
          code: 'MALFORMED_RESPONSE',
          message: 'Something went wrong. Please try again.',
        );
      }

      return QrDownloadFile(
        bytes: Uint8List.fromList(data),
        fileName:
            fileNameFromDisposition(res.headers.value('content-disposition')) ??
                'standee-$code.${format.apiValue}',
        mimeType: res.headers.value(Headers.contentTypeHeader) ??
            (format == StandeeQrFormat.png ? 'image/png' : 'application/pdf'),
      );
    } on DioException catch (error) {
      throw CatalogFailure.fromDio(withDecodedBody(error));
    }
  }

  @override
  Future<RepPublishResult> publish(String catalogId) async {
    // NOT mapCatalogErrors: two of this endpoint's non-2xx answers are not
    // failures to report. A 409 PUBLISH_IN_PROGRESS is the outcome the rep
    // wanted, and a 422 PUBLISH_BLOCKED carries a gate list that
    // CatalogFailure.fromDio would flatten to a single sentence — losing the
    // checklist that tells the rep what to fix before leaving the table.
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/rep/catalogs/$catalogId/publish',
      );
      final body = res.data;
      return RepPublishResult(
        outcome: RepPublishOutcome.queued,
        runId: body?['runId'] as String?,
        publicUrl: body?['publicUrl'] as String?,
      );
    } on DioException catch (error) {
      final data = error.response?.data;
      final code = data is Map<String, dynamic> ? data['code'] : null;

      if (code == RepErrorCodes.publishInProgress) {
        return RepPublishResult(
          outcome: RepPublishOutcome.alreadyRunning,
          runId: (data as Map<String, dynamic>)['runId'] as String?,
        );
      }

      if (code == RepErrorCodes.publishBlocked) {
        final raw = (data as Map<String, dynamic>)['gates'];
        throw RepPublishBlocked(
          raw is List
              ? raw
                  .whereType<Map<String, dynamic>>()
                  .map(PublishGate.fromMap)
                  .toList(growable: false)
              : const <PublishGate>[],
        );
      }

      throw CatalogFailure.fromDio(error);
    }
  }
}

/// How a rep-initiated publish ended, when it did not throw.
enum RepPublishOutcome {
  /// A run was enqueued. The menu goes live when it finishes.
  queued,

  /// One was already running — the state the rep wanted, reached by someone
  /// else (usually a 3D dish that finished generating a moment earlier).
  alreadyRunning,
}

class RepPublishResult {
  const RepPublishResult({required this.outcome, this.runId, this.publicUrl});

  final RepPublishOutcome outcome;
  final String? runId;

  /// Present only on the FIRST publish, which is when provisioning mints it.
  final String? publicUrl;
}

/// The catalog is not ready, and here is everything that is wrong with it.
///
/// A [CatalogFailure] so a screen that only knows how to show failures still
/// shows something useful, and a subclass so the one screen that can render a
/// checklist gets [gates] instead of a flattened sentence.
class RepPublishBlocked extends CatalogFailure {
  const RepPublishBlocked(this.gates)
      : super(
          code: RepErrorCodes.publishBlocked,
          message: 'This menu is not ready to publish yet.',
          statusCode: 422,
        );

  /// EVERY failing gate, not the first — fixing one problem per round trip is
  /// three trips and three disappointments while a rep stands at a table.
  final List<PublishGate> gates;
}

/// The `/rep` data source. Overridden with a fake in tests.
final repRepositoryProvider = Provider<RepRepository>(
  (ref) => RemoteRepRepository(ref.watch(dioProvider)),
);
