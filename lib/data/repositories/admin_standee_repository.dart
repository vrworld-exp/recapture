// lib/data/repositories/admin_standee_repository.dart
//
// Data access for the ADMIN half of the standee pipeline: mint a run of codes,
// see what is left in each batch, and get one code into a rep's hands as a
// printable file.
//
// Mirrors [RepRepository]'s error boundary exactly: every method throws
// [CatalogFailure], never a [DioException], and screens branch on the failure's
// `code` rather than on its sentence.
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/catalog/qr_download_file.dart';
import '../../domain/entities/qr_standee.dart';
import '../remote/api_client.dart';
import 'bytes_response.dart';
import 'catalog_failure.dart';

/// Error codes the standee endpoints return that a screen actually branches on.
abstract final class AdminStandeeErrorCodes {
  /// PUBLIC_RESOLVER_BASE_URL is unset on this deployment.
  ///
  /// THE one error here worth a sentence of its own. Every URL this surface
  /// produces is destined to be printed onto something physical, so the backend
  /// refuses to guess a host — and an admin who saw only a generic failure would
  /// reasonably retry, mint again, and still get nothing.
  static const resolverNotConfigured = 'RESOLVER_NOT_CONFIGURED';

  /// Asked to render a standee that was retired. Mint a replacement instead.
  static const codeRetired = 'CODE_RETIRED';

  /// The picked account cannot hold a standee — it does not exist, or it has
  /// no staff role. One code for both, matching the backend, which will not say
  /// which of the two it was.
  static const repNotFound = 'REP_NOT_FOUND';

  static const notFound = 'NOT_FOUND';
  static const invalidRequest = 'INVALID_REQUEST';
}

/// Which file the admin wants for a code.
enum StandeeQrFormat {
  /// The bare image, for dropping into a chat or a doc.
  png,

  /// A one-page sheet with the code and its URL printed under the square — the
  /// thing a rep can actually print and put on a table.
  pdf;

  String get apiValue => name;
}

abstract interface class AdminStandeeRepository {
  /// Every mint run, newest first, with what is left in each.
  Future<List<QrBatchSummary>> batches();

  /// Mints a run. `count` is bounded server-side by QR_BATCH_MAX_SIZE.
  /// Mints a run. count is bounded server-side by QR_BATCH_MAX_SIZE.
  ///
  /// [assignToUserId] hands the whole run to one staff member as it is
  /// created, which is the point: an admin sending a rep out with twenty
  /// standees should not assign twenty rows one at a time. Omit it to mint
  /// unassigned stock.
  Future<QrMintResult> mint({
    required int count,
    required String label,
    String? assignToUserId,
  });

  /// One keyset page of a batch's codes, sorted by code.
  ///
  /// [after] is the previous page's last code; null starts at the beginning.
  Future<QrCodePage> codes(String batchId, {String? after, int? limit});

  /// The printable standee for one code.
  ///
  /// Throws [CatalogFailure] with [AdminStandeeErrorCodes.codeRetired] for a
  /// retired code — the backend refuses rather than handing back a sheet that
  /// resolves to the fallback page once somebody has printed it.
  Future<QrDownloadFile> standeeFile(
    String code, {
    StandeeQrFormat format,
    int? size,
  });

  /// The print vendor's CSV for a whole batch.
  Future<QrDownloadFile> batchCsv(String batchId);

  /// Everyone an admin may hand a standee to.
  ///
  /// Unpaged and unsearchable, mirroring the endpoint: this is the internal
  /// staff roster, a handful of people, not a user directory.
  Future<List<SalesRepSummary>> salesReps();

  /// Hands one standee to one rep, and reports who ends up holding it.
  ///
  /// IDEMPOTENT AND OVERWRITING — assigning an already-assigned code succeeds
  /// and moves it, because a standee is a physical object that changes hands.
  ///
  /// Throws [CatalogFailure] with [AdminStandeeErrorCodes.repNotFound] for an
  /// account that cannot hold one, and [AdminStandeeErrorCodes.codeRetired]
  /// for a standee that is out of service.
  Future<StandeeAssignee> assign(String code, {required String repUserId});

  /// Takes a standee back off whoever was holding it. Succeeds on a code
  /// nobody holds — the admin's intent is satisfied either way.
  Future<void> unassign(String code);

  /// Hands an ENTIRE batch to one staff member in one call.
  ///
  /// The other half of bulk: minting covers a run created for a known rep,
  /// this covers every case where that is not how it went — a batch minted
  /// before anyone knew who was carrying it, a rep who left, a territory
  /// that moved. Without it an admin is back to one row at a time.
  Future<BatchAssignmentResult> assignBatch(
    String batchId, {
    required String repUserId,
  });

  /// Empties a batch back into stock. Succeeds on a batch nobody holds.
  Future<int> unassignBatch(String batchId);
}

class RemoteAdminStandeeRepository implements AdminStandeeRepository {
  const RemoteAdminStandeeRepository(this._dio);

  final Dio _dio;

