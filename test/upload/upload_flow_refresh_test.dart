// test/upload/upload_flow_refresh_test.dart
//
// P7-A post-upload visibility: the upload flow's terminal `completed`
// (finalize confirmed QUEUED) must trigger a projectsProvider refresh so the
// upload-created remote project appears on All Projects without a restart —
// and ONLY the success terminal does (failed/cancelled create no project).
// Hermetic: fake repository/cache/auth; the flow surface is driven directly
// through the notifier's test seam (no orchestrator, no network/Hive).
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/projects/projects_notifier.dart';
import 'package:recapture/application/upload/upload_flow.dart';
import 'package:recapture/data/local/projects_cache_box.dart';
import 'package:recapture/data/local/storage_providers.dart';
import 'package:recapture/data/repositories/projects_repository.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/create_project_options.dart';
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/domain/entities/project_status.dart';
import 'package:recapture/domain/upload/upload_failure.dart';

class _CountingProjectsRepository implements ProjectsRepository {
  int listCalls = 0;

  @override
  Future<List<Project>> list() async {
    listCalls++;
    return const <Project>[];
  }

  @override
  Future<Project> create({
    required String name,
    required ObjectSize size,
    required CaptureMode mode,
  }) async =>
      Project(
        id: 'p1',
        name: name,
        status: ProjectStatus.draft,
        updatedAt: DateTime(2026),
      );

  @override
  Future<void> rename(String id, String newName) async {}

  @override
  Future<void> delete(String id, {String? confirmName}) async {}

  @override
  Future<void> retry(String id) async {}
}

class _FakeCacheBox implements ProjectsCacheBox {
  @override
  Future<CachedProjects?> read() async => null;

  @override
  Future<void> save(List<Project> projects) async {}

  @override
  Future<void> clear() async {}
}

class _FakeAuthNotifier extends AuthNotifier {
  @override
  AuthState build() => const AuthUnauthenticated();
}

Future<void> _pump() async {
  // Let the stream event, the refresh() future, and its state write settle.
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _CountingProjectsRepository repo;
  late ProviderContainer container;

  setUp(() async {
    repo = _CountingProjectsRepository();
    container = ProviderContainer(overrides: [
      projectsRepositoryProvider.overrideWithValue(repo),
      projectsCacheBoxProvider.overrideWithValue(_FakeCacheBox()),
      authProvider.overrideWith(_FakeAuthNotifier.new),
    ]);
    // Initialize the projects list (cold load = 1 repo call).
    await container.read(projectsProvider.future);
    expect(repo.listCalls, 1);
  });

  tearDown(() => container.dispose());

  test('terminal completed triggers exactly one projects refresh', () async {
    final progress = UploadFlowProgress();
    container.read(uploadFlowProvider.notifier).installForTest(progress);

    progress.markRunning();
    await _pump();
    expect(repo.listCalls, 1, reason: 'no refresh before the terminal state');

    progress.markCompleted();
    await _pump();
    expect(repo.listCalls, 2, reason: 'completed → refresh');

    await _pump();
    expect(repo.listCalls, 2, reason: 'no duplicate refresh');
  });

  test('terminal failure does NOT refresh', () async {
    final progress = UploadFlowProgress();
    container.read(uploadFlowProvider.notifier).installForTest(progress);

    progress.markRunning();
    progress.fail(const UploadFlowFailure(UploadErrorCategory.server));
    await _pump();

    expect(repo.listCalls, 1);
  });

  test('cancel does NOT refresh', () async {
    final progress = UploadFlowProgress();
    container.read(uploadFlowProvider.notifier).installForTest(progress);

    progress.markRunning();
    progress.markCancelled();
    await _pump();

    expect(repo.listCalls, 1);
  });
}
