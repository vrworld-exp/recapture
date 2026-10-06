// test/upload/pending_upload_coordinator_test.dart
//
// The pending-upload coordinator (offline capture, Stage B) with fakes for the
// backend, the transfer engine, connectivity and the projects repository —
// real OfflineUploadQueue, real UploadFlowOrchestrator, real outbox notifier,
// real Hive gateways over a temp dir, real bundle files on disk.
//
// Pins: oldest-first one-at-a-time drain; network failure → waitingNetwork and
// non-network → failed; restore after a kill resumes under the SAME job key;
// userPaused is never auto-resumed; a `pending_` project waits for the outbox
// and the upload path NEVER calls backend.createProject; an auth failure stops
// the drain and keeps every record; the Wi-Fi rule holds a Full capture.
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:recapture/application/auth/auth_notifier.dart';
import 'package:recapture/application/connectivity/connectivity_providers.dart';
import 'package:recapture/application/upload/offline_capture_capability.dart';
import 'package:recapture/application/upload/pending_captures_notifier.dart';
import 'package:recapture/application/upload/pending_upload_coordinator.dart';
import 'package:recapture/application/upload/resilient_upload_runner.dart';
import 'package:recapture/application/upload/upload_flow.dart';
import 'package:recapture/application/upload/upload_jobs_backend.dart';
import 'package:recapture/application/upload/upload_prefs_provider.dart';
import 'package:recapture/application/upload/upload_progress_provider.dart';
import 'package:recapture/data/local/pending_capture_box.dart';
import 'package:recapture/data/local/storage_providers.dart';
import 'package:recapture/data/local/upload_queue_box.dart';
import 'package:recapture/data/repositories/projects_repository.dart';
import 'package:recapture/domain/entities/auth_state.dart';
import 'package:recapture/domain/entities/create_project_options.dart';
import 'package:recapture/domain/entities/project.dart';
import 'package:recapture/domain/entities/project_source.dart';
import 'package:recapture/domain/entities/project_status.dart';
import 'package:recapture/domain/entities/upload_progress.dart';
import 'package:recapture/domain/upload/auto_upload_policy.dart';
import 'package:recapture/domain/upload/capture_bundle.dart';
import 'package:recapture/domain/upload/pending_capture.dart';
import 'package:recapture/domain/upload/upload_failure.dart';
import 'package:recapture/domain/upload/upload_queue_entry.dart';
import 'package:recapture/domain/upload/upload_session_spec.dart';
import 'package:recapture/platform/connectivity_watcher.dart';

import '../projects/repo_fake_defaults.dart';

// ── fakes ─────────────────────────────────────────────────────────────────────

class FakeBackend implements UploadJobsBackend {
  int createProjectCalls = 0;
  final List<String> jobKeys = [];
  final List<String> jobProjectIds = [];
  final List<String> jobModes = [];

  @override
  Future<String> createProject({
    required String name,
    required String size,
    required String mode,
  }) async {
    createProjectCalls++;
    return 'srv_from_upload_path';
  }

  @override
  Future<CreatedUploadJob> createJob({
    required String projectId,
    required String objectSize,
    required String captureVariant,
    required int expectedFilesCount,
    required String idempotencyKey,
    String captureMode = 'full',
  }) async {
    jobKeys.add(idempotencyKey);
    jobProjectIds.add(projectId);
    jobModes.add(captureMode);
    return CreatedUploadJob(
      jobId: 'job-$idempotencyKey',
      keyPrefix: 'pref/',
      manifestKey: 'pref/capture_manifest.json',
    );
  }

  @override
  Future<String> finalizeJob({
    required String jobId,
    required int reportedFilesCount,
  }) async =>
      'QUEUED';
}

class FakeEngine implements UploadEngine, UploadProgressSource {
  FakeEngine(this._outcome, this._tracker);

  final ResilientUploadOutcome _outcome;
  final Tracker _tracker;
  final _feed = StreamController<UploadProgress>.broadcast();

  @override
  UploadProgressSource get progress => this;

  @override
  Stream<UploadProgress> watch() => _feed.stream;

