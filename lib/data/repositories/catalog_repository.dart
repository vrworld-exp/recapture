// lib/data/repositories/catalog_repository.dart
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/catalog/publish_gate.dart';
import '../../domain/catalog/publish_request_result.dart';
import '../../domain/catalog/publish_status.dart';
import '../../domain/entities/business_profile.dart';
import '../../domain/entities/catalog.dart';
import '../../domain/entities/catalog_analytics.dart';
import '../../domain/entities/catalog_category.dart';
import '../../domain/entities/catalog_json.dart';
import '../remote/api_client.dart';
import 'catalog_failure.dart';
import 'catalog_products_repository.dart';

/// Which branding image a slot is for.
///
/// Both live in the SAME key space as product images and differ only in the
/// reserved slot name they occupy, so the client sends the name rather than
/// hitting two near-identical endpoints.
///
/// ⚠ Only the logo reaches customers — it becomes the Mirage restaurant icon at
/// publish. The cover has no Mirage counterpart at all. Read that from
/// [BusinessProfile.publicFields] rather than restating it in the UI.
enum BrandingSlot { logo, cover }

extension BrandingSlotX on BrandingSlot {
  String get apiValue => switch (this) {
        BrandingSlot.logo => 'logo',
        BrandingSlot.cover => 'cover',
      };
}

/// Data access for the catalog root and its categories.
///
/// Categories live here rather than in their own repository because they are not
/// independently addressable — there is exactly one catalog per account, and a
/// category has no meaning outside it. Products are big enough to justify their
/// own file ([CatalogProductsRepository]); categories are not.
///
/// Every method throws [CatalogFailure] on failure — never a [DioException].
abstract interface class CatalogRepository {
  /// The caller's catalog, or **null when they have none yet**.
  ///
  /// The server answers 404 CATALOG_NOT_FOUND for that state, and this is the
  /// one place it is translated into a value: "you have no catalog" is the
  /// first-run flow, not an error the UI should show.
  Future<Catalog?> fetch();

  /// Creates the caller's catalog. Idempotent server-side — a second call
  /// returns the existing catalog rather than erroring, so a retry after a lost
  /// response is safe.
  Future<Catalog> create({required String name, String? businessName});

  /// Updates catalog metadata. Bumps the draft revision server-side, so the
  /// returned catalog already carries the refreshed `hasUnpublishedChanges`.
  ///
  /// [contact] REPLACES the whole contact block when supplied — pass the full
  /// block, not a delta (that is also what makes clearing one field possible).
  Future<Catalog> update({
    String? name,
    String? businessName,
    BusinessContact? contact,
  });

  /// Deletes the catalog and everything under it, so the user can build a new
  /// one from scratch.
  ///
  /// ⚠ NOT the inverse of [CatalogRepository.publish] — that is `unpublish`,
  /// which keeps the restaurant, the URL and every printed QR alive. This gives
  /// all three up: the public page is torn down with the catalog, and the next
  /// catalog gets a NEW link. Anything already printed stops resolving.
  ///
  /// Refuses with `PUBLISH_IN_PROGRESS` while a run holds the catalog, and with
  /// `MIRAGE_UNAVAILABLE` when the public page could not be taken down — in
  /// which case NOTHING was deleted and retrying is the fix.
  Future<CatalogDeletionSummary> delete();

  /// Mints a presigned slot to upload the logo or cover image into (feature 2).
  Future<ProductImageSlot> createBrandingSlot({
    required BrandingSlot slot,
    required ProductImageContentType contentType,
  });

  /// Uploads branding bytes in ONE call and returns the key they landed on.
  /// Feed that key to [commitBranding] exactly as if it had come from
  /// [createBrandingSlot].
  ///
  /// THIS is the path the profile screen actually uses, for the same reason
  /// [CatalogProductsRepository.uploadImageBytes] is the path the add-product
  /// screen uses: the presigned PUT above is cross-origin to the artifacts
  /// bucket, which serves no CORS policy, so it cannot work in the BROWSER
  /// build. One path for web and native beats two that diverge.
  ///
  /// [contentType] must have been sniffed from the bytes themselves; the server
  /// sniffs them again and derives the stored type from ITS answer.
  Future<String> uploadBrandingBytes(
    Uint8List bytes, {
    required BrandingSlot slot,
    required String contentType,
  });

