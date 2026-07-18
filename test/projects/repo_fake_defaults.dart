// test/projects/repo_fake_defaults.dart
//
// Default "not used here" bodies for the repository members a given test fake
// doesn't exercise.
//
// Why a mixin: `implements` in Dart forces EVERY member onto every fake, so
// each new repository method would otherwise mean editing every unrelated test
// file with an identical throwing stub. A fake mixes these in and overrides
// only what its test actually drives — so the next repository addition touches
// this file, not seven others.
import 'package:recapture/data/repositories/live_projects_repository.dart'
    show AdminDeleteMode;
import 'package:recapture/domain/entities/project_model.dart';

/// Model-generation members of `LiveProjectsRepository`.
mixin FakeModelGenerationDefaults {
  Future<ProjectModelView> createModel(
    String projectId,
    List<String> keys, {
    required String idempotencyKey,
  }) async =>
      throw UnimplementedError('not used here');

  Future<List<ProjectModelView>> listModels(String projectId) async =>
      throw UnimplementedError('not used here');

  Future<ProjectModelView> approveModel(String projectId, String modelId) async =>
      throw UnimplementedError('not used here');
}

/// ADMIN curation members of `LiveProjectsRepository`.
mixin FakeAdminDeleteDefaults {
  Future<void> deleteProject(
    String projectId, {
    required AdminDeleteMode mode,
    required String confirmName,
  }) async =>
      throw UnimplementedError('not used here');
}

/// Model members of `ProjectsRepository` (the owner-facing surface).
mixin FakeProjectModelDefaults {
  Future<ProjectModelView?> fetchModel(String id) async => null;
}