  @override
  Future<ResilientUploadOutcome> run(UploadSessionSpec spec) async {
    _tracker.active++;
    if (_tracker.active > _tracker.maxActive) {
      _tracker.maxActive = _tracker.active;
    }
    await Future<void>.delayed(Duration.zero);
    _tracker.active--;
    return _outcome;
  }

  @override
  void pause() {}

  @override
  void resume() {}

  @override
  void cancel() {}
}

class Tracker {
  int active = 0;
  int maxActive = 0;
}

class FakeRepo with FakeProjectModelDefaults implements ProjectsRepository {
  int createCalls = 0;

  @override
  Future<List<Project>> list() async => const [];

  @override
  Future<Project> create({
    required String name,
    ObjectSize? size,
    CaptureMode? mode,
    String? category,
    ProjectSource source = ProjectSource.capture,
    String? idempotencyKey,
  }) async {
    createCalls++;
    return Project(
      id: 'srv_$createCalls',
      name: name,
      status: ProjectStatus.draft,
      updatedAt: DateTime.utc(2026),
    );
  }

  @override
  Future<void> rename(String id, String newName) async {}

  @override
  Future<void> delete(String id, {String? confirmName}) async {}

  @override
  Future<void> retry(String id) async {}
}

class FakeAuth extends AuthNotifier {
  @override
  AuthState build() => const AuthRestoring();
}

// ── harness ───────────────────────────────────────────────────────────────────

const ok = ResilientUploadOutcome(
    status: ResilientUploadStatus.succeeded, attemptsUsed: 1);
const netFail = ResilientUploadOutcome(
  status: ResilientUploadStatus.failed,
  attemptsUsed: 3,
  category: UploadErrorCategory.network,
);
const serverFail = ResilientUploadOutcome(
  status: ResilientUploadStatus.failed,
  attemptsUsed: 3,
  category: UploadErrorCategory.server,
);
const authFail = ResilientUploadOutcome(
  status: ResilientUploadStatus.failed,
  attemptsUsed: 1,
  category: UploadErrorCategory.auth,
);

class Harness {
  Harness(this.docs);

  final String docs;
  final store = InMemoryPendingCaptureStore();
  final queueStore = InMemoryUploadQueueStore();
  final backend = FakeBackend();
  final repo = FakeRepo();
  final tracker = Tracker();
  StateProvider<bool> online = StateProvider<bool>((ref) => true);

  /// The network the harness STARTS on (set before [start]).
  AppNetworkType initialNetwork = AppNetworkType.unmetered;
  late final network =
      StateProvider<AppNetworkType>((ref) => initialNetwork);

  /// Outcome per engine run, in order (last one repeats).
  List<ResilientUploadOutcome> outcomes = [ok];
  int _run = 0;
  late ProviderContainer container;

  PendingCapture capture(
    String id, {
    String mode = 'meshy',
    String projectId = 'srv_p',
    PendingCaptureState state = PendingCaptureState.savedLocal,
    bool userPaused = false,
    int minute = 0,
    bool writeFiles = true,
  }) {
    final at = DateTime.utc(2026, 10, 1, 9, minute);
    final c = PendingCapture(
      localId: id,
      projectId: projectId,
      ownerUserId: 'u1',
      projectName: 'Item $id',
      objectSize: 'medium',
      captureMode: mode,
      flowVariant: 'with_bottom',
      frameCount: 6,
      byteCount: 600,
      state: state,
      capturedAt: at,
      updatedAt: at,
      bundleRelPath: pendingBundleRelPathFor(id),
      perLevelCounts: const {'EYE': 6},
      userPaused: userPaused,
    );
    if (writeFiles) {
      final dir = '$docs/${c.bundleRelPath}';
      for (var i = 1; i <= 6; i++) {
        File('$dir/${bundleImageRelPath('EYE', bundleImageFileName('EYE', i))}')
          ..createSync(recursive: true)
          ..writeAsStringSync('jpg$i');
      }
      File('$dir/$kBundleManifestFileName').writeAsStringSync('{}');
    }
    return c;
  }