  /// Binds an uploaded object as the logo or cover, and returns the refreshed
  /// profile. Call it only after the bytes have landed — via
  /// [uploadBrandingBytes], or a PUT to a [createBrandingSlot] url.
  ///
  /// SEPARATE from the upload on purpose: a commit that fails after a
  /// successful upload must be retryable WITHOUT re-uploading the image.
  Future<BusinessProfile> commitBranding({
    required BrandingSlot slot,
    required String key,
  });

  /// The catalog's categories plus the uncategorized bucket's size.
  Future<CatalogCategoryList> listCategories();

  Future<CatalogCategory> createCategory(String name);

  Future<CatalogCategory> renameCategory(String id, String name);

  /// Deletes a category and returns how many products moved to Uncategorized —
  /// the confirmation copy needs that number, because deleting a grouping must
  /// never look like it deleted the products inside it.
  Future<int> deleteCategory(String id);

  /// Writes a new category order. Send the FULL ordered id list: the server
  /// rejects a partial set with ID_SET_MISMATCH rather than guessing.
  Future<void> reorderCategories(List<String> orderedIds);

  // ── Publish (features 31-39, 52, 53, 68, 69) ──────────────────────────────
  //
  // All five live on this ONE seam. Publishing is a property of the CATALOG,
  // not of its products: a run provisions the restaurant, syncs the categories,
  // then the products, then the deletes, and the QR is minted by the same act.
  // Splitting them across repositories would put four callers in charge of a
  // single state machine that only the server owns.

  /// Asks for a full publish (feature 36).
  ///
  /// Answers a [PublishRequestResult] rather than throwing for the expected
  /// refusals — a run already in flight, a blocked gate set, a name Mirage has
  /// taken. See that file for why each is a value and not an error.
  ///
  /// [idempotencyKey] rides the `Idempotency-Key` header: a retry after a lost
  /// 202 must not start a SECOND run against a catalog the first one is already
  /// holding.
  Future<PublishRequestResult> publish({String? idempotencyKey});

  /// Re-runs ONLY the rows whose sync status is FAILED (feature 53), so a user
  /// tapping Retry after "8 of 10 published" re-attempts two products, not ten.
  Future<PublishRequestResult> retryFailedPublish();

  /// The whole publish picture (features 37, 38, 52). Server truth — poll this,
  /// never derive progress locally.
  Future<PublishStatus> publishStatus();

  /// Takes the published ITEMS offline (feature 39).
  ///
  /// The Mirage restaurant, the public URL and every printed QR survive
  /// deliberately: republishing restores the same page at the same link, which
  /// is why the confirmation copy can promise a printed sticker keeps working.
  Future<UnpublishResult> unpublish();

  /// The catalog's QR code as bytes (features 31-35).
  ///
  /// BYTES, not a URL, and one method for both platforms. The endpoint needs
  /// the Bearer token, so a browser cannot simply navigate an anchor at it the
  /// way the preview-gallery download does with a presigned S3 link — and a
  /// second, url-shaped path for web would be a second thing to keep correct.
  /// The two platforms differ only in what they DO with the bytes: a share
  /// sheet on mobile, a blob download in the browser.
  ///
  /// Rendered from `catalog.publicUrl` verbatim, server-side. Answers a
  /// [CatalogFailure] with `CATALOG_NOT_PUBLISHED` before the first publish —
  /// a URL is minted at provisioning and never invented, because a QR that
  /// resolves to nothing is worse than no QR: it might get printed.
  Future<CatalogQrImage> fetchQr({
    CatalogQrFormat format = CatalogQrFormat.png,
    int? size,
  });

  // ── Analytics (features 61-66) ────────────────────────────────────────────
  //
  // Three reads on the same seam as the rest of the catalog, because they are
  // the same resource under the same auth and the same failure translation —
  // an `AnalyticsRepository` would duplicate [mapCatalogErrors] and give the
  // dashboard a second place to learn what CATALOG_NOT_FOUND means.
  //
  // ⚠ NONE OF THESE IS A COLLECTION POINT. ReCapture does not emit
  // customer-facing events; Mirage's public page does, and has for months.
  // These are reads of history that already exists, which is why the dashboard
  // is useful on the day it ships.
  //
  // THE RANGE TRAVELS AS QUERY PARAMETERS. The aggregation happens server-side
  // (and is cached there per resolved range), so a new window is a new request
  // — never a filter over something already fetched. `visitors` in particular
  // is a DISTINCT count and cannot be re-derived client-side by adding days.
  //
  // All three answer `ANALYTICS_UNAVAILABLE` (HTTP 503) when Mirage is asleep,
  // rate-limiting us or refusing our credential. That is a DEGRADATION, not a
  // failure of anything the user did — the screen renders a soft empty state
  // with a retry off the mapped code, and nothing has been lost.