  @override
  Future<List<QrBatchSummary>> batches() => mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>('/admin/qr-batches');
        final raw = res.data?['batches'];
        if (raw is! List) return const <QrBatchSummary>[];
        return raw
            .whereType<Map<String, dynamic>>()
            .map(QrBatchSummary.fromMap)
            .toList(growable: false);
      });

  @override
  Future<QrMintResult> mint({
    required int count,
    required String label,
    String? assignToUserId,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/admin/qr-batches',
          data: {
            'count': count,
            'label': label,
            // OMITTED, not null, when nobody was picked: the request body
            // is strict server-side, and an explicit null is a different
            // request from an absent key.
            if (assignToUserId != null) 'assignToUserId': assignToUserId,
          },
        );
        final body = res.data;
        final batchId = body?['batchId'];
        if (batchId is! String || batchId.isEmpty) {
          throw const CatalogFailure(
            code: 'MALFORMED_RESPONSE',
            message: 'Something went wrong. Please try again.',
          );
        }
        final assignedTo = body?['assignedTo'];
        return QrMintResult(
          batchId: batchId,
          minted: (body?['minted'] as num?)?.toInt() ?? 0,
          assignedTo: assignedTo is Map<String, dynamic>
              ? StandeeAssignee.fromMap(assignedTo)
              : null,
        );
      });

  @override
  Future<QrCodePage> codes(String batchId, {String? after, int? limit}) =>
      mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/admin/qr-batches/$batchId/codes',
          queryParameters: {
            if (after != null && after.isNotEmpty) 'after': after,
            if (limit != null) 'limit': limit,
          },
        );
        final raw = res.data?['codes'];
        final next = res.data?['nextAfter'];
        return QrCodePage(
          codes: raw is List
              ? raw
                  .whereType<Map<String, dynamic>>()
                  .map(QrStandeeCode.fromMap)
                  .toList(growable: false)
              : const <QrStandeeCode>[],
          nextAfter: next is String && next.isNotEmpty ? next : null,
        );
      });

  @override
  Future<QrDownloadFile> standeeFile(
    String code, {
    StandeeQrFormat format = StandeeQrFormat.pdf,
    int? size,
  }) =>
      _bytes(
        '/admin/qr-codes/$code/qr',
        query: {
          'format': format.apiValue,
          if (size != null) 'size': size,
        },
        fallbackName: 'standee-$code.${format.apiValue}',
        fallbackMime:
            format == StandeeQrFormat.png ? 'image/png' : 'application/pdf',
      );

  @override
  Future<List<SalesRepSummary>> salesReps() => mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>('/admin/sales-reps');
        final raw = res.data?['reps'];
        if (raw is! List) return const <SalesRepSummary>[];
        return raw
            .whereType<Map<String, dynamic>>()
            .map(SalesRepSummary.fromMap)
            .toList(growable: false);
      });

  @override
  Future<StandeeAssignee> assign(String code, {required String repUserId}) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/admin/qr-codes/$code/assignment',
          data: {'repUserId': repUserId},
        );
        final holder = res.data?['assignedTo'];
        if (holder is! Map<String, dynamic>) {
          throw const CatalogFailure(
            code: 'MALFORMED_RESPONSE',
            message: 'Something went wrong. Please try again.',
          );
        }
        return StandeeAssignee.fromMap(holder);
      });

  @override
  Future<void> unassign(String code) => mapCatalogErrors(() async {
        await _dio.delete<Map<String, dynamic>>(
          '/admin/qr-codes/$code/assignment',
        );
      });

  @override
  Future<BatchAssignmentResult> assignBatch(
    String batchId, {
    required String repUserId,
  }) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/admin/qr-batches/$batchId/assignment',
          data: {'repUserId': repUserId},
        );
        final body = res.data;
        final holder = body?['assignedTo'];
        return BatchAssignmentResult(
          assigned: (body?['assigned'] as num?)?.toInt() ?? 0,
          skippedRetired: (body?['skippedRetired'] as num?)?.toInt() ?? 0,
          assignedTo: holder is Map<String, dynamic>
              ? StandeeAssignee.fromMap(holder)
              : null,
        );
      });

  @override
  Future<int> unassignBatch(String batchId) => mapCatalogErrors(() async {
        final res = await _dio.delete<Map<String, dynamic>>(
          '/admin/qr-batches/$batchId/assignment',
        );
        return (res.data?['unassigned'] as num?)?.toInt() ?? 0;
      });

  @override
  Future<QrDownloadFile> batchCsv(String batchId) => _bytes(
        '/admin/qr-batches/$batchId/export',
        fallbackName: 'qr-batch.csv',
        fallbackMime: 'text/csv',
      );

  /// The shared bytes-mode GET.
  ///
  /// THE ERROR PATH IS THE POINT. `responseType: bytes` applies to failures too,
  /// so without [withDecodedBody] a 409 CODE_RETIRED or RESOLVER_NOT_CONFIGURED
  /// arrives as an undecodable byte array and collapses into a generic sentence
  /// — and those two codes carry the only two things an admin can act on.
  Future<QrDownloadFile> _bytes(
    String path, {
    Map<String, dynamic>? query,
    required String fallbackName,
    required String fallbackMime,
  }) async {
    try {
      final res = await _dio.get<List<int>>(
        path,
        queryParameters: query,
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
                fallbackName,
        mimeType: res.headers.value(Headers.contentTypeHeader) ?? fallbackMime,
      );
    } on DioException catch (error) {
      throw CatalogFailure.fromDio(withDecodedBody(error));
    }
  }
}

/// The `/admin` standee data source. Overridden with a fake in tests.
final adminStandeeRepositoryProvider = Provider<AdminStandeeRepository>(
  (ref) => RemoteAdminStandeeRepository(ref.watch(dioProvider)),
);
