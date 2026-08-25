// test/qa/folder_lifecycle/folder_lifecycle_contract_test.dart
//
// QA folder-lifecycle contract test (Step 2, grounded in reality).
//
// The task brief assumes a Dart `FolderManager`; this repo has none — folder
// management is NATIVE (`CaptureStorage.kt` / `.swift`), already unit-tested by
// 24 JVM tests in `CaptureStorageTest.kt`. See `folder_audit.md` §0.
//
// The genuinely Dart-testable surface is `CaptureStorageClient`, the MethodChannel
// transport. The existing `test/storage/capture_storage_test.dart` covers one-shot
// arg-forwarding/parsing per method. This file adds the missing angle: the
// LIFECYCLE — a single STATEFUL fake native store driven through the client across
// create → account → delete → verify-gone → orphan-sweep → guarded/partial paths →
// the traversal guard, so sequencing and state transitions are asserted end to end.
//
// Runs under `flutter test` (MethodChannel needs the Flutter binding). The brief's
// "must run under `dart test` with no binding" requirement does not apply: there is
// no pure-Dart folder logic — it lives natively. Hand-written fake only (no mockito).
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/platform/capture_storage.dart';
import 'package:recapture/utils/constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel(AppConfig.channelCaptureStorage);

  late _FakeNativeStore store;

  setUp(() {
    store = _FakeNativeStore();
    messenger.setMockMethodCallHandler(channel, store.handle);
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  CaptureStorageClient client() => CaptureStorageClient(channel);

  group('FolderLifecycle — create + account', () {
    test('a captured job is visible to the client (listProjects + usage)',
        () async {
      store.startJob('qa-001', 'job-a', frames: 12, bytes: 4800);
      store.completeJob('qa-001', 'job-a');

      expect(await client().listProjects(), contains('qa-001'));
      expect(await client().listJobs('qa-001'), ['job-a']);
      final u = await client().usage('qa-001');
      expect(u.frameCount, 12);
      expect(u.byteCount, 4800);
    });

    test('usage of a never-captured project is zero, not an error', () async {
      final u = await client().usage('qa-ghost');
      expect(u.frameCount, 0);
      expect(u.byteCount, 0);
    });

    test('listProjects is an empty list (never null) when nothing captured',
        () async {
      expect(await client().listProjects(), isEmpty);
    });
  });

  group('FolderLifecycle — interrupted job detection (orphan/crash)', () {
    test('a job started but never completed surfaces as incomplete', () async {
      store.startJob('qa-002', 'job-killed', frames: 3, bytes: 900);
      // App killed before completeJob → manifest stays in_progress.

      final jobs = await client().listIncompleteJobs();
      expect(jobs.map((j) => j.jobId), contains('job-killed'));
      expect(jobs.single.reason, 'in_progress');
    });

    test('frames with no manifest surface as no_manifest', () async {
      store.framesWithoutManifest('qa-003', 'bare', frames: 2, bytes: 600);
      final jobs = await client().listIncompleteJobs();
      expect(jobs.single.reason, 'no_manifest');
    });
  });

  group('FolderLifecycle — delete + verify gone', () {
    test('deleteProject removes the whole tree and reports what it freed',
        () async {
      store.startJob('qa-004', 'j', frames: 5, bytes: 2000);
      store.completeJob('qa-004', 'j');

      final r = await client().deleteProject('qa-004');
      expect(r.ok, isTrue);
      expect(r.filesDeleted, greaterThanOrEqualTo(5));
      expect(r.bytesFreed, 2000);
      expect(await client().listProjects(), isNot(contains('qa-004')));
    });

    test('purge is the project-deletion cleanup hook (ok then idempotent noop)',
        () async {
      store.startJob('qa-005', 'j', frames: 4, bytes: 1600);
      store.completeJob('qa-005', 'j');

      final first = await client().purgeProjectCaptureData('qa-005');
      expect(first.ok, isTrue);
      expect(first.reclaimedBytes, 1600);

      // Second purge of an already-gone project is a no-op success, never throws.
      final second = await client().purgeProjectCaptureData('qa-005');
      expect(second.isNoop, isTrue);
    });

    test('deleting one project does not touch a sibling (no contamination)',
        () async {
      store.startJob('qa-006', 'j', frames: 1, bytes: 100);
      store.completeJob('qa-006', 'j');
      store.startJob('qa-007', 'j', frames: 1, bytes: 100);
      store.completeJob('qa-007', 'j');

      await client().purgeProjectCaptureData('qa-006');

      final remaining = await client().listProjects();
      expect(remaining, isNot(contains('qa-006')));
      expect(remaining, contains('qa-007'));
      expect((await client().usage('qa-007')).frameCount, 1);
    });
  });

  group('FolderLifecycle — guards', () {
    test('purge is refused while a job in the project is active', () async {
      store.startJob('qa-008', 'live', frames: 2, bytes: 800); // not completed

      final r = await client().purgeProjectCaptureData('qa-008');
      expect(r.refusedByActiveJob, isTrue);
      expect(r.ok, isFalse);
      // Nothing was deleted out from under the in-flight capture.
      expect(await client().listProjects(), contains('qa-008'));

      // force overrides the guard.
      final forced =
          await client().purgeProjectCaptureData('qa-008', force: true);
      expect(forced.ok, isTrue);
    });

    test('a partial purge reports the surviving (locked) paths', () async {
      store.startJob('qa-009', 'j', frames: 3, bytes: 1200);
      store.completeJob('qa-009', 'j');
      store.lockOneFile('qa-009', '/recapture/qa-009/j/images/0/000002.jpg');

      final r = await client().purgeProjectCaptureData('qa-009');
      expect(r.isPartial, isTrue);
      expect(r.failed, ['/recapture/qa-009/j/images/0/000002.jpg']);
      // Project still present because the tree was not fully removed.
      expect(await client().listProjects(), contains('qa-009'));
    });
  });

  group('FolderLifecycle — orphan sweep', () {
    test('sweep purges unknown projects and keeps known ones', () async {
      for (final id in ['keep', 'orphan1', 'orphan2']) {
        store.startJob(id, 'j', frames: 1, bytes: 100);
        store.completeJob(id, 'j');
      }

      final r = await client().sweepOrphanedCaptureData(['keep']);
      expect(r.purgedProjects.toSet(), {'orphan1', 'orphan2'});
      expect(await client().listProjects(), ['keep']);
    });

    test('sweep skips an orphan with an active job (left for next time)',
        () async {
      store.startJob('busy-orphan', 'live', frames: 1, bytes: 100); // active

      final r = await client().sweepOrphanedCaptureData(<String>[]);
      expect(r.skipped, contains('busy-orphan'));
      expect(r.purgedProjects, isNot(contains('busy-orphan')));
      expect(await client().listProjects(), contains('busy-orphan'));
    });
  });

  group('FolderLifecycle — traversal guard (scenario F equivalent)', () {
    // The native StorageSegments allowlist ([A-Za-z0-9_-]{1,128}) rejects crafted
    // ids before they touch a path; the rejection surfaces to Dart as a
    // PlatformException. The client does not (and must not) silently swallow it.
    test('a path-traversal project id is rejected, nothing is purged', () async {
      store.startJob('victim', 'j', frames: 1, bytes: 100);
      store.completeJob('victim', 'j');

      await expectLater(
        client().purgeProjectCaptureData('../victim'),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'INVALID_SEGMENT')),
      );
      // The crafted id touched nothing — the real project is intact.
      expect(await client().listProjects(), contains('victim'));
    });

    test('an empty project id is rejected', () async {
      await expectLater(
        client().purgeProjectCaptureData(''),
        throwsA(isA<PlatformException>()),
      );
    });
  });
}