  /// The headline counters for the window, plus the preceding window of equal
  /// length for the deltas (`previousKpis`, which may be null).
  ///
  /// [from] and [to] are `YYYY-MM-DD` UTC days. Omit both to take the server's
  /// default window; the response always carries the range it actually used,
  /// which is what the screen must title itself from.
  Future<AnalyticsSummary> fetchAnalyticsSummary({String? from, String? to});

  /// One row per UTC day, already gap-filled and ordered by Mirage. The client
  /// neither re-sorts nor re-fills — see [AnalyticsTimeseries.points].
  Future<AnalyticsTimeseries> fetchAnalyticsTimeseries({
    String? from,
    String? to,
  });

  /// The most-viewed products, each labelled 3D / image-only / unknown, plus
  /// the per-type totals behind the split (feature 65).
  ///
  /// A row whose product was deleted locally comes back as `UNKNOWN` with its
  /// Mirage id and its views intact — dropping it would make the totals
  /// disagree with the public page's own.
  Future<TopProducts> fetchAnalyticsTopProducts({
    String? from,
    String? to,
    int? limit,
  });
}

/// How many top-product rows the dashboard asks for.
///
/// Enough to scroll, short of the backend's cap of 100: this is a "what is
/// working" list, not an export, and a café with twelve products has already
/// seen everything by row twenty.
const int kTopProductsLimit = 20;

/// What a catalog delete took with it.
///
/// The counts are for the confirmation copy: "deleted, along with 12 products"
/// is the difference between a user believing the action worked and a user
/// pulling to refresh to check.
class CatalogDeletionSummary {
  const CatalogDeletionSummary({
    required this.deletedProducts,
    required this.deletedCategories,
    required this.wasPublished,
  });

  final int deletedProducts;
  final int deletedCategories;

  /// True when a live public page was taken down with it — which is the half
  /// worth saying out loud, because it is the irreversible one.
  final bool wasPublished;
}

/// The two formats the QR endpoint renders. PNG for the screen and for sharing,
/// PDF for printing at a size a sticker press can use.
enum CatalogQrFormat { png, pdf }

extension CatalogQrFormatX on CatalogQrFormat {
  /// Must match the backend `catalogQrQuerySchema` enum exactly.
  String get apiValue => switch (this) {
        CatalogQrFormat.png => 'png',
        CatalogQrFormat.pdf => 'pdf',
      };

  String get label => switch (this) {
        CatalogQrFormat.png => 'PNG',
        CatalogQrFormat.pdf => 'PDF',
      };
}

/// One rendered QR, ready to draw, share or download.
class CatalogQrImage {
  const CatalogQrImage({
    required this.bytes,
    required this.contentType,
    required this.fileName,
    required this.format,
  });

  final Uint8List bytes;

  /// `image/png` or `application/pdf`, as the server sent it.
  final String contentType;

  /// The server's own filename, so a saved file is named after the catalog
  /// rather than after whatever the client would have guessed.
  final String fileName;

  final CatalogQrFormat format;
}

/// Concrete [CatalogRepository] over the app Dio (Bearer attach + 401-refresh
/// via `AuthInterceptor`).
class RemoteCatalogRepository implements CatalogRepository {
  const RemoteCatalogRepository(this._dio);

  final Dio _dio;

  @override
  Future<Catalog?> fetch() async {
    try {
      final res = await _dio.get<Map<String, dynamic>>('/catalog');
      return _catalogFrom(res.data);
    } on DioException catch (error) {
      final failure = CatalogFailure.fromDio(error);
      if (failure.isNoCatalog) return null;
      throw failure;
    }
  }