  Future<void> start() async {
    container = ProviderContainer(overrides: [
      pendingCaptureStoreProvider.overrideWithValue(store),
      currentUserIdProvider.overrideWithValue('u1'),
      offlineCaptureCapabilityProvider.overrideWithValue(true),
      isOnlineProvider.overrideWith((ref) => ref.watch(online)),
      currentNetworkTypeProvider.overrideWith((ref) => ref.watch(network)),
      connectivityStatusProvider
          .overrideWith((ref) => const Stream<AppConnectivityStatus>.empty()),
      autoUploadSettingsProvider.overrideWithValue(const AutoUploadSettings()),
      projectsRepositoryProvider.overrideWithValue(repo),
      authProvider.overrideWith(FakeAuth.new),
      pendingUploadDepsProvider.overrideWithValue(PendingUploadDeps(
        backend: () => backend,
        engine: (_) {
          final o = outcomes[_run < outcomes.length ? _run : outcomes.length - 1];
          _run++;
          return FakeEngine(o, tracker);
        },
        documentsDir: () async => docs,
        queueStore: queueStore,
        // Debounce passes at once; reachability re-probes never fire in a test.
        sleep: (d) => d.inMilliseconds <= 500
            ? Future<void>.value()
            : Completer<void>().future,
        observeLifecycle: false,
      )),
    ]);
    addTearDown(container.dispose);
    container.read(pendingCapturesProvider);
    container.read(pendingUploadCoordinatorProvider);
    await container.read(pendingUploadCoordinatorProvider.notifier).whenReady();
    await settle();
  }

  PendingUploadCoordinator get coordinator =>
      container.read(pendingUploadCoordinatorProvider.notifier);

  List<PendingCapture> get pending => container.read(pendingCapturesProvider);

  PendingCapture? record(String id) =>
      container.read(pendingCapturesProvider.notifier).byLocalId(id);

  Future<void> settle() async {
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await coordinator.idle;
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

void main() {
  late Directory tmp;
  late Harness h;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('pending_coord_');
    Hive.init('${tmp.path}/hive');
    h = Harness('${tmp.path}/docs');
  });

