// test/projects/projects_notifier_test.dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/projects/project_capture_cleanup.dart';
import 'package:recapture/application/projects/projects_notifier.dart';
import 'package:recapture/data/local/projects_cache_box.dart';
import 'package:recapture/data/local/storage_providers.dart';
import 'package:recapture/data/repositories/projects_repository.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/create_project_options.dart';
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/domain/entities/project_status.dart';

Project _p(String id, {String? name, ProjectStatus status = ProjectStatus.draft}) {
  return Project(
    id: id,
    name: name ?? 'Project $id',
    status: status,
    updatedAt: DateTime(2026, 1, 1),
  );
}

/// Controllable in-memory projects repository.
class FakeProjectsRepository implements ProjectsRepository {
  FakeProjectsRepository(this.seed);

  List<Project> seed;
  bool failList = false;
  bool failCreate = false;
  bool failRename = false;
  bool failDelete = false;
  bool failRetry = false;

  /// Optional gates to interleave concurrent operations.
  Completer<void>? renameGate;
  Completer<void>? deleteGate;

  int listCalls = 0;
  int createCalls = 0;
  int renameCalls = 0;
  int deleteCalls = 0;
  int retryCalls = 0;

  @override
  Future<List<Project>> list() async {
    listCalls++;
    if (failList) throw Exception('list failed');
    return List<Project>.of(seed);
  }

  @override
  Future<Project> create({
    required String name,
    required ObjectSize size,
    required CaptureMode mode,
  }) async {
    createCalls++;
    if (failCreate) throw Exception('create failed');
    return _p('new', name: name, status: ProjectStatus.draft);
  }

  @override
  Future<void> rename(String id, String newName) async {
    renameCalls++;
    if (renameGate != null) await renameGate!.future;
    if (failRename) throw Exception('rename failed');
  }

  @override
  Future<void> delete(String id) async {
    deleteCalls++;
    if (deleteGate != null) await deleteGate!.future;
    if (failDelete) throw Exception('delete failed');
  }

  @override
  Future<void> retry(String id) async {
    retryCalls++;
    if (failRetry) throw Exception('retry failed');
  }
}

/// Auth notifier double that skips secure-storage restore and lets the test
/// drive auth state transitions.
class FakeAuthNotifier extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
  void emit(AuthState next) => state = next;
}

/// In-memory projects cache double.
class FakeProjectsCacheBox implements ProjectsCacheBox {
  FakeProjectsCacheBox([List<Project>? seed])
      : _stored = seed == null ? null : CachedProjects(seed, DateTime(2026));

  CachedProjects? _stored;
  int saveCount = 0;
  int clearCount = 0;

  @override
  Future<CachedProjects?> read() async => _stored;

  @override
  Future<void> save(List<Project> projects) async {
    saveCount++;
    _stored = CachedProjects(List<Project>.of(projects), DateTime(2026));
  }

  @override
  Future<void> clear() async {
    clearCount++;
    _stored = null;
  }

  List<Project> get cachedOrEmpty => _stored?.projects ?? const [];
}

/// Records which projects had their local capture data purged (Option A: the
/// notifier purges after a confirmed delete). Avoids any real MethodChannel.
class SpyCaptureCleanup implements ProjectCaptureCleanup {
  final List<String> purged = [];

  @override
  Future<void> purgeProjectCaptureData(String projectId) async {
    purged.add(projectId);
  }
}

ProviderContainer _container(
  FakeProjectsRepository repo, {
  FakeProjectsCacheBox? cache,
  ProjectCaptureCleanup? cleanup,
}) {
  final c = ProviderContainer(overrides: [
    projectsRepositoryProvider.overrideWithValue(repo),
    projectsCacheBoxProvider.overrideWithValue(cache ?? FakeProjectsCacheBox()),
    projectCaptureCleanupProvider
        .overrideWithValue(cleanup ?? SpyCaptureCleanup()),
    authProvider.overrideWith(FakeAuthNotifier.new),
  ]);
  addTearDown(c.dispose);
  return c;
}

/// Boots the provider and waits for the initial load to settle.
Future<ProviderContainer> _booted(
  FakeProjectsRepository repo, {
  FakeProjectsCacheBox? cache,
  ProjectCaptureCleanup? cleanup,
}) async {
  final c = _container(repo, cache: cache, cleanup: cleanup);
  await c.read(projectsProvider.future);
  return c;
}

List<Project> _list(ProviderContainer c) =>
    c.read(projectsProvider).valueOrNull ?? const [];

