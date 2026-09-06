// lib/data/repositories/project_photos_repository.dart
//
// All HTTP for the artist photo-upload surface, plus its error translation.
// The notifier above it is pure state and never sees a Dio type or an envelope
// (AGENTS.md: repositories own all HTTP and error translation).
//
//   POST   /projects/:id/photos/session   → the job id + server-assigned keys
//   POST   /projects/:id/photos/commit    → verify what landed
//   GET    /projects/:id/photos           → presigned thumbnails
//   DELETE /projects/:id/photos           → soft-delete out of the set
//   POST   /projects/:id/photos/generate  → the credit-spending step
//
// The BYTES do not go through here: they ride the existing
// `/jobs/:jobId/uploads/*` engine, which [photo_set_upload_flow.dart] drives.
//
// A presigned URL is a bearer credential — it lives on [ProjectPhoto.url] and
// is never logged.
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../remote/api_client.dart';

/// One server-assigned upload slot, in the order the client listed its files.
class PhotoUploadSlot {
  const PhotoUploadSlot({required this.key});

  /// The full S3 object key. Echoed to initiate/part-url/complete verbatim.
  final String key;
}

/// The opened session: the job the bytes upload against, plus its slots.
class PhotoUploadSession {
  const PhotoUploadSession({
    required this.jobId,
    required this.slots,
    required this.keyPrefix,
  });

  final String jobId;
  final List<PhotoUploadSlot> slots;

  /// Containment boundary for every object of this job. Kept for diagnostics —
  /// the client never composes a key itself.
  final String keyPrefix;
}

/// One uploaded photo as the grid renders it.
class ProjectPhoto {
  const ProjectPhoto({
    required this.key,
    required this.url,
    required this.size,
  });

  /// Job-RELATIVE key (`uploads/photo_0001.jpg`) — what delete and generate
  /// echo back. NOT a display name.
  final String key;

  /// Presigned GET, valid for about an hour. A BEARER CREDENTIAL: never log it.
  final String url;

  final int size;
}

/// Why a photo-upload call failed, in terms the notifier can render.
///
/// Mapped, never a raw code and never raw server text — the same stance the
/// upload failure categories take.
enum PhotoUploadFailure {
  /// No connectivity, or the request never reached the server.
  offline,

  /// 403 — the account is not a MODEL_ARTIST. The client gate is UX; this is
  /// the server saying no.
  forbidden,

  /// 404 — no such project, or not this user's. Deliberately indistinguishable.
  notFound,

  /// 409 — the project was created for guided capture, so it cannot take
  /// uploads.
  notAnUploadProject,

  /// 429 — too many sessions or too many generations.
  rateLimited,

  /// 413 — at least one photo exceeded the server's per-photo ceiling and was
  /// removed. The artist must re-upload smaller versions.
  photoTooLarge,

  /// 400 with TOO_FEW_PHOTOS — fewer photos arrived than the minimum.
  tooFewPhotos,

  /// Anything else, including a malformed response.
  unknown,
}

/// Thrown by every method here. Carries a mapped [failure] plus, when the
/// server sent one we trust, its owner-safe [message].
class PhotoUploadException implements Exception {
  const PhotoUploadException(this.failure, [this.message]);

  final PhotoUploadFailure failure;
  final String? message;

  @override
  String toString() => 'PhotoUploadException($failure)';
}

abstract interface class ProjectPhotosRepository {
  /// Opens an upload session for [files], in the order they will be uploaded.
  ///
  /// The client sends only `{contentType, size}` per file — never a name. Every
  /// KEY comes back from the server.
  Future<PhotoUploadSession> openSession({
    required String projectId,
    required List<({String contentType, int size})> files,
    String? idempotencyKey,
  });

  /// Closes the session: the server verifies what actually landed in S3 and
  /// flips the job to UPLOADED. Idempotent.
  Future<int> commit({required String projectId, required String jobId});

  /// The project's uploaded set, presigned for the grid.
  Future<List<ProjectPhoto>> listPhotos(String projectId);

  /// Soft-deletes photos out of the set (a move to `deleted/`, never a hard
  /// delete). Fail-closed server-side: one bad key refuses the whole request.
  Future<void> deletePhotos({
    required String projectId,
    required List<String> keys,
  });

  /// Asks for a 3D model from the hand-picked [keys] (3–4).
  ///
  /// THIS is the step that spends credits. Returns the new model's id.
  Future<String> generateModel({
    required String projectId,
    required List<String> keys,
    String? idempotencyKey,
  });
}

class RemoteProjectPhotosRepository implements ProjectPhotosRepository {
  const RemoteProjectPhotosRepository(this._dio);

  final Dio _dio;

  @override
  Future<PhotoUploadSession> openSession({
    required String projectId,
    required List<({String contentType, int size})> files,
    String? idempotencyKey,
  }) async {
    return _guard(() async {
      final res = await _dio.post<Map<String, dynamic>>(
        '/projects/$projectId/photos/session',
        data: {
          'files': [
            for (final file in files)
              {'contentType': file.contentType, 'size': file.size},
          ],
        },
        options: idempotencyKey == null
            ? null
            : Options(headers: {'Idempotency-Key': idempotencyKey}),
      );
      final data = res.data ?? const <String, dynamic>{};
      final jobId = data['jobId'];
      final rawSlots = data['files'];
      final plan = data['uploadPlan'];
      if (jobId is! String || rawSlots is! List || plan is! Map) {
        throw const PhotoUploadException(PhotoUploadFailure.unknown);
      }
      return PhotoUploadSession(
        jobId: jobId,
        keyPrefix: (plan['keyPrefix'] ?? '').toString(),
        slots: [
          for (final slot in rawSlots.whereType<Map>())
            PhotoUploadSlot(key: (slot['key'] ?? '').toString()),
        ],
      );
    });
  }