  tearDown(() async {
    await Hive.close();
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can hold a just-closed box file for a moment; the OS temp dir
      // is cleaned eventually and every test uses its own folder.
    }
  });

  test('drains oldest first, one at a time, and cleans up after QUEUED',
      () async {
    await h.store.put(h.capture('newer', minute: 5));
    await h.store.put(h.capture('older', minute: 1));

    await h.start();

    expect(h.backend.jobKeys, ['capture-older', 'capture-newer']);
    expect(h.tracker.maxActive, 1);
    expect(h.pending, isEmpty); // records removed after finalize QUEUED
    expect(Directory('${h.docs}/${pendingBundleRelPathFor('older')}').existsSync(),
        isFalse); // photos deleted only now
    expect(h.backend.jobModes, ['meshy', 'meshy']); // Meshy uploads as Meshy
  });

  test('a network failure waits for connection; a server failure fails',
      () async {
    await h.store.put(h.capture('net', minute: 1));
    h.outcomes = [netFail];
    await h.start();

    expect(h.record('net')!.state, PendingCaptureState.waitingNetwork);
    expect(Directory('${h.docs}/${pendingBundleRelPathFor('net')}').existsSync(),
        isTrue); // never deleted on failure
  });

  test('a non-network terminal failure marks the capture failed', () async {
    await h.store.put(h.capture('bad', minute: 1));
    await h.store.put(h.capture('next', minute: 2));
    h.outcomes = [serverFail, ok];
    await h.start();

    expect(h.record('bad')!.state, PendingCaptureState.failed);
    expect(h.record('bad')!.lastErrorCode, UploadErrorCategory.server.wireName);
    // One capture's failure does not block the one behind it.
    expect(h.record('next'), isNull);
  });

  test('restore after a kill resumes under the SAME job key', () async {
    // Killed mid-upload: the record says uploading, the queue job says so too.
    final c = h.capture('killed', state: PendingCaptureState.uploading);
    await h.store.put(c);
    await h.queueStore.put(UploadQueueEntry(
      jobId: 'killed',
      spec: const UploadSessionSpec(sessionId: 'killed', files: []),
      state: UploadJobState.uploading,
      seq: 0,
      attempts: 1,
    ));

    await h.start();

    // Same key → the server replays the original job → the engine resumes
    // from that job's saved part ETags (no second job, no restart from 0).
    expect(h.backend.jobKeys, [c.jobIdempotencyKey]);
    expect(h.pending, isEmpty);
  });

  test('a user-paused capture is never resumed automatically', () async {
    await h.store.put(h.capture('paused',
        state: PendingCaptureState.waitingNetwork, userPaused: true));
    await h.start();

    expect(h.backend.jobKeys, isEmpty);
    expect(h.record('paused')!.userPaused, isTrue);

    // Resume is the only way on.
    await h.coordinator.resume('paused');
    await h.settle();
    expect(h.backend.jobKeys, ['capture-paused']);
  });

  test('a pending_ project waits for the outbox; the upload path never creates '
      'a project', () async {
    await h.store.put(h.capture('offline', projectId: 'pending_42'));
    await h.start();

    expect(h.repo.createCalls, 1); // the outbox — the ONE creator
    expect(h.backend.createProjectCalls, 0); // never from the upload path
    expect(h.backend.jobProjectIds, ['srv_1']); // uploaded into the server id
    expect(h.pending, isEmpty);
  });

  test('an auth failure stops the drain and keeps every record', () async {
    await h.store.put(h.capture('first', minute: 1));
    await h.store.put(h.capture('second', minute: 2));
    h.outcomes = [authFail, ok];
    await h.start();

    expect(h.container.read(pendingUploadCoordinatorProvider).needsLogin, isTrue);
    expect(h.record('first'), isNotNull);
    expect(h.record('second'), isNotNull);
    expect(h.backend.jobKeys, ['capture-first']); // the second never started
  });

  test('on mobile data a Full capture is held, a Meshy one uploads', () async {
    h.initialNetwork = AppNetworkType.metered;
    await h.store.put(h.capture('full', mode: 'full', minute: 1));
    await h.store.put(h.capture('meshy', mode: 'meshy', minute: 2));
    await h.start();

    expect(h.backend.jobKeys, ['capture-meshy']);
    expect(h.record('full')!.state, PendingCaptureState.savedLocal);
  });

  test('Upload now on mobile data asks before sending a Full capture',
      () async {
    h.initialNetwork = AppNetworkType.metered;
    await h.store.put(h.capture('full', mode: 'full'));
    await h.start();

    expect(await h.coordinator.uploadNow('full'),
        UploadNowResult.needsMobileDataConfirm);
    await h.settle();
    expect(h.backend.jobKeys, isEmpty);

    expect(
      await h.coordinator.uploadNow('full', confirmedMobileData: true),
      UploadNowResult.started,
    );
    await h.settle();
    expect(h.backend.jobKeys, ['capture-full']);
    expect(h.pending, isEmpty);
  });

  test('a held Full capture uploads by itself when Wi-Fi returns', () async {
    h.initialNetwork = AppNetworkType.metered;
    await h.store.put(h.capture('full', mode: 'full'));
    await h.start();
    expect(h.backend.jobKeys, isEmpty);

    h.container.read(h.network.notifier).state = AppNetworkType.unmetered;
    await h.settle();
    expect(h.backend.jobKeys, ['capture-full']);
  });

  test('offline: nothing starts, and Upload now says so', () async {
    await h.store.put(h.capture('c'));
    h.online = StateProvider<bool>((ref) => false);
    await h.start();

    expect(h.backend.jobKeys, isEmpty);
    expect(await h.coordinator.uploadNow('c'), UploadNowResult.offline);
  });

  test('missing photos fail with FILES_MISSING and never retry', () async {
    await h.store.put(h.capture('gone', writeFiles: false));
    await h.start();

    expect(h.record('gone')!.state, PendingCaptureState.failed);
    expect(h.record('gone')!.lastErrorCode, PendingFailureCodes.filesMissing);
    expect(h.backend.jobKeys, isEmpty);
    expect(await h.coordinator.uploadNow('gone'), UploadNowResult.unavailable);
  });
}
