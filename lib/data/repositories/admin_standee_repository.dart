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
import '../../domain/entities/standee_activation.dart';
import '../remote/api_client.dart';
import 'bytes_response.dart';
import 'catalog_failure.dart';
import 'catalog_repository.dart'
    show CatalogQrFormat, CatalogQrFormatX, CatalogQrImage;

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

  /// The batch is bigger than one printable sheet request will render.
  ///
  /// Worth its own sentence for the same reason [resolverNotConfigured] is:
  /// the recovery is a DIFFERENT button (the vendor CSV), not a retry, and an
  /// admin who saw a generic failure would press this one again.
  static const batchTooLarge = 'BATCH_TOO_LARGE';

  /// Every code in the batch is retired, so the sheet would be blank paper.
  static const nothingToPrint = 'NOTHING_TO_PRINT';

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

/// A whole batch's printable sheet, and what the server says is on it.
///
/// The counts arrive as `X-Standee-Sheet-*` RESPONSE HEADERS because the body
/// is already the PDF — there is nowhere in it to put them. They are not
/// decoration: `skippedRetired` is the only thing that explains a batch of 50
/// printing 48 cards, and without it a correct sheet reads as a short one.
class BatchSheetDownload {
  const BatchSheetDownload({
    required this.file,
    required this.standees,
    required this.pages,
    required this.skippedRetired,
  });

  final QrDownloadFile file;

  /// Cards actually on the sheet. Retired codes are not among them.
  final int standees;
  final int pages;
  final int skippedRetired;
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

  /// What an ACTIVE standee turned into: the restaurant and who activated it.
  ///
  /// Throws [CatalogFailure] with [AdminStandeeErrorCodes.notFound] for a code
  /// that is not in use — unknown, unassigned stock, retired, or an activation
  /// whose restaurant was deleted; the backend makes no distinction.
  Future<StandeeActivation> activation(String code);

  /// The activated RESTAURANT's own QR — the Mirage link, the same square the
  /// rep's and the owner's QR screens draw — not the standee sheet.
  ///
  /// Throws [CatalogFailure] with `CATALOG_NOT_PUBLISHED` while the restaurant
  /// has been activated but never published.
  Future<CatalogQrImage> activationQr(
    String code, {
    CatalogQrFormat format,
    int? size,
  });

  /// The print vendor's CSV for a whole batch.
  Future<QrDownloadFile> batchCsv(String batchId);

  /// THE WHOLE BATCH as one printable PDF — nine standees to an A4 page, with
  /// cut guides, as many pages as the run needs.
  ///
  /// The per-page count is the SERVER'S, not this client's: the layout is an
  /// env-tuned grid that clamps itself to what A4 holds, and both surfaces just
  /// deliver the bytes. The page count worth showing a user is the one that
  /// comes back in `X-Standee-Sheet-Pages`, never one computed here.
  ///
  /// The other half of [standeeFile], which renders ONE code. That is right for
  /// sending a rep a single standee and absurd for a run of fifty: fifty
  /// presses, fifty near-identical files, fifty sheets of paper for fifty
  /// squares.
  ///
  /// Throws [CatalogFailure] with [AdminStandeeErrorCodes.batchTooLarge] for a
  /// run past the server's per-request ceiling (the recovery is the vendor CSV,
  /// not a retry) and [AdminStandeeErrorCodes.nothingToPrint] when every code
  /// in the batch is retired.
  Future<BatchSheetDownload> batchSheet(String batchId);

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
      ).then((res) => res.file);

  @override
  Future<StandeeActivation> activation(String code) =>
      mapCatalogErrors(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/admin/qr-codes/$code/activation',
        );
        final raw = res.data?['activation'];
        if (raw is! Map<String, dynamic>) {
          throw const CatalogFailure(
            code: 'MALFORMED_RESPONSE',
            message: 'Something went wrong. Please try again.',
          );
        }
        return StandeeActivation.fromMap(raw);
      });

  @override
  Future<CatalogQrImage> activationQr(
    String code, {
    CatalogQrFormat format = CatalogQrFormat.png,
    int? size,
  }) async {
    // Through [_bytes] so a 409 CATALOG_NOT_PUBLISHED keeps its code — see the
    // note on that helper — then reshaped into the image the shared QR
    // notifier state carries.
    final res = await _bytes(
      '/admin/qr-codes/$code/activation/qr',
      query: {
        'format': format.apiValue,
        if (size != null) 'size': size,
      },
      fallbackName: 'catalog-qr.${format.apiValue}',
      fallbackMime:
          format == CatalogQrFormat.png ? 'image/png' : 'application/pdf',
    );
    return CatalogQrImage(
      bytes: res.file.bytes,
      contentType: res.file.mimeType,
      fileName: res.file.fileName,
      format: format,
    );
  }

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
      ).then((res) => res.file);

  @override
  Future<BatchSheetDownload> batchSheet(String batchId) async {
    final res = await _bytes(
      '/admin/qr-batches/$batchId/sheet',
      fallbackName: 'standee-sheet.pdf',
      fallbackMime: 'application/pdf',
    );

    return BatchSheetDownload(
      file: res.file,
      // Defaulted rather than demanded. These headers only describe the file for
      // a sentence afterwards; a proxy that strips them, or a browser that has
      // not been told to expose them, must not turn a good download into an
      // error. A zero simply drops that clause from what the screen says.
      standees: _headerInt(res.headers, 'x-standee-sheet-standees'),
      pages: _headerInt(res.headers, 'x-standee-sheet-pages'),
      skippedRetired: _headerInt(res.headers, 'x-standee-sheet-skipped-retired'),
    );
  }

  static int _headerInt(Headers headers, String name) =>
      int.tryParse(headers.value(name) ?? '') ?? 0;

  /// The shared bytes-mode GET.
  ///
  /// THE ERROR PATH IS THE POINT. `responseType: bytes` applies to failures too,
  /// so without [withDecodedBody] a 409 CODE_RETIRED or RESOLVER_NOT_CONFIGURED
  /// arrives as an undecodable byte array and collapses into a generic sentence
  /// — and those two codes carry the only two things an admin can act on.
  ///
  /// Returns the HEADERS alongside the file because the batch sheet's counts
  /// travel in them: the body is the PDF, so there is nowhere else they could
  /// go. Callers that do not need them drop them at the call site.
  Future<({QrDownloadFile file, Headers headers})> _bytes(
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

      return (
        file: QrDownloadFile(
          bytes: Uint8List.fromList(data),
          fileName: fileNameFromDisposition(
                res.headers.value('content-disposition'),
              ) ??
              fallbackName,
          mimeType: res.headers.value(Headers.contentTypeHeader) ?? fallbackMime,
        ),
        headers: res.headers,
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
