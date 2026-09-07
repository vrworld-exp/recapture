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
  Future<QrMintResult> mint({required int count, required String label});

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
  Future<QrMintResult> mint({required int count, required String label}) =>
      mapCatalogErrors(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/admin/qr-batches',
          data: {'count': count, 'label': label},
        );
        final body = res.data;
        final batchId = body?['batchId'];
        if (batchId is! String || batchId.isEmpty) {
          throw const CatalogFailure(
            code: 'MALFORMED_RESPONSE',
            message: 'Something went wrong. Please try again.',
          );
        }
        return QrMintResult(
          batchId: batchId,
          minted: (body?['minted'] as num?)?.toInt() ?? 0,
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
