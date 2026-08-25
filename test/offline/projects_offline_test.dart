// test/offline/projects_offline_test.dart
//
// OFFLINE behavior of the Projects Hub, end-to-end:
//   1. Offline READ  — the list loads from the durable Hive cache (no error).
//   2. Offline CREATE — gated on connectivity: while offline a create makes NO
//      network call; it is shown optimistically (temp id + pending flag) and
//      enqueued to the durable Hive outbox, then flushed exactly once and
//      reconciled (temp id → server id) when connectivity returns.
//
// FULLY HERMETIC: real Hive gateways (`ProjectsCacheBox`/`OfflineQueueBox`) over
// a per-test temp dir; the network seam (`ProjectsRepository`) and connectivity
// (`connectivityStatusProvider`) are controllable fakes. "Offline"/"online" is
// driven by emitting on a connectivity StreamController — never slept on. The
// repo is flipped reachable/unreachable in lockstep so a flush can be made to
// succeed or fail deterministically.

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/connectivity/connectivity_providers.dart';
import 'package:recapture/application/offline/offline_queue_notifier.dart';
import 'package:recapture/application/projects/projects_notifier.dart';
import 'package:recapture/data/local/offline_queue_box.dart';
import 'package:recapture/data/local/projects_cache_box.dart';
import 'package:recapture/data/repositories/projects_repository.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/create_project_options.dart';
import 'package:recapture/domain/entities/project_source.dart';
import 'package:recapture/domain/entities/offline_action.dart';
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/domain/entities/project_status.dart';
import 'package:recapture/platform/connectivity_watcher.dart';
import '../projects/repo_fake_defaults.dart';

// ── Test doubles ──────────────────────────────────────────────────────────────

/// A network failure — what the repository raises while unreachable.
class _Offline implements Exception {
  const _Offline();
  @override
  String toString() => 'Offline (network unreachable)';
}

/// Scriptable [ProjectsRepository]. [online] gates reachability: while false,
/// `list`/`create` throw [_Offline]; while true, `create` mints a server id.
/// Records call counts + create payloads so tests can assert what reached the
/// network (and prove nothing did while offline).
class FakeProjectsRepository with FakeProjectModelDefaults implements ProjectsRepository {
  FakeProjectsRepository({this.online = false, List<Project> remote = const []})
      : _remote = List.of(remote);

  bool online;
  List<Project> _remote;

  int listCalls = 0;
  int createCalls = 0;
  final List<Map<String, dynamic>> createPayloads = [];
  int _serverSeq = 0;

  @override
  Future<List<Project>> list() async {
    listCalls++;
    if (!online) throw const _Offline();
    return List.of(_remote);
  }

  @override
  Future<Project> create({
    required String name,
    ObjectSize? size,
    CaptureMode? mode,
    String? category,
    ProjectSource source = ProjectSource.capture,
  }) async {
    createCalls++;
    createPayloads.add({'name': name, 'size': (size ?? ObjectSize.medium).apiValue, 'mode': (mode ?? CaptureMode.guided).apiValue});
    if (!online) throw const _Offline();
    final created = Project(
      id: 'srv_${++_serverSeq}',
      name: name,
      status: ProjectStatus.draft,
      updatedAt: DateTime.now(),
    );
    _remote = [created, ..._remote];
    return created;
  }

  @override
  Future<void> rename(String id, String newName) async {
    if (!online) throw const _Offline();
  }

  @override
  Future<void> delete(String id, {String? confirmName}) async {
    if (!online) throw const _Offline();
  }

  @override
  Future<void> retry(String id) async {
    if (!online) throw const _Offline();
  }
}

/// Controllable auth so building the providers never touches secure storage.
class FakeAuthNotifier extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

// ── Harness ──────────────────────────────────────────────────────────────────

typedef _Harness = ({
  ProviderContainer container,
  FakeProjectsRepository repo,
  StreamController<AppConnectivityStatus> conn,
});

