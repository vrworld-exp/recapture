// lib/data/repositories/projects_repository.dart
import '../../domain/entities/create_project_options.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/project_status.dart';

/// Data access for the Projects Hub. All projects API logic lives here — the
/// UI calls these methods and never talks to the network directly.
///
/// TODO(api): replace the stubbed bodies with real Dio calls against the
/// recapture-api `/projects` endpoints. Throw on network failure so the UI can
/// surface the offline/retry modal.
class ProjectsRepository {
  const ProjectsRepository();

  /// Fetches the user's projects. Throws on network failure.
  Future<List<Project>> fetchProjects() async {
    // TODO(api): final res = await dio.get('/projects');
    //            return (res.data as List).map((e) => Project.fromMap(e)).toList();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final now = DateTime.now();
    return [
      Project(
        id: 'p1',
        name: 'Wooden Statue',
        status: ProjectStatus.completed,
        updatedAt: now.subtract(const Duration(hours: 2)),
      ),
      Project(
        id: 'p2',
        name: 'Leather Chair',
        status: ProjectStatus.draft,
        updatedAt: now.subtract(const Duration(minutes: 20)),
      ),
      Project(
        id: 'p3',
        name: 'Coffee Mug',
        status: ProjectStatus.failed,
        updatedAt: now.subtract(const Duration(days: 1)),
      ),
      Project(
        id: 'p4',
        name: 'Ceramic Vase With An Extremely Long Name That Must Truncate Cleanly',
        status: ProjectStatus.processing,
        updatedAt: now.subtract(const Duration(minutes: 5)),
      ),
      Project(
        id: 'p5',
        name: 'Bronze Figurine',
        status: ProjectStatus.capturing,
        updatedAt: now.subtract(const Duration(minutes: 1)),
      ),
      Project(
        id: 'p6',
        name: 'Marble Bust',
        status: ProjectStatus.uploading,
        updatedAt: now.subtract(const Duration(seconds: 30)),
      ),
    ];
  }

  /// Re-submits a failed project for processing. Throws on network failure.
  Future<void> retryProject(String id) async {
    // TODO(api): await dio.post('/projects/$id/reprocess');
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  /// Renames a project. Throws on network failure.
  ///
  /// The backend returns only success here, so the caller constructs the
  /// updated [Project] locally via [Project.copyWith] (see the Projects Hub
  /// `onRename` wiring).
  Future<void> renameProject(String id, String newName) async {
    // TODO(api): await dio.patch('/projects/$id', data: {'name': newName});
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  /// Permanently deletes a project. Throws on network failure.
  Future<void> deleteProject(String id) async {
    // TODO(api): await dio.delete('/projects/$id');
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  /// Creates a new project and returns the persisted entity. Throws on network
  /// failure.
  Future<Project> createProject({
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
}
