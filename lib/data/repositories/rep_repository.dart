// lib/data/repositories/rep_repository.dart
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/business_profile.dart';
import '../../domain/entities/catalog.dart';
import '../../domain/entities/catalog_category.dart';
import '../../domain/entities/catalog_product.dart';
import '../../domain/entities/product_availability.dart';
import '../../domain/entities/product_food_type.dart';
import '../../domain/entities/product_type.dart';
import '../../domain/catalog/publish_request_result.dart';
import '../../domain/catalog/publish_status.dart';
import '../../application/catalog/qr_download_file.dart';
import '../../domain/entities/qr_code_preflight.dart';
import '../../domain/entities/qr_standee.dart';
import 'admin_standee_repository.dart' show StandeeQrFormat;
import 'bytes_response.dart';
import 'catalog_repository.dart'
    show
        BrandingSlot,
        BrandingSlotX,
        CatalogQrFormat,
        CatalogQrFormatX,
        CatalogQrImage;
import 'catalog_products_repository.dart'
    show
        BulkProductAction,
        BulkProductActionX,
        ProductImageSlot,
        kBulkProductIdLimit,
        kCatalogUnchanged;
import '../../domain/entities/rep_activation.dart';
import '../remote/api_client.dart';
import 'catalog_failure.dart';
import 'publish_request_mapping.dart';

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
  /// THE OWNER'S SHAPE, on purpose. Answers the same [PublishRequestResult]
  /// the owner's `CatalogRepository.publish` does — a 409 is the run the rep
  /// wanted ([PublishAlreadyRunning]), a 422 is the checklist
  /// ([PublishBlocked]), a name clash carries its suggestion — so the rep's
  /// publish screen and the owner's are one screen reading one result type,
  /// and a rep and an owner are told the same thing about the same catalog.
  ///
  /// [idempotencyKey] is the lost-202 guard the owner's route has: a second
  /// press with the same key is the same request, never a second run.
  Future<PublishRequestResult> publish(
    String catalogId, {
    String? idempotencyKey,
  });

  /// Re-runs only the FAILED rows — the owner's "Retry failed", delegated.
  Future<PublishRequestResult> retryFailedPublish(String catalogId);

  /// How the last publish went — the owner's `GET /catalog/publish/status`,
  /// answered for a catalog the rep holds.
  ///
  /// THE GAP THIS CLOSES. The rep screen learned that a run had ended from
  /// the catalog document alone, so a run that FAILED looked exactly like one
  /// that finished: the bar went back to "Draft changes not yet live" and
  /// said nothing about why. The rep pressed Publish again, waited another
  /// minute, and left with a dead standee. This is the same payload the owner
  /// reads, so a rep and an owner are told the same thing about the same run.
  Future<PublishStatus> publishStatus(String catalogId);

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
  ///
  /// [categoryId] files the dish on the way in. Null means Uncategorized, which
  /// is a real answer and not an omission — it is where a dish goes when the rep
  /// has not decided yet.
  Future<CatalogProduct> createProduct(
    String catalogId, {
    required ProductType type,
    required String name,
    String? description,
    double? price,
    String? sourceModelId,
    String? imageKey,
    String? categoryId,
    /// Omit for veg — the server default. Only an explicit choice is sent.
    ProductFoodType? foodType,
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

  /// The standees this rep has put live.
  ///
  /// A HISTORY, and the only rep list that only ever grows. Keyed server-side
  /// on who ACTIVATED each code, so losing access to a restaurant does not
  /// erase having signed it up.
  Future<RepPublishedPage> publishedStandees({int? days});

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

  /// The RESTAURANT's own QR code — the square a customer scans to open the
  /// menu, rendered from the delegated catalog's frozen `publicUrl`.
  ///
  /// NOT [standeeFile], and the two are easy to confuse. That one renders the
  /// printed standee artwork for a code in the rep's own stock, with the eight
  /// characters on it. This one renders the menu's code, for a restaurant that
  /// is already live, and is byte-identical to what the owner gets from
  /// `/catalog/qr` — the server delegates to the same renderer with the same
  /// URL, so a rep and an owner cannot print two different squares.
  ///
  /// Throws [CatalogFailure] with `CATALOG_NOT_PUBLISHED` before the first
  /// publish: a URL is minted at provisioning and never invented, because a QR
  /// that resolves to nothing might get printed.
  Future<CatalogQrImage> catalogQr(
    String catalogId, {
    CatalogQrFormat format,
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
  /// WRITABLE on this surface, and it has to be. `activate` seeds no categories
  /// at all, so a rep-signed restaurant starts with none — a read-only list here
  /// meant the dish editor's picker offered Uncategorized and nothing else on
  /// every restaurant a rep ever set up, and the public page rendered as one
  /// flat heap until the owner signed in and built the sections by hand.
  Future<CatalogCategoryList> categories(String catalogId);

  /// Creates a section. Throws [CatalogFailure] with `DUPLICATE_NAME` when the
  /// menu already has one by that name — the server's verdict, shown beside the
  /// field rather than guessed at from a local list that may be stale.
  Future<CatalogCategory> createCategory(String catalogId, String name);

  /// Renames one.
  Future<CatalogCategory> renameCategory(
    String catalogId,
    String categoryId,
    String name,
  );

  /// Deletes a section and returns how many dishes moved to Uncategorized.
  ///
  /// The count is the whole point of the return type: the rep is deleting a
  /// grouping on someone else's menu, and the confirmation must never let that
  /// look like it deleted the dishes inside it.
  Future<int> deleteCategory(String catalogId, String categoryId);

  /// Writes a new section order. Send the FULL ordered id list — the server
  /// answers a partial set with `ID_SET_MISMATCH` rather than guessing.
  Future<void> reorderCategories(String catalogId, List<String> orderedIds);

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
    ProductFoodType? foodType,
    String? imageKey,
  });

  /// Writes a new dish order on the restaurant's behalf.
  ///
  /// THE OWNER HAS HAD THIS SINCE FEATURE 10; THE REP DID NOT. Send the FULL
  /// ordered id list of what the screen holds — the server accepts a subset
  /// and renumbers it 0..n-1 among itself, and rejects any id that is not a
  /// live dish of this catalog with `ID_SET_MISMATCH`, wholesale, so a failure
  /// means nothing moved.
  Future<void> reorderProducts(String catalogId, List<String> orderedIds);

  /// Applies one action to many dishes and returns how many were affected.
  ///
  /// The owner's `bulk`, delegated: the rep's category manager moves dishes
  /// between sections, empties a section before deleting it, and adds picked
  /// dishes to one — all `SET_CATEGORY` over a list of ids, and one call rather
  /// than N patches. [categoryId] is required by
  /// [BulkProductAction.setCategory] (null = Uncategorized) and rejected for
  /// every other action. Chunk at [kBulkProductIdLimit].
  Future<int> bulkProducts(
    String catalogId, {
    required BulkProductAction action,
    required List<String> ids,
    Object? categoryId = kCatalogUnchanged,
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

  /// The menu cannot go live yet. Mapped to [PublishBlocked] — the gate list,
  /// never a flattened sentence — by [RepRepository.publish].
  static const publishBlocked = 'PUBLISH_BLOCKED';

  /// A publish is already running for this catalog. Mapped to
  /// [PublishAlreadyRunning] rather than thrown; see [RepRepository.publish].
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
    String? categoryId,
    ProductFoodType? foodType,
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
            // OMITTED when null rather than sent as null: the create schema
            // treats an absent categoryId as Uncategorized already, and sending
            // an explicit null would be a second way to say the same thing.
            if (categoryId != null) 'categoryId': categoryId,
            if (foodType != null) 'foodType': foodType.apiValue,
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
  Future<CatalogCategory> createCategory(String catalogId, String name) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/rep/catalogs/$catalogId/categories',
          data: {'name': name},
        );
        return _categoryFrom(res.data);
      });

  @override
  Future<CatalogCategory> renameCategory(
    String catalogId,
    String categoryId,
    String name,
  ) =>
      mapCatalogErrors(() async {
        final res = await _dio.patch<Map<String, dynamic>>(
          '/rep/catalogs/$catalogId/categories/$categoryId',
          data: {'name': name},
        );
        return _categoryFrom(res.data);
      });

  @override
  Future<int> deleteCategory(String catalogId, String categoryId) =>
      mapCatalogErrors(() async {
        final res = await _dio.delete<Map<String, dynamic>>(
          '/rep/catalogs/$catalogId/categories/$categoryId',
        );
        final moved = res.data?['movedProductCount'];
        return moved is num && moved >= 0 ? moved.toInt() : 0;
      });

  @override
  Future<void> reorderCategories(String catalogId, List<String> orderedIds) =>
      mapCatalogErrors(() async {
        await _dio.post<Map<String, dynamic>>(
          '/rep/catalogs/$catalogId/categories/reorder',
          data: {'ids': orderedIds},
        );
      });

  @override
  Future<void> reorderProducts(String catalogId, List<String> orderedIds) =>
      mapCatalogErrors(() async {
        await _dio.post<Map<String, dynamic>>(
          '/rep/catalogs/$catalogId/products/reorder',
          data: {'ids': orderedIds},
        );
      });

  @override
  Future<int> bulkProducts(
    String catalogId, {
    required BulkProductAction action,
    required List<String> ids,
    Object? categoryId = kCatalogUnchanged,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/rep/catalogs/$catalogId/products/bulk',
          data: {
            'action': action.apiValue,
            'ids': ids,
            // SET_CATEGORY needs the key even when the value is null
            // (Uncategorized); every other action is rejected if it is present.
            if (!identical(categoryId, kCatalogUnchanged))
              'categoryId': categoryId,
          },
        );
        final affected = res.data?['affected'];
        return affected is num && affected >= 0 ? affected.toInt() : 0;
      });

  CatalogCategory _categoryFrom(Map<String, dynamic>? body) {
    final category = body?['category'];
    if (category is! Map<String, dynamic>) throw _malformed;
    return CatalogCategory.fromMap(category);
  }

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
    ProductFoodType? foodType,
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
            if (foodType != null) 'foodType': foodType.apiValue,
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
  Future<RepPublishedPage> publishedStandees({int? days}) =>
      mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/rep/published',
          queryParameters: {if (days != null) 'days': days},
        );
        final raw = res.data?['standees'];
        return RepPublishedPage(
          standees: raw is List
              ? raw
                  .whereType<Map<String, dynamic>>()
                  .map(RepPublishedStandee.fromMap)
                  .toList(growable: false)
              : const <RepPublishedStandee>[],
          total: (res.data?['total'] as num?)?.toInt() ?? 0,
        );
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
  Future<CatalogQrImage> catalogQr(
    String catalogId, {
    CatalogQrFormat format = CatalogQrFormat.png,
    int? size,
  }) async {
    // NOT mapCatalogErrors, for the reason documented on [standeeFile] above:
    // `responseType: bytes` applies to FAILURES too, so without withDecodedBody
    // the 409 CATALOG_NOT_PUBLISHED this endpoint answers before the first
    // publish arrives as an undecodable byte array and collapses into a generic
    // sentence — losing the one code the screen renders its whole empty state
    // from.
    try {
      final res = await _dio.get<List<int>>(
        '/rep/catalogs/$catalogId/qr',
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

      return CatalogQrImage(
        bytes: Uint8List.fromList(data),
        contentType: res.headers.value(Headers.contentTypeHeader) ??
            (format == CatalogQrFormat.png ? 'image/png' : 'application/pdf'),
        // The server's own filename, so a saved file is named after the
        // restaurant rather than after whatever the client would have guessed.
        fileName:
            fileNameFromDisposition(res.headers.value('content-disposition')) ??
                'catalog-qr.${format.apiValue}',
        format: format,
      );
    } on DioException catch (error) {
      throw CatalogFailure.fromDio(withDecodedBody(error));
    }
  }

  @override
  Future<PublishRequestResult> publish(
    String catalogId, {
    String? idempotencyKey,
  }) =>
      postPublishRequest(
        _dio,
        '/rep/catalogs/$catalogId/publish',
        idempotencyKey: idempotencyKey,
      );

  @override
  Future<PublishRequestResult> retryFailedPublish(String catalogId) =>
      postPublishRequest(_dio, '/rep/catalogs/$catalogId/publish/retry');

  @override
  Future<PublishStatus> publishStatus(String catalogId) =>
      getPublishStatus(_dio, '/rep/catalogs/$catalogId/publish/status');
}

/// The `/rep` data source. Overridden with a fake in tests.
final repRepositoryProvider = Provider<RepRepository>(
  (ref) => RemoteRepRepository(ref.watch(dioProvider)),
);
