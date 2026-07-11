// lib/application/upload/jobs_multipart_upload_api.dart
//
// The REAL [MultipartUploadApi] adapter against the live recapture-api
// per-file presigned-multipart endpoints (mirrors the dev probe, which uploads
// successfully end-to-end):
//
//   POST /jobs/:jobId/uploads/initiate  { key, fileSize, partCount }
//     → { uploadId, key, parts: [{ partNumber, url }], urlsExpireAt }
//   POST /jobs/:jobId/uploads/part-url  { key, uploadId, partNumber } → { url }
//   POST /jobs/:jobId/uploads/complete  { key, uploadId,
//                                         parts: [{ partNumber, etag }] }
//
// All bodies/fields are camelCase (the backend envelope convention). Calls go
// through the AUTHED upload Dio (Bearer attach — see upload_auth_session.dart);
// the direct-to-S3 part PUTs stay on [DioS3PartClient]'s separate bare Dio.
//
// ABORT: the backend deliberately has NO uploads/abort route (it keeps no
// per-file state; incomplete multipart uploads are reclaimed by the S3
// lifecycle rule). [abort] is therefore a local no-op — the engine's abort is
// already best-effort, and cancelling still stops every in-flight part PUT.
import 'package:dio/dio.dart';

import 'multipart_upload_api.dart';

/// Backend broker for one job's presigned multipart uploads.
class JobsMultipartUploadApi implements MultipartUploadApi {
  const JobsMultipartUploadApi({required Dio dio, required String jobId})
      : _dio = dio,
        _jobId = jobId;

  final Dio _dio;
  final String _jobId;

  @override
  Future<InitiatedUpload> initiate({
    required String sessionId,
    required String fileKey,
    required int fileSize,
    required int partCount,
  }) async {
    // sessionId is engine-internal bookkeeping; the backend scopes by jobId.
    final res = await _dio.post<Map<String, dynamic>>(
      '/jobs/$_jobId/uploads/initiate',
      data: {
        'key': fileKey,
        'fileSize': fileSize,
        'partCount': partCount,
      },
    );
    final data = res.data ?? const {};
    final rawParts = (data['parts'] as List?) ?? const [];
    return InitiatedUpload(
      uploadId: data['uploadId'] as String,
      key: (data['key'] as String?) ?? fileKey,
      parts: [
        for (final p in rawParts.whereType<Map>())
          PresignedPart(
            partNumber: (p['partNumber'] as num).toInt(),
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
      '/jobs/$_jobId/uploads/part-url',
      data: {'key': key, 'uploadId': uploadId, 'partNumber': partNumber},
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
      '/jobs/$_jobId/uploads/complete',
      data: {
        'key': key,
        'uploadId': uploadId,
        // The engine already supplies ascending part-number order (an S3
        // CompleteMultipartUpload requirement the backend passes through).
        'parts': [for (final p in parts) p.toJson()],
      },
    );
  }

  @override
  Future<void> abort({required String uploadId, required String key}) async {
    // No backend route (see header). Local no-op keeps the engine's
    // best-effort abort silent instead of manufacturing a guaranteed 404.
  }
}