  @override
  Future<Catalog> create({required String name, String? businessName}) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/catalog',
          data: {
            'name': name,
            // The schema is `.strict()`; a null businessName would be rejected,
            // so an absent value must be an absent KEY.
            if (businessName != null) 'businessName': businessName,
          },
        );
        return _catalogFrom(res.data);
      });

  @override
  Future<Catalog> update({
    String? name,
    String? businessName,
    BusinessContact? contact,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.patch<Map<String, dynamic>>(
          '/catalog',
          data: {
            if (name != null) 'name': name,
            if (businessName != null) 'businessName': businessName,
            if (contact != null) 'contact': contact.toMap(),
          },
        );
        return _catalogFrom(res.data);
      });

  @override
  Future<CatalogDeletionSummary> delete() => mapCatalogErrors(() async {
        final res = await _dio.delete<Map<String, dynamic>>('/catalog');
        final body = res.data;

        // Counts are cosmetic, so a body missing them is NOT a malformed
        // response: the delete happened, and refusing to acknowledge it would
        // send the user back to a catalog that is already gone.
        return CatalogDeletionSummary(
          deletedProducts: _count(body?['deletedProductCount']),
          deletedCategories: _count(body?['deletedCategoryCount']),
          wasPublished: body?['wasPublished'] == true,
        );
      });

  static int _count(Object? value) =>
      value is num && value >= 0 ? value.toInt() : 0;

  @override
  Future<ProductImageSlot> createBrandingSlot({
    required BrandingSlot slot,
    required ProductImageContentType contentType,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/catalog/logo/upload-url',
          data: {'slot': slot.apiValue, 'contentType': contentType.apiValue},
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
  Future<String> uploadBrandingBytes(
    Uint8List bytes, {
    required BrandingSlot slot,
    required String contentType,
  }) =>
      mapCatalogErrors(() async {
        // The raw image IS the body — not multipart, not JSON. The app Dio is
        // right: the endpoint is ours and needs the Bearer token.
        final res = await _dio.post<Map<String, dynamic>>(
          '/catalog/logo/bytes',
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
        if (key is! String || key.isEmpty) {
          throw const CatalogFailure(
            code: 'MALFORMED_RESPONSE',
            message: 'Something went wrong. Please try again.',
          );
        }
        return key;
      });

  @override
  Future<BusinessProfile> commitBranding({
    required BrandingSlot slot,
    required String key,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.put<Map<String, dynamic>>(
          '/catalog/logo',
          data: {'slot': slot.apiValue, 'key': key},
        );
        final profile = res.data?['profile'];
        if (profile is! Map<String, dynamic>) {
          throw const CatalogFailure(
            code: 'MALFORMED_RESPONSE',
            message: 'Something went wrong. Please try again.',
          );
        }
        return BusinessProfile.fromMap(profile);
      });

  @override
  Future<CatalogCategoryList> listCategories() => mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>('/catalog/categories');
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
  Future<CatalogCategory> createCategory(String name) => mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/catalog/categories',
          data: {'name': name},
        );
        return _categoryFrom(res.data);
      });

  @override
  Future<CatalogCategory> renameCategory(String id, String name) =>
      mapCatalogErrors(() async {
        final res = await _dio.patch<Map<String, dynamic>>(
          '/catalog/categories/$id',
          data: {'name': name},
        );
        return _categoryFrom(res.data);
      });

  @override
  Future<int> deleteCategory(String id) => mapCatalogErrors(() async {
        final res =
            await _dio.delete<Map<String, dynamic>>('/catalog/categories/$id');
        final moved = res.data?['movedProductCount'];
        return moved is num && moved >= 0 ? moved.toInt() : 0;
      });

  @override
  Future<void> reorderCategories(List<String> orderedIds) => mapCatalogErrors(() async {
        await _dio.post<Map<String, dynamic>>(
          '/catalog/categories/reorder',
          data: {'ids': orderedIds},
        );
      });

  // ── Publish ───────────────────────────────────────────────────────────────

  @override
  Future<PublishRequestResult> publish({String? idempotencyKey}) =>
      _requestPublish(
        '/catalog/publish',
        idempotencyKey: idempotencyKey,
      );

  @override
  Future<PublishRequestResult> retryFailedPublish() =>
      _requestPublish('/catalog/publish/retry');

  /// The shared body of publish and retry: identical response shapes, identical
  /// refusals, one place that maps them.
  Future<PublishRequestResult> _requestPublish(
    String path, {
    String? idempotencyKey,
  }) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        path,
        options: idempotencyKey == null
            ? null
            : Options(headers: {'Idempotency-Key': idempotencyKey}),
      );

      final body = res.data;
      final runId = body?['runId'];
      if (runId is! String || runId.isEmpty) {
        // 200 with `queued: false` — a retry that found nothing failed. The
        // outcome the user asked for, so it is not a broken contract.
        return const PublishNothingToRetry();
      }
      return PublishQueued(
        runId: runId,
        publicUrl: catalogText(body?['publicUrl']),
      );
    } on DioException catch (error) {
      final result = _refusalFrom(error);
      if (result != null) return result;
      throw CatalogFailure.fromDio(error);
    }
  }

  /// Maps the EXPECTED refusals onto values. Returns null for anything else,
  /// which the caller turns into a [CatalogFailure].
  PublishRequestResult? _refusalFrom(DioException error) {
    final body = error.response?.data;
    if (body is! Map) return null;

    switch (body['code']) {
      case 'PUBLISH_IN_PROGRESS':
        final runId = body['runId'];
        // Without an id there is nothing to poll, so this degrades to a plain
        // failure rather than a screen watching a run it cannot name.
        return runId is String && runId.isNotEmpty
            ? PublishAlreadyRunning(runId)
            : null;

      case 'PUBLISH_BLOCKED':
        return PublishBlocked(PublishGate.listFrom(body['gates']));

      case 'CATALOG_NAME_TAKEN':
        final fields = body['fields'];
        final suggested = fields is Map ? fields['name'] : null;
        return suggested is String && suggested.isNotEmpty
            ? PublishNameTaken(suggested)
            : null;

      default:
        return null;
    }
  }

  @override
  Future<PublishStatus> publishStatus() => mapCatalogErrors(() async {
        final res =
            await _dio.get<Map<String, dynamic>>('/catalog/publish/status');
        final publish = res.data?['publish'];
        if (publish is! Map<String, dynamic>) {
          throw const CatalogFailure(
            code: 'MALFORMED_RESPONSE',
            message: 'Something went wrong. Please try again.',
          );
        }
        return PublishStatus.fromMap(publish);
      });

  @override
  Future<UnpublishResult> unpublish() async {
    try {
      final res = await _dio.post<Map<String, dynamic>>('/catalog/unpublish');
      final body = res.data;
      // `unpublished: false` is the 200 for a catalog that was never live.
      if (body?['unpublished'] != true) return const UnpublishNotPublished();

      final runId = body?['runId'];
      return runId is String && runId.isNotEmpty
          ? UnpublishQueued(runId)
          : const UnpublishNotPublished();
    } on DioException catch (error) {
      final body = error.response?.data;
      if (body is Map && body['code'] == 'PUBLISH_IN_PROGRESS') {
        final runId = body['runId'];
        if (runId is String && runId.isNotEmpty) {
          return UnpublishAlreadyRunning(runId);
        }
      }
      throw CatalogFailure.fromDio(error);
    }
  }

  @override
  Future<CatalogQrImage> fetchQr({
    CatalogQrFormat format = CatalogQrFormat.png,
    int? size,
  }) async {
    try {
      final res = await _dio.get<List<int>>(
        '/catalog/qr',
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
        fileName:
            _qrFileName(res.headers.value('content-disposition')) ??
                'catalog-qr.${format.apiValue}',
        format: format,
      );
    } on DioException catch (error) {
      // THE ONE ENDPOINT WHOSE ERRORS NEED DECODING BY HAND. Asking for bytes
      // applies to the FAILURE body too, so a 409 CATALOG_NOT_PUBLISHED comes
      // back as a byte array and `CatalogFailure.fromDio` — which looks for a
      // Map — would flatten it to a generic "something went wrong". That
      // matters here more than anywhere: "publish first, the QR is created when
      // it goes live" is the single most useful sentence this screen can say,
      // and it is carried entirely by that code.
      throw CatalogFailure.fromDio(_withDecodedBody(error));
    }
  }

  // ── Analytics ─────────────────────────────────────────────────────────────
  //
  // Plain JSON GETs — no bytes-mode special case, so `mapCatalogErrors` alone
  // carries the 503 ANALYTICS_UNAVAILABLE envelope through to the screen with
  // its code intact, which is the whole thing the degraded state is drawn
  // from.

  @override
  Future<AnalyticsSummary> fetchAnalyticsSummary({String? from, String? to}) =>
      mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/catalog/analytics/summary',
          queryParameters: _rangeQuery(from: from, to: to),
        );
        return AnalyticsSummary.fromMap(res.data);
      });

  @override
  Future<AnalyticsTimeseries> fetchAnalyticsTimeseries({
    String? from,
    String? to,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/catalog/analytics/timeseries',
          queryParameters: _rangeQuery(from: from, to: to),
        );
        return AnalyticsTimeseries.fromMap(res.data);
      });

  @override
  Future<TopProducts> fetchAnalyticsTopProducts({
    String? from,
    String? to,
    int? limit,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/catalog/analytics/top-products',
          queryParameters: {
            ..._rangeQuery(from: from, to: to),
            if (limit != null) 'limit': limit,
          },
        );
        return TopProducts.fromMap(res.data);
      });

  /// The `from` / `to` pair, with absent bounds left OUT of the query.
  ///
  /// Absent, not null: the analytics schemas are `.strict()` and a `from=null`
  /// on the wire is a 400 INVALID_REQUEST, which would turn "show me the
  /// default window" into a hard error on the one screen whose whole job is to
  /// degrade gracefully.
  static Map<String, dynamic> _rangeQuery({String? from, String? to}) => {
        if (from != null && from.isNotEmpty) 'from': from,
        if (to != null && to.isNotEmpty) 'to': to,
      };

  /// Re-reads a bytes-mode error response as the house JSON envelope.
  ///
  /// Best effort by design: a proxy's HTML page, a truncated body or a 502 from
  /// the platform leaves the exception exactly as it was, and the caller gets
  /// the generic sentence — which is the right outcome for a body that is not
  /// ours.
  static DioException _withDecodedBody(DioException error) {
    final response = error.response;
    final data = response?.data;
    if (response == null || data is! List<int>) return error;

    try {
      final decoded = jsonDecode(utf8.decode(data));
      if (decoded is! Map<String, dynamic>) return error;
      return error.copyWith(
        response: Response<dynamic>(
          data: decoded,
          statusCode: response.statusCode,
          headers: response.headers,
          requestOptions: response.requestOptions,
        ),
      );
    } on FormatException {
      return error;
    }
  }

  /// The filename out of `Content-Disposition: attachment; filename="..."`.
  ///
  /// Sanitised rather than trusted: it becomes a filename on the user's device,
  /// and a value carrying a path separator would write outside the directory
  /// the caller chose. The server builds it from a slug of the catalog's own
  /// name, so this only ever has to defend against a bug.
  static String? _qrFileName(String? disposition) {
    if (disposition == null) return null;
    final match = RegExp(r'filename="?([^";]+)"?').firstMatch(disposition);
    final raw = match?.group(1)?.trim();
    if (raw == null || raw.isEmpty) return null;
    final safe = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return safe.isEmpty ? null : safe;
  }

  /// Unwraps `{status:"success", catalog:{...}}`. A 2xx without the payload is a
  /// broken contract, not an empty result — fail loudly rather than rendering a
  /// blank catalog the user would try to fix by re-creating one.
  Catalog _catalogFrom(Map<String, dynamic>? body) {
    final catalog = body?['catalog'];
    if (catalog is! Map<String, dynamic>) {
      throw const CatalogFailure(
        code: 'MALFORMED_RESPONSE',
        message: 'Something went wrong. Please try again.',
      );
    }
    return Catalog.fromMap(catalog);
  }

  CatalogCategory _categoryFrom(Map<String, dynamic>? body) {
    final category = body?['category'];
    if (category is! Map<String, dynamic>) {
      throw const CatalogFailure(
        code: 'MALFORMED_RESPONSE',
        message: 'Something went wrong. Please try again.',
      );
    }
    return CatalogCategory.fromMap(category);
  }
}

/// App-wide catalog repository.
final catalogRepositoryProvider = Provider<CatalogRepository>(
  (ref) => RemoteCatalogRepository(ref.watch(dioProvider)),
);
