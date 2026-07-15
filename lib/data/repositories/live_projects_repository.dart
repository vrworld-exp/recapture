// lib/data/repositories/live_projects_repository.dart
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/live_project.dart';
import '../remote/api_client.dart';

/// Friendly failure buckets for the staff Live-projects surface — the UI
/// renders copy per category and NEVER a raw code/URL (same mapped-only rule
/// as Screen 9F's upload categories).
enum LiveProjectsFailure {
  /// 403 — the account lost its staff role (or never had it).
  forbidden,

  /// 409 NOT_EXPORTABLE — the project has no finalized upload to export.
  notExportable,

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
        nextCursor: data['nextCursor'] is String ? data['nextCursor'] as String : null,
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

  static LiveProjectsException _translate(DioException e) {
    final status = e.response?.statusCode;
    if (status == null) {
      return const LiveProjectsException(LiveProjectsFailure.network);
    }
    if (status == 403) {
      return const LiveProjectsException(LiveProjectsFailure.forbidden);
    }
    final body = e.response?.data;
    final code = body is Map ? body['code'] : null;
    if (status == 409 && code == 'NOT_EXPORTABLE') {
      return const LiveProjectsException(LiveProjectsFailure.notExportable);
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
