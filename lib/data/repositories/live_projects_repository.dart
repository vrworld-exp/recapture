// lib/data/repositories/live_projects_repository.dart
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/live_project.dart';
import '../../domain/entities/project_model.dart';
import '../remote/api_client.dart';

/// Friendly failure buckets for the staff Live-projects surface — the UI
/// renders copy per category and NEVER a raw code/URL (same mapped-only rule
/// as Screen 9F's upload categories).
enum LiveProjectsFailure {
  /// 403 — the account lost its staff role (or never had it).
  forbidden,

  /// 409 NOT_EXPORTABLE — the project has no finalized upload to export.
  notExportable,

  /// 404 — the project is gone (already hard-deleted, or never existed).
  notFound,

  /// 422 CONFIRMATION_REQUIRED — the typed project name didn't match; the
  /// server refused without touching anything.
  confirmationMismatch,

  /// 429 — export generation rate limit; [LiveProjectsException.retryAfterSeconds]
  /// may say when to retry.
  rateLimited,

  /// Transport-level failure (offline, timeout).
  network,

  /// Anything else the server refused with.
  server,
}

/// A translated Live-projects/export failure. [failure] drives the UI copy;
/// nothing here carries raw response bodies or presigned URLs.
class LiveProjectsException implements Exception {
  const LiveProjectsException(this.failure, {this.retryAfterSeconds});

  final LiveProjectsFailure failure;
  final int? retryAfterSeconds;

  @override
  String toString() =>
      'LiveProjectsException(${failure.name}${retryAfterSeconds == null ? '' : ', retryAfter: ${retryAfterSeconds}s'})';
}

/// Data access for the staff-only Live projects surface (`/admin/*`).
/// Owns all HTTP + error translation — the notifier never touches Dio.
abstract interface class LiveProjectsRepository {
  /// One page of captured projects across all users, newest first.
  /// Throws [LiveProjectsException] on failure.
  Future<LiveProjectsPage> list({int limit, String? cursor});

  /// The export manifest for [projectId] — returned as the RAW response
  /// `export` object (the artist-facing JSON written to the share file).
  /// Throws [LiveProjectsException] (notExportable / rateLimited / …).
  Future<Map<String, dynamic>> export(String projectId);

  /// Soft-deletes the given job-root-RELATIVE [keys] (exactly as the export
  /// manifest emits them) from [projectId]'s exportable job. Returns which keys
  /// were deleted vs already missing. Throws [LiveProjectsException]
  /// (forbidden when the account is not ADMIN / notExportable / network / …).
  Future<PreviewDeleteResult> deletePhotos(String projectId, List<String> keys);

  /// Requests a Meshy AI 3D model from the 3–4 selected [keys]. Returns the
  /// QUEUED record to poll. [idempotencyKey] makes a double-tap resolve to the
  /// first request instead of a second PAID generation — always pass one.
  /// Throws [LiveProjectsException].
  Future<ProjectModelView> createModel(
    String projectId,
    List<String> keys, {
    required String idempotencyKey,
  });

  /// Presigned PUT slots for [count] EDITED model-input copies (the
  /// Prepare-Images screen). Each slot's key is job-root-relative and is
  /// accepted by [createModel] exactly like a captured photo's key. Throws
  /// [LiveProjectsException] (notExportable / rateLimited / …).
  Future<List<ModelImageUploadSlot>> requestModelImageUploads(
    String projectId,
    int count,
  );

  /// PUTs one edited JPEG to its presigned [slot]. Throws
  /// [LiveProjectsException] (network / server).
  Future<void> uploadModelImage(ModelImageUploadSlot slot, Uint8List bytes);

  /// The project's generation history, newest first. Throws
  /// [LiveProjectsException].
  Future<List<ProjectModelView>> listModels(String projectId);

  /// Marks [modelId] approved ("we're satisfied — skip manual creation").
  /// Throws [LiveProjectsException].
  Future<ProjectModelView> approveModel(String projectId, String modelId);