/// Production-faithful container: real `ProjectsNotifier` + `OfflineQueueNotifier`
/// + real Hive gateways, with only the network seam, auth, and connectivity
/// swapped for controllable fakes. Reading `offlineQueueProvider` here builds it
/// so its connectivity auto-drain subscription is live before any emit.
_Harness _harness({required bool repoOnline, List<Project> remote = const []}) {
  final repo = FakeProjectsRepository(online: repoOnline, remote: remote);
  final conn = StreamController<AppConnectivityStatus>.broadcast();
  final container = ProviderContainer(overrides: [
    projectsRepositoryProvider.overrideWithValue(repo),
    authProvider.overrideWith(FakeAuthNotifier.new),
    connectivityStatusProvider.overrideWith((ref) => conn.stream),
  ]);
  addTearDown(container.dispose);
  addTearDown(conn.close);
  container.read(offlineQueueProvider); // build → subscribe to connectivity
  return (container: container, repo: repo, conn: conn);
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Builds the projects list, then drives connectivity offline and settles, so
/// `isOnlineProvider` reads false before an offline create. Returns the notifier.
Future<ProjectsNotifier> _bootOffline(_Harness h) async {
  await h.container.read(projectsProvider.future);
  // Keep the projects state alive so a later flush can reconcile into it.
  final sub = h.container.listen(projectsProvider, (_, __) {});
  addTearDown(sub.close);
  h.conn.add(AppConnectivityStatus.offline);
  await _settle();
  expect(h.container.read(isOnlineProvider), isFalse);
  return h.container.read(projectsProvider.notifier);
}

Project _p(String id, String name,
        {ProjectStatus status = ProjectStatus.draft}) =>
    Project(id: id, name: name, status: status, updatedAt: DateTime.utc(2026, 1, 1));

List<String> _ids(Iterable<Project> ps) => [for (final p in ps) p.id];

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('recapture_offline_test');
    Hive.init(dir.path);
  });

  tearDown(() async {
    await Hive.close(); // release box handles before touching the files
    await Hive.deleteFromDisk(); // wipe box state → isolation guaranteed
    // Best-effort temp-dir removal: on Windows the OS can still hold a box file
    // handle for a moment after close, which would make the recursive delete
    // throw. Box state is already gone, so a transient leftover dir is harmless.
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } on FileSystemException {
      /* OS still releasing the handle; the temp dir is ephemeral anyway */
    }
  });

  Future<void> simulateRestart() async {
    await Hive.close();
    Hive.init(dir.path);
  }

  // ───────────────────────────────────────────────────────────────────────────
  // OFFLINE READ — loads from the Hive cache instead of erroring.
  // ───────────────────────────────────────────────────────────────────────────
  group('offline read: project list loads from the Hive cache', () {
    test('seeded cache + offline → returns the cached projects, no error', () async {
      await ProjectsCacheBox().save([_p('a', 'Wooden Statue'), _p('b', 'Mug')]);
      final h = _harness(repoOnline: false);

      final list = await h.container.read(projectsProvider.future);
      await _settle(); // the background revalidation fails offline, silently

      expect(_ids(list), ['a', 'b']);
      final state = h.container.read(projectsProvider);
      expect(state, isA<AsyncData<List<Project>>>());
      expect(_ids(state.value!), ['a', 'b']);
      expect(h.repo.listCalls, greaterThanOrEqualTo(1)); // attempted, failed → cache won
    });

    test('offline read loads from the DURABLE cache after a restart', () async {
      await ProjectsCacheBox().save([_p('a', 'Statue'), _p('b', 'Mug')]);
      await simulateRestart();
      final h = _harness(repoOnline: false);

      final list = await h.container.read(projectsProvider.future);
      expect(_ids(list), ['a', 'b']);
      expect(h.container.read(projectsProvider), isA<AsyncData<List<Project>>>());
    });

    test('GAP: offline + EMPTY cache currently ERRORS instead of empty list', () async {
      // Documented divergence: with no cache to paint, build() falls through to
      // the (failing) network and surfaces AsyncError. The spec wants a graceful
      // empty list; that is a separate production change, not fixed here.
      final h = _harness(repoOnline: false);
      await expectLater(
        h.container.read(projectsProvider.future),
        throwsA(isA<_Offline>()),
      );
      expect(h.container.read(projectsProvider), isA<AsyncError<List<Project>>>());
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // ONLINE CREATE — baseline.
  // ───────────────────────────────────────────────────────────────────────────
  group('online create (baseline)', () {
    test('create goes to the server and is prepended (not pending)', () async {
      await ProjectsCacheBox().save([_p('a', 'Statue')]);
      final h = _harness(repoOnline: true, remote: [_p('a', 'Statue')]);
      await h.container.read(projectsProvider.future);
      await _settle();

      final created = await h.container.read(projectsProvider.notifier).create(
            name: 'New Scan',
            size: ObjectSize.small,
            mode: CaptureMode.guided,
          );

      expect(created.id, startsWith('srv_'));
      expect(created.isPending, isFalse);
      expect(h.repo.createCalls, 1);
      expect(h.container.read(projectsProvider).value!.first.id, created.id);
      // Nothing was queued — the create completed online.
      expect(await OfflineQueueBox().read(), isEmpty);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // OFFLINE CREATE — optimistic + durable outbox + reconnect flush + reconcile.
  // ───────────────────────────────────────────────────────────────────────────
  group('offline create: outbox', () {
    test('optimistic pending project (temp id) + durable enqueue, NO network call',
        () async {
      await ProjectsCacheBox().save([_p('a', 'Statue')]);
      final h = _harness(repoOnline: false);
      final notifier = await _bootOffline(h);

      final created = await notifier.create(
        name: 'Offline One',
        size: ObjectSize.medium,
        mode: CaptureMode.guided,
      );

      // Optimistic: prepended, pending, temp (non-server) id.
      expect(created.isPending, isTrue);
      expect(created.id, startsWith('pending_'));
      final list = h.container.read(projectsProvider).value!;
      expect(_ids(list), [created.id, 'a']);
      expect(list.first.isPending, isTrue);

      // NO POST while offline.
      expect(h.repo.createCalls, 0);

      // Durable outbox entry carrying the create fields.
      final queued = await OfflineQueueBox().read();
      expect(queued, hasLength(1));
      expect(queued.single.type, OfflineActionType.createProject);
      expect(queued.single.payload, {
        'tempId': created.id,
        'name': 'Offline One',
        'size': 'medium',
        'mode': 'guided',
      });
    });

    test('queued offline create survives a Hive restart', () async {
      await ProjectsCacheBox().save([_p('a', 'Statue')]);
      final h = _harness(repoOnline: false);
      final notifier = await _bootOffline(h);
      await notifier.create(name: 'Persisted', size: ObjectSize.large, mode: CaptureMode.manual);
      expect(await OfflineQueueBox().read(), hasLength(1));

      await simulateRestart();

      final after = await OfflineQueueBox().read();
      expect(after, hasLength(1));
      expect(after.single.type, OfflineActionType.createProject);
      expect(after.single.payload['name'], 'Persisted');
      expect(after.single.payload['size'], 'large');
    });

    test('reconnect flushes the create once and reconciles temp id → server id',
        () async {
      await ProjectsCacheBox().save([_p('a', 'Statue')]);
      final h = _harness(repoOnline: false);
      final notifier = await _bootOffline(h);
      final pending = await notifier.create(
        name: 'Recon',
        size: ObjectSize.small,
        mode: CaptureMode.guided,
      );
      expect(h.repo.createCalls, 0);

      // Reconnect (server now reachable) → queue auto-drains.
      h.repo.online = true;
      h.conn.add(AppConnectivityStatus.online);
      await _settle();

      // Exactly one POST, with the queued fields.
      expect(h.repo.createCalls, 1);
      expect(h.repo.createPayloads.single, {'name': 'Recon', 'size': 'small', 'mode': 'guided'});

      // Outbox drained.
      expect(await OfflineQueueBox().read(), isEmpty);
      expect(h.container.read(offlineQueueProvider).pendingCount, 0);

      // Reconciled: the temp row is replaced by the server project, pending cleared.
      final list = h.container.read(projectsProvider).value!;
      final reconciled = list.firstWhere((p) => p.name == 'Recon');
      expect(reconciled.id, startsWith('srv_'));
      expect(reconciled.isPending, isFalse);
      expect(list.any((p) => p.id == pending.id), isFalse); // temp id gone
    });

    test('multiple offline creates all queue and all flush — none lost or duplicated',
        () async {
      await ProjectsCacheBox().save([_p('a', 'Statue')]);
      final h = _harness(repoOnline: false);
      final notifier = await _bootOffline(h);
      await notifier.create(name: 'One', size: ObjectSize.small, mode: CaptureMode.guided);
      await notifier.create(name: 'Two', size: ObjectSize.small, mode: CaptureMode.guided);
      await notifier.create(name: 'Three', size: ObjectSize.small, mode: CaptureMode.guided);
      expect(await OfflineQueueBox().read(), hasLength(3));
      expect(h.repo.createCalls, 0);

      h.repo.online = true;
      h.conn.add(AppConnectivityStatus.online);
      await _settle();

      expect(h.repo.createCalls, 3); // one POST per create, none duplicated
      expect(await OfflineQueueBox().read(), isEmpty);
      final list = h.container.read(projectsProvider).value!;
      expect(list.map((p) => p.name).toSet(), containsAll({'One', 'Two', 'Three', 'Statue'}));
      expect(list.any((p) => p.isPending), isFalse); // all reconciled
    });

    test('a failed flush keeps the create queued for retry (not dropped)', () async {
      await ProjectsCacheBox().save([_p('a', 'Statue')]);
      final h = _harness(repoOnline: false);
      final notifier = await _bootOffline(h);
      await notifier.create(name: 'WillFail', size: ObjectSize.small, mode: CaptureMode.guided);

      // Connectivity returns but the server is still unreachable → flush fails.
      h.conn.add(AppConnectivityStatus.online); // repo.online stays false
      await _settle();

      expect(h.repo.createCalls, 1); // attempted
      final queued = await OfflineQueueBox().read();
      expect(queued, hasLength(1)); // RETAINED, not dropped
      expect(queued.single.attempts, 1); // bumped for the next retry
    });

    test('the offline queue can represent a project-create action', () {
      expect(OfflineActionType.values.map((t) => t.name), contains('createProject'));
      expect(OfflineActionType.createProject.analyticsValue, 'create_project');
    });
  });
}
