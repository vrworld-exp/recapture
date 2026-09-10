// lib/data/remote/model_upload_client.dart
//
// The direct-to-S3 PUT for a staff-submitted `.glb`.
//
// AUTH: a presigned URL is self-authenticating, and an extra `Authorization`
// header BREAKS the signature — so this uses its own interceptor-free Dio and
// never `dioProvider`. Identical reasoning (and identical shape) to
// [DioS3PartClient] on the capture upload path; the two are separate because
// that one speaks multipart parts and ETags, and this one puts a whole object.
//
// CONTENT-TYPE IS PART OF THE SIGNATURE. The server presigns with
// `model/gltf-binary`, so the PUT must send exactly that or S3 rejects it.
//
// STREAMED, ALWAYS. The body is [PickedModelFile.openRead] — path-backed on
// native, blob-backed on web — so a 100 MiB model never sits in RAM to be
// uploaded, on either target, and this file needs no platform branch at all.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../datasources/model_file_picker.dart';

/// The content type the server signs the slot with. Hand-synced with
/// `GLB_CONTENT_TYPE` in recapture-api/src/services/projectModelsService.ts.
const String kGlbContentType = 'model/gltf-binary';

/// Uploads one picked model to its presigned slot.
abstract interface class ModelUploadClient {
  /// PUTs [file] to [url]. [onProgress] reports 0..1 so the screen can show a
  /// bar rather than an indeterminate spinner — a model upload is long enough
  /// that "is this doing anything?" is a real question.
  ///
  /// Throws [DioException] on failure; the repository translates it.
  Future<void> putGlb({
    required String url,
    required PickedModelFile file,
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  });
}

class DioModelUploadClient implements ModelUploadClient {
  DioModelUploadClient([Dio? dio]) : _dio = dio ?? Dio();

  final Dio _dio;

  @override
  Future<void> putGlb({
    required String url,
    required PickedModelFile file,
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    await _dio.put<void>(
      url,
      data: file.openRead(),
      options: Options(
        headers: {
          Headers.contentLengthHeader: file.size,
          Headers.contentTypeHeader: kGlbContentType,
        },
        // S3 answers with an empty body; nothing here parses it.
        responseType: ResponseType.plain,
      ),
      onSendProgress: (sent, total) {
        if (onProgress == null) return;
        // `total` is -1 when the length is unknown; the picked size is the one
        // number that is always right, and it is what we signed the PUT with.
        final denominator = total > 0 ? total : file.size;
        if (denominator <= 0) return;
        onProgress((sent / denominator).clamp(0.0, 1.0));
      },
      cancelToken: cancelToken,
    );
  }
}

final modelUploadClientProvider = Provider<ModelUploadClient>(
  (ref) => DioModelUploadClient(),
);
