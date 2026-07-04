// lib/application/upload/multipart_upload_api.dart
//
// The injectable boundary between the upload ENGINE and the outside world:
//   • [MultipartUploadApi] — the BACKEND broker (initiate / complete / abort, and
//     an optional presigned-URL refresh). Uses the app's authenticated Dio.
//   • [S3PartClient] — the direct-to-S3 presigned part PUT (returns the ETag).
//   • [PartByteSource] — streams a byte range of a file off disk (memory-bounded).
//
// All three are interfaces so the manager is fully unit-testable with fakes. Dio-
// backed defaults are provided for wiring.
//
// AUTH NOTE (important): the backend broker calls go through the project's
// configured, AUTHENTICATED Dio (`dioProvider`) — Bearer attach + 401 refresh. The
// S3 part PUTs must NOT carry that Authorization header: a presigned URL is
// self-authenticating and an extra Authorization header breaks the signature. So
// [DioS3PartClient] deliberately uses a SEPARATE, interceptor-free Dio. This is not
// "spinning up an unconfigured client" for API calls — it is the correct, required
// separation for direct-to-S3 transfers.
//
// ENDPOINTS ARE PLACEHOLDERS pending backend confirmation (recapture-api has no
// upload routes yet): the paths/payloads in [DioMultipartUploadApi] implement the
// assumed presigned-multipart contract and MUST be reconciled when the backend
// lands. The engine itself depends only on the interfaces, so confirming the
// contract is a change to this one adapter, not the manager.
import 'dart:async';

import 'dart:io';

import 'package:dio/dio.dart';

import '../../domain/upload/upload_part_plan.dart' show normalizeETag;

/// A presigned URL for one part (1-based [partNumber]).
class PresignedPart {
  const PresignedPart({required this.partNumber, required this.url});

  final int partNumber;
  final String url;
}

/// Result of initiating a multipart upload for one file.
class InitiatedUpload {
  const InitiatedUpload({
    required this.uploadId,
    required this.key,
    required this.parts,
  });

  /// The S3 multipart upload id — echoed back on complete/abort.
  final String uploadId;

  /// The S3 object key — echoed back on complete/abort.
  final String key;

  /// Presigned part URLs, one per planned part (may be empty if the contract
  /// fetches URLs per part via [MultipartUploadApi.refreshPartUrl]).
  final List<PresignedPart> parts;

  /// The presigned URL for [partNumber], or null if not provided upfront.
  String? urlForPart(int partNumber) {
    for (final p in parts) {
      if (p.partNumber == partNumber) return p.url;
    }
    return null;
  }
}

/// One completed part's ETag, submitted (in ascending part-number order) on complete.
class CompletedPart {
  const CompletedPart({required this.partNumber, required this.etag});

  final int partNumber;
  final String etag;

  Map<String, dynamic> toJson() => {'part_number': partNumber, 'etag': etag};
}

/// The backend broker for the presigned multipart lifecycle.
abstract interface class MultipartUploadApi {
  /// Begins a multipart upload for a file; returns the upload id, key, and (per the
  /// contract) the presigned part URLs.
  Future<InitiatedUpload> initiate({
    required String sessionId,
    required String fileKey,
    required int fileSize,
    required int partCount,
  });

  /// Re-fetches a presigned URL for [partNumber] when the original expired (403).
  /// Returns null if the contract does not support per-part refresh (→ the part
  /// fails after retries).
  Future<String?> refreshPartUrl({
    required String uploadId,
    required String key,
    required int partNumber,
  });

  /// Completes the multipart upload with [parts] in ASCENDING part-number order.
  Future<void> complete({
    required String uploadId,
    required String key,
    required List<CompletedPart> parts,
  });

  /// Aborts the multipart upload so S3 does not retain an incomplete (billed) upload.
  Future<void> abort({required String uploadId, required String key});
}

/// Uploads one part's bytes to its presigned S3 URL and returns the normalized ETag.
abstract interface class S3PartClient {
  Future<String> putPart({
    required String url,
    required Stream<List<int>> body,
    required int length,
    void Function(int sent, int total)? onSendProgress,
    required CancelToken cancelToken,
  });
}