/// A stateful in-memory stand-in for the native `CaptureStorage` filesystem,
/// modelling `recapture/<projectId>/<jobId>` with frame counts, byte sizes,
/// active-job flags, locked files, and the same result envelopes the real
/// Kotlin/Swift managers return. Drives the client across a real lifecycle so
/// state transitions (not just single calls) are asserted.
class _FakeNativeStore {
  final Map<String, Map<String, _Job>> _projects = {};
  // Allowlist mirror of StorageSegments.require — the native traversal guard.
  static final _allowed = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  void startJob(String p, String j, {required int frames, required int bytes}) {
    final job = (_projects[p] ??= {})[j] = _Job(frames, bytes, hasManifest: true);
    job.active = true;
  }

  void completeJob(String p, String j) => _projects[p]![j]!.active = false;

  void framesWithoutManifest(String p, String j,
      {required int frames, required int bytes}) {
    (_projects[p] ??= {})[j] = _Job(frames, bytes, hasManifest: false)
      ..active = false;
  }

  void lockOneFile(String p, String path) =>
      _projects[p]!.values.first.lockedPath = path;

  bool _projectActive(String p) =>
      _projects[p]?.values.any((j) => j.active) ?? false;

  int _frames(String p) =>
      _projects[p]?.values.fold(0, (a, j) => a! + j.frames) ?? 0;
  int _bytes(String p) =>
      _projects[p]?.values.fold(0, (a, j) => a! + j.bytes) ?? 0;