  /// ADMIN-only: deletes [projectId] — [AdminDeleteMode.soft] hides it
  /// (recoverable), [AdminDeleteMode.hard] permanently erases the project,
  /// its photos and its models. [confirmName] must echo the project's exact
  /// name; the server independently enforces it (confirmationMismatch).
  /// Throws [LiveProjectsException] (forbidden / notFound /
  /// confirmationMismatch / network / …).
  Future<void> deleteProject(
    String projectId, {
    required AdminDeleteMode mode,
    required String confirmName,
  });
}

/// How an admin project delete behaves — mirrors the backend's SOFT/HARD enum.
enum AdminDeleteMode {
  /// Flag-only: hidden from every list, every byte kept, restorable by the team.
  soft('SOFT'),

  /// Permanently erases the project, its photos, and its 3D models.
  hard('HARD');

  const AdminDeleteMode(this.wire);

  /// The exact value the API expects.
  final String wire;
}

/// One presigned upload slot for an edited model-input image, as
/// `POST /admin/projects/:id/model-images/upload-urls` returns it. [url] is a
/// WRITE bearer credential (short TTL) — never logged; [key] is job-root
/// relative and is what Create-Model consumes.
class ModelImageUploadSlot {
  const ModelImageUploadSlot({required this.key, required this.url});

  final String key;
  final String url;

  /// Defensive parse — a malformed row fails the whole request upstream.
  static ModelImageUploadSlot? tryFromMap(Object? raw) {
    if (raw is! Map) return null;
    final key = (raw['key'] ?? '').toString();
    final url = (raw['url'] ?? '').toString();
    if (key.isEmpty || url.isEmpty) return null;
    return ModelImageUploadSlot(key: key, url: url);
  }
}

/// Outcome of a soft-delete: the keys that were moved out vs those already gone.
class PreviewDeleteResult {
  const PreviewDeleteResult({required this.deleted, required this.missing});

  final List<String> deleted;
  final List<String> missing;
}

class RemoteLiveProjectsRepository implements LiveProjectsRepository {
  const RemoteLiveProjectsRepository(this._dio);

  final Dio _dio;

