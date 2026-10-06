// test/offline/offline_create_reconcile_test.dart
//
// Offline capture, Step B4: when the outbox reconciles an offline-created
// project (temp `pending_…` id → server id), EVERYTHING stored under the temp
// id moves:
//   • progression box: progression / capture mode / flow variant / object size,
//     plus a durable temp → server mapping (so a capture uploaded long after
//     the flush still finds the server id and never creates a second project);
//   • capture session snapshots `'$projectId::$levelId'` (format unchanged);
//   • the resumable ActiveSession slot, when it points at the temp id;
//   • captures waiting for upload (pendingCapturesProvider).
// There is no per-PROJECT capture folder to move: a waiting capture's bundle is
// keyed by its own localId, and native frames by the capture session id.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/capture/progression/level_progression_store.dart';
import 'package:recapture/application/capture/session/capture_session_store.dart';
import 'package:recapture/application/projects/projects_notifier.dart';
import 'package:recapture/application/upload/offline_capture_capability.dart';
import 'package:recapture/application/upload/pending_captures_notifier.dart';
import 'package:recapture/data/local/active_session_box.dart';
import 'package:recapture/data/local/box_names.dart';
import 'package:recapture/data/local/pending_capture_box.dart';
import 'package:recapture/data/local/storage_providers.dart';
import 'package:recapture/data/repositories/projects_repository.dart';
import 'package:recapture/domain/capture/capture_mode.dart';
import 'package:recapture/domain/entities/active_session.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/create_project_options.dart'
    hide CaptureMode;
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/domain/entities/project_source.dart';
import 'package:recapture/domain/entities/project_status.dart';
import 'package:recapture/domain/upload/pending_capture.dart';

import '../projects/repo_fake_defaults.dart';

class _Repo with FakeProjectModelDefaults implements ProjectsRepository {
  @override
  Future<List<Project>> list() async => const [];

  @override
  Future<Project> create({
    required String name,
    ObjectSize? size,
    dynamic mode,
    String? category,
    ProjectSource source = ProjectSource.capture,
    String? idempotencyKey,
  }) async =>
      throw UnimplementedError();

  @override
  Future<void> rename(String id, String newName) async {}

  @override
  Future<void> delete(String id, {String? confirmName}) async {}

  @override
  Future<void> retry(String id) async {}
}

class _Auth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

/// The migration chain does real Hive file I/O, which microtask turns alone do
/// not drain — give it real time.
Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('reconcile_');
    Hive.init(tmp.path);
  });

  tearDown(() async {
    await Hive.close();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {/* Windows file lock — temp dir */}
  });

  test('progression store moves mode and records temp → server', () async {
    final store = LevelProgressionStore();
    await store.saveMode('pending_1', CaptureMode.meshy);

    await store.migrateProject('pending_1', 'srv_1');

    expect(await store.loadModeOrNull('srv_1'), CaptureMode.meshy);
    expect(await store.loadModeOrNull('pending_1'), isNull);
    expect(await store.reconciledIdFor('pending_1'), 'srv_1');
    expect(await store.reconciledIdFor('pending_2'), isNull);
  });

  test('session snapshots are re-keyed, others untouched', () async {
    final box = await Hive.openBox<String>(BoxNames.captureSessions);
    await box.put('pending_1::mid', jsonEncode({'x': 1}));
    await box.put('pending_1::high', jsonEncode({'x': 2}));
    await box.put('other::mid', jsonEncode({'x': 3}));

    await CaptureSessionStore().migrateProject('pending_1', 'srv_1');

    expect(box.get('srv_1::mid'), jsonEncode({'x': 1}));
    expect(box.get('srv_1::high'), jsonEncode({'x': 2}));
    expect(box.containsKey('pending_1::mid'), isFalse);
    expect(box.get('other::mid'), jsonEncode({'x': 3}));
  });

  test('reconcilePendingCreate re-keys waiting captures and the draft slot',
      () async {
    final pending = InMemoryPendingCaptureStore();
    final at = DateTime.utc(2026, 10, 1);
    await pending.put(PendingCapture(
      localId: 'cap',
      projectId: 'pending_1',
      ownerUserId: 'u1',
      projectName: 'Lamp',
      objectSize: 'medium',
      captureMode: 'meshy',
      flowVariant: 'with_bottom',
      frameCount: 6,
      byteCount: 1,
      state: PendingCaptureState.savedLocal,
      capturedAt: at,
      updatedAt: at,
      bundleRelPath: pendingBundleRelPathFor('cap'),
      perLevelCounts: const {'EYE': 6},
    ));
    final slot = ActiveSessionBox();
    await slot.save(ActiveSession(projectId: 'pending_1', updatedAt: at));

    final c = ProviderContainer(overrides: [
      pendingCaptureStoreProvider.overrideWithValue(pending),
      currentUserIdProvider.overrideWithValue('u1'),
      offlineCaptureCapabilityProvider.overrideWithValue(true),
      activeSessionBoxProvider.overrideWithValue(slot),
      projectsRepositoryProvider.overrideWithValue(_Repo()),
      authProvider.overrideWith(_Auth.new),
    ]);
    addTearDown(c.dispose);
    c.read(pendingCapturesProvider);
    await c.read(pendingCapturesProvider.notifier).whenLoaded();
    await c.read(projectsProvider.future);

    c.read(projectsProvider.notifier).reconcilePendingCreate(
          'pending_1',
          Project(
            id: 'srv_1',
            name: 'Lamp',
            status: ProjectStatus.draft,
            updatedAt: at,
          ),
        );
    // In memory at once — the upload coordinator may be awaiting this flush.
    expect(c.read(pendingCapturesProvider).single.projectId, 'srv_1');
    await _settle();

    expect((await pending.get('cap'))!.projectId, 'srv_1');
    expect((await slot.read())!.projectId, 'srv_1');
    expect(await LevelProgressionStore().reconciledIdFor('pending_1'), 'srv_1');
  });
}