  void _requireValid(String? id) {
    if (id == null || !_allowed.hasMatch(id)) {
      throw PlatformException(
          code: 'INVALID_SEGMENT', message: 'Invalid projectId');
    }
  }

  Future<Object?> handle(MethodCall call) async {
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'freeSpace':
        return 5 * 1024 * 1024 * 1024;
      case 'listProjects':
        return _projects.keys.toList()..sort();
      case 'listJobs':
        return (_projects[args['projectId']]?.keys.toList() ?? <String>[])
          ..sort();
      case 'usage':
        final p = args['projectId'] as String;
        return {'frameCount': _frames(p), 'byteCount': _bytes(p)};
      case 'listIncompleteJobs':
        final out = <Map<String, Object?>>[];
        _projects.forEach((p, jobs) {
          jobs.forEach((j, job) {
            if (!job.hasManifest && job.frames > 0) {
              out.add({'projectId': p, 'jobId': j, 'reason': 'no_manifest'});
            } else if (job.active) {
              out.add({'projectId': p, 'jobId': j, 'reason': 'in_progress'});
            }
          });
        });
        return out;
      case 'deleteProject':
        final p = args['projectId'] as String;
        _requireValid(p);
        final force = args['force'] as bool? ?? false;
        if (!force && _projectActive(p)) {
          return {'ok': false, 'code': 'active_job', 'filesDeleted': 0, 'bytesFreed': 0};
        }
        final files = _frames(p), freed = _bytes(p);
        if (!_projects.containsKey(p)) {
          return {'ok': true, 'code': 'not_found', 'filesDeleted': 0, 'bytesFreed': 0};
        }
        _projects.remove(p);
        return {'ok': true, 'code': 'ok', 'filesDeleted': files, 'bytesFreed': freed};
      case 'deleteJob':
        final p = args['projectId'] as String, j = args['jobId'] as String;
        _requireValid(p);
        final job = _projects[p]?[j];
        if (job != null && job.active && !(args['force'] as bool? ?? false)) {
          return {'ok': false, 'code': 'active_job', 'filesDeleted': 0, 'bytesFreed': 0};
        }
        _projects[p]?.remove(j);
        return {'ok': true, 'code': 'ok', 'filesDeleted': job?.frames ?? 0, 'bytesFreed': job?.bytes ?? 0};
      case 'purgeProjectCaptureData':
        return _purge(args['projectId'] as String, args['force'] as bool? ?? false);
      case 'sweepOrphanedCaptureData':
        final known =
            (args['knownProjectIds'] as List?)?.cast<String>().toSet() ?? {};
        final force = args['force'] as bool? ?? false;
        final purged = <String>[], skipped = <String>[];
        var bytes = 0;
        for (final p in _projects.keys.toList()) {
          if (known.contains(p)) continue;
          final res = _purge(p, force);
          switch (res['status']) {
            case 'ok':
              purged.add(p);
              bytes += res['reclaimedBytes'] as int;
            case 'partial':
              purged.add(p);
              skipped.add(p);
              bytes += res['reclaimedBytes'] as int;
            case 'refused':
              skipped.add(p);
          }
        }
        return {'purgedProjects': purged, 'reclaimedBytes': bytes, 'skipped': skipped};
      default:
        throw MissingPluginException('no fake for ${call.method}');
    }
  }

  Map<String, Object?> _purge(String p, bool force) {
    _requireValid(p);
    if (!force && _projectActive(p)) {
      return {'status': 'refused', 'reclaimedBytes': 0, 'failed': <String>[]};
    }
    if (!_projects.containsKey(p)) {
      return {'status': 'noop', 'reclaimedBytes': 0, 'failed': <String>[]};
    }
    final locked = _projects[p]!
        .values
        .map((j) => j.lockedPath)
        .whereType<String>()
        .toList();
    final freed = _bytes(p);
    if (locked.isNotEmpty && !force) {
      // Partial: locked files survive; the tree (and project) is not removed.
      return {'status': 'partial', 'reclaimedBytes': freed, 'failed': locked};
    }
    _projects.remove(p);
    return {'status': 'ok', 'reclaimedBytes': freed, 'failed': <String>[]};
  }
}

class _Job {
  _Job(this.frames, this.bytes, {required this.hasManifest});
  final int frames;
  final int bytes;
  final bool hasManifest;
  bool active = false;
  String? lockedPath;
}