void main() {
  group('load', () {
    test('success → AsyncData with the list', () async {
      final c = await _booted(FakeProjectsRepository([_p('a'), _p('b')]));
      expect(_list(c).map((p) => p.id), ['a', 'b']);
    });

    test('empty → AsyncData([])', () async {
      final c = await _booted(FakeProjectsRepository([]));
      expect(c.read(projectsProvider), isA<AsyncData<List<Project>>>());
      expect(_list(c), isEmpty);
    });

    test('failure → AsyncError', () async {
      final repo = FakeProjectsRepository([])..failList = true;
      final c = _container(repo);
      await expectLater(c.read(projectsProvider.future), throwsException);
      expect(c.read(projectsProvider), isA<AsyncError<List<Project>>>());
    });
  });

  group('create', () {
    test('prepends the new project without a refetch', () async {
      final repo = FakeProjectsRepository([_p('a')]);
      final c = await _booted(repo);
      final created = await c.read(projectsProvider.notifier).create(
            name: 'Fresh',
            size: ObjectSize.small,
            mode: CaptureMode.guided,
          );
      expect(created.name, 'Fresh');
      expect(_list(c).map((p) => p.id), ['new', 'a']);
      expect(repo.listCalls, 1); // no refetch
    });
  });

  group('rename', () {
    test('success updates the name in place', () async {
      final c = await _booted(FakeProjectsRepository([_p('a', name: 'Old')]));
      await c.read(projectsProvider.notifier).rename('a', 'New');
      expect(_list(c).single.name, 'New');
    });

    test('failure rolls back to the original name', () async {
      final repo = FakeProjectsRepository([_p('a', name: 'Old')])
        ..failRename = true;
      final c = await _booted(repo);
      await expectLater(
        c.read(projectsProvider.notifier).rename('a', 'New'),
        throwsException,
      );
      expect(_list(c).single.name, 'Old');
    });
  });

  group('delete', () {
    test('success removes the project and purges its local capture', () async {
      final cleanup = SpyCaptureCleanup();
      final c = await _booted(
        FakeProjectsRepository([_p('a'), _p('b')]),
        cleanup: cleanup,
      );
      await c.read(projectsProvider.notifier).delete('a');
      expect(_list(c).map((p) => p.id), ['b']);
      // Option A: local capture data reclaimed on a confirmed delete.
      expect(cleanup.purged, ['a']);
    });

    test('failure restores the project and does NOT purge local capture',
        () async {
      final cleanup = SpyCaptureCleanup();
      final repo = FakeProjectsRepository([_p('a'), _p('b'), _p('c')])
        ..failDelete = true;
      final c = await _booted(repo, cleanup: cleanup);
      await expectLater(
        c.read(projectsProvider.notifier).delete('b'),
        throwsException,
      );
      expect(_list(c).map((p) => p.id), ['a', 'b', 'c']);
      // The server delete failed → local capture must be retained.
      expect(cleanup.purged, isEmpty);
    });

    test('deleting an already-gone id is a harmless no-op (still purges)',
        () async {
      final cleanup = SpyCaptureCleanup();
      final c = await _booted(FakeProjectsRepository([_p('a')]), cleanup: cleanup);
      await c.read(projectsProvider.notifier).delete('ghost');
      expect(_list(c).map((p) => p.id), ['a']);
      // The repo confirmed the (idempotent) delete, so purge runs; the native
      // purge is itself a no-op when there is no capture data.
      expect(cleanup.purged, ['ghost']);
    });
  });

  group('retry / updateStatus', () {
    test('retry flips status to processing in place', () async {
      final c = await _booted(
        FakeProjectsRepository([_p('a', status: ProjectStatus.failed)]),
      );
      await c.read(projectsProvider.notifier).retry('a');
      expect(_list(c).single.status, ProjectStatus.processing);
    });

    test('retry failure rolls back to the prior status', () async {
      final repo =
          FakeProjectsRepository([_p('a', status: ProjectStatus.failed)])
            ..failRetry = true;
      final c = await _booted(repo);
      await expectLater(
        c.read(projectsProvider.notifier).retry('a'),
        throwsException,
      );
      expect(_list(c).single.status, ProjectStatus.failed);
    });

    test('updateStatus on a missing id is a no-op (no crash)', () async {
      final c = await _booted(FakeProjectsRepository([_p('a')]));
      c.read(projectsProvider.notifier).updateStatus('ghost', ProjectStatus.completed);
      expect(_list(c).single.status, ProjectStatus.draft);
    });
  });

  group('refresh', () {
    test('success updates the list without emitting AsyncLoading', () async {
      final repo = FakeProjectsRepository([_p('a')]);
      final c = await _booted(repo);

      final emitted = <AsyncValue<List<Project>>>[];
      c.listen(projectsProvider, (_, next) => emitted.add(next));

      repo.seed = [_p('a'), _p('b')];
      await c.read(projectsProvider.notifier).refresh();

      expect(_list(c).map((p) => p.id), ['a', 'b']);
      expect(emitted.any((s) => s is AsyncLoading), isFalse);
    });

    test('failure rethrows and preserves the last good list', () async {
      final repo = FakeProjectsRepository([_p('a'), _p('b')]);
      final c = await _booted(repo);
      repo.failList = true;

      await expectLater(
        c.read(projectsProvider.notifier).refresh(),
        throwsException,
      );
      expect(_list(c).map((p) => p.id), ['a', 'b']); // not blanked
      expect(c.read(projectsProvider), isA<AsyncData<List<Project>>>());
    });
  });

  group('concurrency', () {
    test('rename B while deleting A both resolve correctly by id', () async {
      final repo = FakeProjectsRepository([_p('a'), _p('b', name: 'B')]);
      final renameGate = Completer<void>();
      final deleteGate = Completer<void>();
      repo
        ..renameGate = renameGate
        ..deleteGate = deleteGate;
      final c = await _booted(repo);
      final notifier = c.read(projectsProvider.notifier);

      final renameFuture = notifier.rename('b', 'B2');
      final deleteFuture = notifier.delete('a');

      // Resolve in reverse order to stress id-keying (not index capture).
      deleteGate.complete();
      renameGate.complete();
      await Future.wait([renameFuture, deleteFuture]);

      final list = _list(c);
      expect(list.map((p) => p.id), ['b']);
      expect(list.single.name, 'B2');
    });
  });

  group('cache (stale-while-revalidate)', () {
    test('cold start (empty cache) fetches and seeds the cache', () async {
      final cache = FakeProjectsCacheBox();
      final c = await _booted(FakeProjectsRepository([_p('a')]), cache: cache);
      expect(_list(c).map((p) => p.id), ['a']);
      expect(cache.cachedOrEmpty.map((p) => p.id), ['a']);
      expect(cache.saveCount, 1);
    });

    test('cached data paints first, then revalidates to fresh', () async {
      final cache = FakeProjectsCacheBox([_p('a')]);
      final repo = FakeProjectsRepository([_p('a'), _p('b')]);
      final c = _container(repo, cache: cache);

      // First paint is the cached list (no skeleton).
      final initial = await c.read(projectsProvider.future);
      expect(initial.map((p) => p.id), ['a']);

      // Background revalidation updates state + cache to the fresh list.
      for (var i = 0; i < 50 && _list(c).length < 2; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(_list(c).map((p) => p.id), ['a', 'b']);
      expect(cache.cachedOrEmpty.map((p) => p.id), ['a', 'b']);
    });

    test('refresh writes the fresh list to the cache', () async {
      final cache = FakeProjectsCacheBox();
      final repo = FakeProjectsRepository([_p('a')]);
      final c = await _booted(repo, cache: cache);

      repo.seed = [_p('a'), _p('b')];
      await c.read(projectsProvider.notifier).refresh();

      expect(cache.cachedOrEmpty.map((p) => p.id), ['a', 'b']);
    });

    test('mutations do NOT write the cache (only fetch/refresh do)', () async {
      final cache = FakeProjectsCacheBox();
      final c = await _booted(FakeProjectsRepository([_p('a')]), cache: cache);
      final savesAfterLoad = cache.saveCount; // 1 from cold-start fetch

      await c.read(projectsProvider.notifier).create(
            name: 'X',
            size: ObjectSize.small,
            mode: CaptureMode.guided,
          );
      await c.read(projectsProvider.notifier).rename('a', 'Renamed');

      expect(cache.saveCount, savesAfterLoad); // unchanged by mutations
    });
  });

  group('auth scoping', () {
    test('logout resets the projects state to empty', () async {
      final c = await _booted(FakeProjectsRepository([_p('a'), _p('b')]));
      expect(_list(c), isNotEmpty);

      (c.read(authProvider.notifier) as FakeAuthNotifier)
          .emit(const AuthUnauthenticated());
      await Future<void>.delayed(Duration.zero);

      expect(c.read(projectsProvider), isA<AsyncData<List<Project>>>());
      expect(_list(c), isEmpty);
    });
  });
}