  @override
  Future<int> commit({required String projectId, required String jobId}) {
    return _guard(() async {
      final res = await _dio.post<Map<String, dynamic>>(
        '/projects/$projectId/photos/commit',
        data: {'jobId': jobId},
      );
      final count = res.data?['photoCount'];
      return count is num ? count.toInt() : 0;
    });
  }

  @override
  Future<List<ProjectPhoto>> listPhotos(String projectId) {
    return _guard(() async {
      final res = await _dio.get<Map<String, dynamic>>('/projects/$projectId/photos');
      final items = res.data?['items'];
      if (items is! List) return const <ProjectPhoto>[];
      return [
        for (final item in items.whereType<Map>())
          ProjectPhoto(
            key: (item['key'] ?? '').toString(),
            url: (item['url'] ?? '').toString(),
            size: item['size'] is num ? (item['size'] as num).toInt() : 0,
          ),
      ];
    });
  }

  @override
  Future<void> deletePhotos({
    required String projectId,
    required List<String> keys,
  }) {
    return _guard(() async {
      await _dio.delete<Map<String, dynamic>>(
        '/projects/$projectId/photos',
        data: {'keys': keys},
      );
    });
  }

  @override
  Future<String> generateModel({
    required String projectId,
    required List<String> keys,
    String? idempotencyKey,
  }) {
    return _guard(() async {
      final res = await _dio.post<Map<String, dynamic>>(
        '/projects/$projectId/photos/generate',
        data: {'keys': keys},
        options: idempotencyKey == null
            ? null
            : Options(headers: {'Idempotency-Key': idempotencyKey}),
      );
      final modelId = res.data?['modelId'];
      if (modelId is! String) {
        throw const PhotoUploadException(PhotoUploadFailure.unknown);
      }
      return modelId;
    });
  }

  /// Runs [body], translating every Dio failure into a [PhotoUploadException].
  /// The one place an envelope is read — nothing above this sees a status code.
  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on PhotoUploadException {
      rethrow;
    } on DioException catch (error) {
      throw PhotoUploadException(_failureFor(error), _messageFor(error));
    } catch (_) {
      throw const PhotoUploadException(PhotoUploadFailure.unknown);
    }
  }

  static PhotoUploadFailure _failureFor(DioException error) {
    final status = error.response?.statusCode;
    if (status == null) return PhotoUploadFailure.offline;
    final code = _codeFor(error);
    return switch (status) {
      403 => PhotoUploadFailure.forbidden,
      404 => PhotoUploadFailure.notFound,
      409 when code == 'NOT_AN_UPLOAD_PROJECT' => PhotoUploadFailure.notAnUploadProject,
      413 => PhotoUploadFailure.photoTooLarge,
      429 => PhotoUploadFailure.rateLimited,
      400 when code == 'TOO_FEW_PHOTOS' => PhotoUploadFailure.tooFewPhotos,
      _ => PhotoUploadFailure.unknown,
    };
  }

  static String? _codeFor(DioException error) {
    final data = error.response?.data;
    return data is Map ? data['code'] as String? : null;
  }

  /// The server's own sentence, when it sent the standard envelope. The server
  /// owns this copy deliberately (the auto-selection refusal, for instance, is
  /// worded there to name no pipeline internal); the fallback below is used
  /// only when there is nothing to show.
  static String? _messageFor(DioException error) {
    final data = error.response?.data;
    if (data is! Map) return null;
    final message = data['message'];
    return message is String && message.isNotEmpty ? message : null;
  }
}

/// Fallback copy when the server sent none we trust. Mapped only — never a
/// code, never raw text.
String photoUploadFallbackMessage(PhotoUploadFailure failure) => switch (failure) {
      PhotoUploadFailure.offline =>
        "You're offline — check your connection and try again.",
      PhotoUploadFailure.forbidden =>
        "Your account can't upload photos to a project.",
      PhotoUploadFailure.notFound => "We couldn't find this project.",
      PhotoUploadFailure.notAnUploadProject =>
        'This project was made for guided capture, so photos cannot be added to it.',
      PhotoUploadFailure.rateLimited =>
        'Too many requests. Please try again in a few minutes.',
      PhotoUploadFailure.photoTooLarge =>
        'Some photos were too large and were removed. Please add smaller versions.',
      PhotoUploadFailure.tooFewPhotos =>
        'Not enough photos arrived. Please add more and upload again.',
      PhotoUploadFailure.unknown => 'Something went wrong. Please try again.',
    };

/// App-wide photo-upload repository.
final projectPhotosRepositoryProvider = Provider<ProjectPhotosRepository>(
  (ref) => RemoteProjectPhotosRepository(ref.watch(dioProvider)),
);
