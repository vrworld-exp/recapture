// lib/data/repositories/projects_repository.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/create_project_options.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/project_status.dart';

/// Data access for the Projects Hub. The interface `ProjectsNotifier` depends
/// on — it owns all projects HTTP and error translation, so the notifier is
/// pure state and never touches the network.
///
/// Backend reality (see recapture-api): `rename`, `delete` and `retry` return
/// success only (no entity body), so those return `void`/`Future<void>` and the
/// notifier reconciles the in-state project locally. `list` and `create` return
/// full entities.
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

  /// Permanently deletes a project. Throws on network failure.
  Future<void> delete(String id);

  /// Re-queues a failed project for processing (status returns to `processing`).
  /// Backend returns success only. Throws on network failure.
  Future<void> retry(String id);
}

/// Concrete [ProjectsRepository] backed by the recapture-api `/projects`
/// endpoints.
///
/// TODO(api): the bodies are stubbed (no central Dio client consumes
/// `dioProvider` yet — see lib/data/remote/api_client.dart). Replace each stub
/// with the real Dio call and keep error translation here. Throw on network
/// failure so the notifier/screens can surface the offline/retry modal.
class RemoteProjectsRepository implements ProjectsRepository {
  const RemoteProjectsRepository();

  @override
  Future<List<Project>> list() async {
    // TODO(api): final res = await dio.get('/projects');
    //            return (res.data as List).map((e) => Project.fromMap(e)).toList();
    // The demo-era hardcoded seed projects were removed on purpose: a fresh
    // login lands on the real empty state ("Nothing captured yet") instead of
    // fake "previously captured" cards. Real projects render once the Dio call
    // above lands; the delay keeps the loading skeleton behavior observable.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    return const <Project>[];
  }

  @override
  Future<Project> create({
    required String name,
    required ObjectSize size,
    required CaptureMode mode,
  }) async {
    // TODO(api): final res = await dio.post('/projects', data: {
    //   'name': name, 'size': size.apiValue, 'mode': mode.apiValue });
    //            return Project.fromMap(res.data as Map<String, dynamic>);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    return Project(
      id: 'p${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      status: ProjectStatus.draft,
      updatedAt: DateTime.now(),
    );
  }

  @override
  Future<void> rename(String id, String newName) async {
    // TODO(api): await dio.patch('/projects/$id', data: {'name': newName});
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  @override
  Future<void> delete(String id) async {
    // TODO(api): await dio.delete('/projects/$id');
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  @override
  Future<void> retry(String id) async {
    // TODO(api): await dio.post('/projects/$id/reprocess');
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

/// App-wide projects repository.
final projectsRepositoryProvider =
    Provider<ProjectsRepository>((ref) => const RemoteProjectsRepository());
