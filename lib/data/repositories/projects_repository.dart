// lib/data/repositories/projects_repository.dart
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/create_project_options.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/project_model.dart';
import '../remote/api_client.dart';

/// Data access for the Projects Hub. The interface `ProjectsNotifier` depends
/// on — it owns all projects HTTP and error translation, so the notifier is
/// pure state and never touches the network.
///
/// Backend reality (see recapture-api): `rename` and `delete` return
/// success-only shapes the notifier doesn't need, so those return
/// `Future<void>` and the notifier reconciles the in-state project locally.
/// `list` and `create` return full entities.
abstract interface class ProjectsRepository {
  /// Fetches the user's projects. Throws on network failure.
  Future<List<Project>> list();

  /// Creates a project and returns the persisted entity (initial status
  /// `draft`). Throws on network failure.
  Future<Project> create({
    required String name,
    required ObjectSize size,
    required CaptureMode mode,
  });

  /// Renames a project. Backend returns success only. Throws on network failure.
  Future<void> rename(String id, String newName);

  /// Soft-deletes a project. The backend independently enforces a
  /// [confirmName] echo of the project's exact current name; callers that
  /// have the entity MUST pass it (the repository falls back to one extra
  /// lookup when it is absent — rare stale-UI path).
  Future<void> delete(String id, {String? confirmName});

  /// Re-queues a failed project for processing (status returns to `processing`).
  /// Backend returns success only. Throws on network failure.
  Future<void> retry(String id);

  /// The project's newest finished 3D model, or null if it has none yet.
  ///
  /// Fetched ON DEMAND (one request when the user taps View) rather than being
  /// carried by `list()`: the Project DTO is identical across GET /projects,
  /// POST /projects and this entity by contract (AGENTS.md), so the model can't
  /// join it — and watching it per card would mean an N+1 across the whole list.
  Future<ProjectModelView?> fetchModel(String id);
}

/// Concrete [ProjectsRepository] backed by the recapture-api `/projects`
/// endpoints, over the app Dio (Bearer attach + 401-refresh via
/// [AuthInterceptor]). Non-2xx surfaces as a [DioException] — the notifier and
/// screens already translate throws into the offline/retry modal.
class RemoteProjectsRepository implements ProjectsRepository {
  const RemoteProjectsRepository(this._dio);

  final Dio _dio;

  @override
  Future<List<Project>> list() async {
    final res = await _dio.get<Map<String, dynamic>>('/projects');
    final items = res.data?['items'];
    if (items is! List) return const <Project>[];
    return [
      for (final item in items)
        if (item is Map<String, dynamic>) Project.fromMap(item),
    ];
  }

  @override
  Future<Project> create({
    required String name,
    required ObjectSize size,
    required CaptureMode mode,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/projects',
      data: {'name': name, 'size': size.apiValue, 'mode': mode.apiValue},
    );
    final project = res.data?['project'];
    if (project is! Map<String, dynamic>) {
      throw StateError('POST /projects returned no project');
    }
    return Project.fromMap(project);
  }

  @override
  Future<void> rename(String id, String newName) async {
    await _dio.patch<Map<String, dynamic>>(
      '/projects/$id',
      data: {'name': newName},
    );
  }

  @override
  Future<void> delete(String id, {String? confirmName}) async {
    // The backend refuses to delete without the exact current name — when the
    // caller couldn't supply it (stale UI), fetch it first.
    var name = confirmName;
    if (name == null) {
      final res = await _dio.get<Map<String, dynamic>>('/projects/$id');
      final project = res.data?['project'];
      name = project is Map ? (project['name'] ?? '').toString() : '';
    }
    await _dio.delete<Map<String, dynamic>>(
      '/projects/$id',
      data: {'confirmName': name},
    );
  }

  @override
  Future<void> retry(String id) async {
    // TODO(api): the backend has no reprocess route yet (FAILED → QUEUED is a
    // worker/admin concern). Keep the optimistic UI flow alive; the next list
    // refresh reconciles the real status.
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  @override
  Future<ProjectModelView?> fetchModel(String id) async {
    final res = await _dio.get<Map<String, dynamic>>('/projects/$id');
    // `model` rides alongside the project DTO and is null until a generation
    // finishes — an absent/unparsable model is "none yet", never an error.
    return ProjectModelView.tryFromOwnerMap(res.data?['model']);
  }
}

/// App-wide projects repository.
final projectsRepositoryProvider = Provider<ProjectsRepository>(
  (ref) => RemoteProjectsRepository(ref.watch(dioProvider)),
);