/// Streams a byte range of a file — the engine reads part bytes lazily from disk so
/// a large file never sits fully in memory.
abstract interface class PartByteSource {
  /// The file's size in bytes (0 if missing/unreadable).
  int fileSize(String path);

  /// A lazy stream of `[offset, offset + length)` of the file.
  Stream<List<int>> read(String path, int offset, int length);
}

/// `dart:io`-backed [PartByteSource]: `File.openRead` streams the range in chunks.
class FilePartByteSource implements PartByteSource {
  const FilePartByteSource();

  @override
  int fileSize(String path) {
    final f = File(path);
    return f.existsSync() ? f.lengthSync() : 0;
  }

  @override
  Stream<List<int>> read(String path, int offset, int length) =>
      File(path).openRead(offset, offset + length);
}

/// Dio-backed presigned part PUT. Uses a SEPARATE interceptor-free Dio (see the
/// auth note above) so the app's Bearer token is never attached to the S3 URL.
class DioS3PartClient implements S3PartClient {
  DioS3PartClient([Dio? dio]) : _dio = dio ?? Dio();

  final Dio _dio;

  @override
  Future<String> putPart({
    required String url,
    required Stream<List<int>> body,
    required int length,
    void Function(int sent, int total)? onSendProgress,
    required CancelToken cancelToken,
  }) async {
    final res = await _dio.put<void>(
      url,
      data: body,
      options: Options(
        headers: {Headers.contentLengthHeader: length},
        // S3 returns bytes/empty; we only need the ETag header.
        responseType: ResponseType.plain,
      ),
      onSendProgress: onSendProgress,
      cancelToken: cancelToken,
    );
    final raw = res.headers.value('etag') ?? res.headers.value('ETag');
    if (raw == null || raw.isEmpty) {
      throw StateError('S3 part PUT returned no ETag header');
    }
    return normalizeETag(raw);
  }
}

/// Dio-backed broker against the ASSUMED presigned-multipart endpoints. PLACEHOLDER
/// paths — reconcile with the backend when upload routes land (the engine depends
/// only on [MultipartUploadApi], so only this adapter changes).
class DioMultipartUploadApi implements MultipartUploadApi {
  const DioMultipartUploadApi(this._dio, {this.basePath = '/uploads'});

  final Dio _dio;
  final String basePath;

  @override
  Future<InitiatedUpload> initiate({
    required String sessionId,
    required String fileKey,
    required int fileSize,
    required int partCount,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '$basePath/initiate',
      data: {
        'session_id': sessionId,
        'key': fileKey,
        'file_size': fileSize,
        'part_count': partCount,
      },
    );
    final data = res.data ?? const {};
    final rawParts = (data['part_urls'] as List?) ?? const [];
    return InitiatedUpload(
      uploadId: data['upload_id'] as String,
      key: (data['key'] as String?) ?? fileKey,
      parts: [
        for (final p in rawParts.whereType<Map>())
          PresignedPart(
            partNumber: (p['part_number'] as num).toInt(),
            url: p['url'] as String,
          ),
      ],
    );
  }

  @override
  Future<String?> refreshPartUrl({
    required String uploadId,
    required String key,
    required int partNumber,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '$basePath/part-url',
      data: {'upload_id': uploadId, 'key': key, 'part_number': partNumber},
    );
    return res.data?['url'] as String?;
  }

  @override
  Future<void> complete({
    required String uploadId,
    required String key,
    required List<CompletedPart> parts,
  }) async {
    await _dio.post<void>(
      '$basePath/complete',
      data: {
        'upload_id': uploadId,
        'key': key,
        'parts': [for (final p in parts) p.toJson()],
      },
    );
  }

  @override
  Future<void> abort({required String uploadId, required String key}) async {
    await _dio.post<void>(
      '$basePath/abort',
      data: {'upload_id': uploadId, 'key': key},
    );
  }
}