  @override
  Future<LiveProjectsPage> list({int limit = 20, String? cursor}) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '/admin/projects',
        queryParameters: {
          'limit': limit,
          if (cursor != null) 'cursor': cursor,
        },
      );
      final data = res.data ?? const {};
      final items = data['items'];
      return LiveProjectsPage(
        items: [
          if (items is List)
            for (final item in items)
              if (item is Map<String, dynamic>) LiveProject.fromMap(item),
        ],
        nextCursor:
            data['nextCursor'] is String ? data['nextCursor'] as String : null,
      );
    } on DioException catch (e) {
      throw _translate(e);
    }
  }

  @override
  Future<Map<String, dynamic>> export(String projectId) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '/admin/projects/$projectId/export',
      );
      final export = res.data?['export'];
      if (export is! Map<String, dynamic>) {
        throw const LiveProjectsException(LiveProjectsFailure.server);
      }
      return export;
    } on DioException catch (e) {
      throw _translate(e);
    }
  }

  @override
  Future<PreviewDeleteResult> deletePhotos(
    String projectId,
    List<String> keys,
  ) async {
    try {
      final res = await _dio.delete<Map<String, dynamic>>(
        '/admin/projects/$projectId/photos',
        data: {'keys': keys},
      );
      final data = res.data ?? const {};
      List<String> asStrings(Object? v) => [
            if (v is List)
              for (final e in v) e.toString(),
          ];
      return PreviewDeleteResult(
        deleted: asStrings(data['deleted']),
        missing: asStrings(data['missing']),
      );
    } on DioException catch (e) {
      throw _translate(e);
    }
  }

  @override
  Future<ProjectModelView> createModel(
    String projectId,
    List<String> keys, {
    required String idempotencyKey,
  }) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/admin/projects/$projectId/model',
        data: {'keys': keys},
        // The server's replay guard: without this a retried/double-tapped
        // request enqueues (and pays for) a second generation.
        options: Options(headers: {'Idempotency-Key': idempotencyKey}),
      );
      final model = ProjectModelView.tryFromStaffMap(res.data?['model']);
      if (model == null) {
        throw const LiveProjectsException(LiveProjectsFailure.server);
      }
      return model;
    } on DioException catch (e) {
      throw _translate(e);
    }
  }

  @override
  Future<List<ModelImageUploadSlot>> requestModelImageUploads(
    String projectId,
    int count,
  ) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/admin/projects/$projectId/model-images/upload-urls',
        data: {'count': count},
      );
      final uploads = res.data?['uploads'];
      final slots = [
        if (uploads is List)
          for (final u in uploads)
            if (ModelImageUploadSlot.tryFromMap(u) case final slot?) slot,
      ];
      // A partial slot list would strand an edited image with nowhere to go —
      // treat it as a server fault rather than uploading a subset.
      if (slots.length != count) {
        throw const LiveProjectsException(LiveProjectsFailure.server);
      }
      return slots;
    } on DioException catch (e) {
      throw _translate(e);
    }
  }

  @override
  Future<void> uploadModelImage(
      ModelImageUploadSlot slot, Uint8List bytes) async {
    // BARE Dio: the presigned URL carries its own SigV4 auth in the query, and
    // the app client's Authorization header / baseUrl would corrupt the
    // request (same reasoning as the preview download's byte fetch).
    final http = Dio();
    try {
      await http.put<void>(
        slot.url,
        data: Stream.fromIterable([bytes]),
        options: Options(
          // Content-Type is part of the presigned signature — must match the
          // server's declared image/jpeg exactly.
          contentType: 'image/jpeg',
          headers: {Headers.contentLengthHeader: bytes.length},
          validateStatus: (status) =>
              status != null && status >= 200 && status < 300,
        ),
      );
    } on DioException catch (e) {
      // S3 failures don't speak our envelope: anything with a response is a
      // server-side refusal (expired presign, signature mismatch), the rest is
      // transport.
      throw LiveProjectsException(e.response == null
          ? LiveProjectsFailure.network
          : LiveProjectsFailure.server);
    }
  }

  @override
  Future<List<ProjectModelView>> listModels(String projectId) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '/admin/projects/$projectId/models',
      );
      final models = res.data?['models'];
      return [
        if (models is List)
          for (final m in models)
            if (ProjectModelView.tryFromStaffMap(m) case final model?) model,
      ];
    } on DioException catch (e) {
      throw _translate(e);
    }
  }

  @override
  Future<ProjectModelView> approveModel(
      String projectId, String modelId) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/admin/projects/$projectId/models/$modelId/approve',
      );
      final model = ProjectModelView.tryFromStaffMap(res.data?['model']);
      if (model == null) {
        throw const LiveProjectsException(LiveProjectsFailure.server);
      }
      return model;
    } on DioException catch (e) {
      throw _translate(e);
    }
  }

  @override
  Future<void> deleteProject(
    String projectId, {
    required AdminDeleteMode mode,
    required String confirmName,
  }) async {
    try {
      await _dio.delete<Map<String, dynamic>>(
        '/admin/projects/$projectId',
        data: {'mode': mode.wire, 'confirmName': confirmName},
      );
    } on DioException catch (e) {
      throw _translate(e);
    }
  }

  static LiveProjectsException _translate(DioException e) {
    final status = e.response?.statusCode;
    if (status == null) {
      return const LiveProjectsException(LiveProjectsFailure.network);
    }
    if (status == 403) {
      return const LiveProjectsException(LiveProjectsFailure.forbidden);
    }
    if (status == 404) {
      return const LiveProjectsException(LiveProjectsFailure.notFound);
    }
    final body = e.response?.data;
    final code = body is Map ? body['code'] : null;
    if (status == 409 && code == 'NOT_EXPORTABLE') {
      return const LiveProjectsException(LiveProjectsFailure.notExportable);
    }
    if (status == 422 && code == 'CONFIRMATION_REQUIRED') {
      return const LiveProjectsException(
          LiveProjectsFailure.confirmationMismatch);
    }
    if (status == 429) {
      final retryAfter = body is Map ? body['retryAfter'] : null;
      return LiveProjectsException(
        LiveProjectsFailure.rateLimited,
        retryAfterSeconds: retryAfter is num ? retryAfter.toInt() : null,
      );
    }
    return const LiveProjectsException(LiveProjectsFailure.server);
  }
}

/// App-wide live-projects repository (staff-only surface).
final liveProjectsRepositoryProvider = Provider<LiveProjectsRepository>(
  (ref) => RemoteLiveProjectsRepository(ref.watch(dioProvider)),
);
