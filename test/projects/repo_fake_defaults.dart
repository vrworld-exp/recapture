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
    show AdminDeleteMode, AutoGenerationRequest;
import 'package:recapture/data/repositories/projects_repository.dart'
    show
        OwnerGenerationRequestOutcome,
        OwnerGenerationRequestResult,
        OwnerModelState;
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

  Future<ProjectModelView> approveModel(
          String projectId, String modelId) async =>
      throw UnimplementedError('not used here');
}

/// The SERVER-selected generation member of `LiveProjectsRepository` (the
/// "Generate 3D model" button).
///
/// Its own mixin rather than part of [FakeModelGenerationDefaults]: several
/// fakes implement the hand-picked create/list/approve members themselves and
/// so cannot mix that one in, but none of them drive this button. Two mixins
/// cannot both supply the same member, so it lives alone.
mixin FakeAutoGenerationDefaults {
  Future<AutoGenerationRequest> autoGenerateModel(
    String projectId, {
    bool force = false,
  }) async =>
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
///
/// Both default to "this project has no model and nothing is being generated"
/// — the state every pre-existing test was written against, so mixing this in
/// keeps their behaviour identical.
mixin FakeProjectModelDefaults {
  Future<ProjectModelView?> fetchModel(String id) async => null;

  Future<OwnerModelState> fetchModelState(String id) async => const OwnerModelState();

  /// "This project has produced no models" — matching the two above, so a fake
  /// that doesn't care about the models list behaves exactly as it did before
  /// the list existed.
  Future<List<ProjectModelView>> fetchModels(String id) async =>
      const <ProjectModelView>[];

  /// Throws rather than pretending to succeed: this one SPENDS MONEY, so a test
  /// that reaches it by accident must fail loudly instead of quietly recording a
  /// generation nobody meant to ask for.
  Future<OwnerGenerationRequestResult> requestModelGeneration(
    String id, {
    bool regenerate = false,
  }) async =>
      throw UnimplementedError('not used here');
}

/// The owner "Generate 3D model" press, defaulted to a plain success — for the
/// tests that need the request to go through but do not assert on it.
///
/// Kept apart from [FakeProjectModelDefaults] for the same reason
/// [FakeAutoGenerationDefaults] is: a fake cannot take two mixins that supply
/// the same member, and most fakes want the throwing default above.
mixin FakeOwnerGenerationSucceeds {
  Future<OwnerGenerationRequestResult> requestModelGeneration(
    String id, {
    bool regenerate = false,
  }) async =>
      const OwnerGenerationRequestResult(
        OwnerGenerationRequestOutcome.started,
        'Creating your 3D model.',
      );
}
