// test/platform/capture_port_contract_test.dart
//
// The port CONTRACT, run against two implementations so a difference between
// them fails here rather than on a phone.
//
// The two implementations are:
//   • the channel-backed native ports, driven through mocked platform channels
//     that model a small in-memory capture tree — i.e. the real Dart code path
//     Android and iOS take, with the native side faked;
//   • an in-memory port that mirrors the web ports' semantics (opaque handles,
//     scoped keys, the active-job guard).
//
// The web ports themselves need a browser, so they cannot run on the VM. What
// CAN be pinned here is the contract they are written against — and that is
// where the divergences that matter live: a handle that comes back empty, a
// timestamp of 0, usage that does not add up, a delete that quietly ignores an
// active job and takes a user's photos out from under a running capture.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/platform/capture_ports/capture_storage_port.dart';
import 'package:recapture/platform/capture_ports/still_capture_port.dart';
import 'package:recapture/platform/capture_storage.dart';
import 'package:recapture/platform/method_channels.dart';
import 'package:recapture/utils/constants.dart';

/// The shared model both implementations are driven against: one project, one
/// job, one level, three frames.
const _projectId = 'p1';
const _jobId = 'j1';
const _level = 'EYE';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── still capture ─────────────────────────────────────────────────────────

  group('StillCapturePort contract', () {
    _runStillCaptureContract(
      'native (mocked capture channel)',
      () => _NativeStillCaptureHarness(),
    );
    _runStillCaptureContract(
      'in-memory (web-shaped handles)',
      () => _InMemoryStillCaptureHarness(),
    );
  });

  // ── capture storage ───────────────────────────────────────────────────────

  group('CaptureStoragePort contract', () {
    _runStorageContract(
      'native (mocked capture_storage channel)',
      () => _NativeStorageHarness(),
    );
    _runStorageContract(
      'in-memory (web-shaped IndexedDB semantics)',
      () => _InMemoryStorageHarness(),
    );
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Still capture
// ─────────────────────────────────────────────────────────────────────────────

abstract class _StillCaptureHarness {
  Future<void> setUp();
  Future<void> tearDown();

  /// The port under test, exercised through the public wrapper so the contract
  /// covers the code the app actually calls.
  CaptureChannel get channel;
}

void _runStillCaptureContract(
  String label,
  _StillCaptureHarness Function() create,
) {
  group(label, () {
    late _StillCaptureHarness harness;

    setUp(() async {
      harness = create();
      await harness.setUp();
    });
    tearDown(() => harness.tearDown());

    test('a capture returns a non-empty handle and a non-zero timestamp',
        () async {
      final frame = await harness.channel.captureSingle();
      expect(frame, isNotNull);
      // The handle is opaque — a filesystem path natively, an `idb://…` handle
      // on web — but it must never be blank, because it is the only way the
      // ledger, the review grid and the uploader can find the photo again.
      expect(frame!.path, isNotEmpty);
      expect(frame.id, isNotEmpty);
      // A zero timestamp would silently break sensor/frame alignment.
      expect(frame.timestampNs, isNonZero);
    });

    test('successive captures produce distinct handles', () async {
      final a = await harness.channel.captureSingle();
      final b = await harness.channel.captureSingle();
      expect(a!.path, isNot(b!.path));
      expect(a.id, isNot(b.id));
    });

    test('timestamps are monotonically non-decreasing', () async {
      final a = await harness.channel.captureSingle();
      final b = await harness.channel.captureSingle();
      expect(b!.timestampNs, greaterThanOrEqualTo(a!.timestampNs));
    });

    test('a staged resolution policy is accepted and reported back', () async {
      const policy = CaptureResolutionPolicy(
        aspectRatio: CaptureAspectRatio.ratio16x9,
        jpegQuality: 90,
      );
      expect(await harness.channel.configureCaptureResolution(policy), isTrue);
      final active = await harness.channel.getActiveCaptureResolution();
      expect(active, isNotNull);
      expect(active!.jpegQuality, 90);
      expect(active.aspectRatio, CaptureAspectRatio.ratio16x9);
    });

    test('an out-of-range JPEG quality is rejected, leaving the prior policy',
        () async {
      expect(
        await harness.channel.configureCaptureResolution(
          const CaptureResolutionPolicy(jpegQuality: 0),
        ),
        isFalse,
      );
    });
  });
}

class _NativeStillCaptureHarness implements _StillCaptureHarness {
  static const _channel = MethodChannel(AppConfig.channelCapture);

  int _seq = 0;
  int _quality = 90;
  String _aspect = CaptureAspectRatio.ratio4x3.wire;

  @override
  CaptureChannel get channel => CaptureChannel();

  @override
  Future<void> setUp() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      switch (call.method) {
        case 'captureSingle':
          final n = _seq++;
          return <String, Object?>{
            'id': 'frame_$n',
            'path': '/data/captures/session/frame_$n.jpg',
            'timestampNs': 1000000000 + n,
          };
        case 'configureCaptureResolution':
          final args = (call.arguments as Map).cast<String, Object?>();
          final q = (args['jpegQuality'] as num?)?.toInt() ?? 0;
          if (q < 1 || q > 100) {
            throw PlatformException(code: 'INVALID_ARGS');
          }
          _quality = q;
          _aspect = args['aspectRatio'] as String? ?? _aspect;
          return <String, Object?>{'accepted': true};
        case 'getActiveCaptureResolution':
          return <String, Object?>{
            'width': 1920,
            'height': 1080,
            'jpegQuality': _quality,
            'aspectRatio': _aspect,
            'fellBack': false,
            'bound': true,
          };
        default:
          return null;
      }
    });
  }

  @override
  Future<void> tearDown() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}

/// Mirrors the web still-capture port: opaque `idb://` handles, a
/// `performance.now()`-shaped timestamp, and the same policy validation.
class _InMemoryStillCapturePort implements StillCapturePort {
  int _seq = 0;
  CaptureResolutionPolicy _policy = const CaptureResolutionPolicy();

  @override
  Future<CapturedFrame?> captureSingle() async {
    final n = _seq++;
    final timestampNs = 2000000000 + n;
    return CapturedFrame(
      id: 'web_${timestampNs}_$n',
      path: 'idb://$_projectId/$_jobId/$_level/web_${timestampNs}_$n.jpg',
      timestampNs: timestampNs,
    );
  }

  @override
  Future<bool> configureCaptureResolution(
    CaptureResolutionPolicy policy,
  ) async {
    if (policy.jpegQuality < 1 || policy.jpegQuality > 100) return false;
    _policy = policy;
    return true;
  }

  @override
  Future<ActiveCaptureResolution?> getActiveCaptureResolution() async =>
      ActiveCaptureResolution(
        width: 1920,
        height: 1080,
        jpegQuality: _policy.jpegQuality,
        aspectRatio: _policy.aspectRatio,
        fellBack: false,
        bound: true,
      );

  @override
  Future<String?> startBurst(int count, {int? intervalMs}) async => null;

  @override
  Future<String?> startAutoCapture({int? intervalMs}) async => null;

  @override
  Future<void> stopAutoCapture() async {}

  @override
  Stream<CaptureEvent> events() => const Stream<CaptureEvent>.empty();
}

class _InMemoryStillCaptureHarness implements _StillCaptureHarness {
  final _port = _InMemoryStillCapturePort();

  @override
  CaptureChannel get channel => _PortBackedCaptureChannel(_port);

  @override
  Future<void> setUp() async {}

  @override
  Future<void> tearDown() async {}
}

/// Drives the same public surface as [CaptureChannel] over an injected port,
/// so both sides of the contract are exercised through identical call shapes.
class _PortBackedCaptureChannel implements CaptureChannel {
  _PortBackedCaptureChannel(this._port);

  final StillCapturePort _port;

  @override
  Future<CapturedFrame?> captureSingle() => _port.captureSingle();

  @override
  Future<bool> configureCaptureResolution(CaptureResolutionPolicy policy) =>
      _port.configureCaptureResolution(policy);

  @override
  Future<ActiveCaptureResolution?> getActiveCaptureResolution() =>
      _port.getActiveCaptureResolution();

  @override
  Future<String?> startAutoCapture({int? intervalMs}) =>
      _port.startAutoCapture(intervalMs: intervalMs);

  @override
  Future<String?> startBurst(int count, {int? intervalMs}) =>
      _port.startBurst(count, intervalMs: intervalMs);

  @override
  Future<void> stopAutoCapture() => _port.stopAutoCapture();
}

// ─────────────────────────────────────────────────────────────────────────────
// Capture storage
// ─────────────────────────────────────────────────────────────────────────────

abstract class _StorageHarness {
  Future<void> setUp();
  Future<void> tearDown();

  CaptureStorageClient get client;

  /// Marks the job active (what the delete guard consults).
  Future<void> setActive(bool active);
}

void _runStorageContract(String label, _StorageHarness Function() create) {
  group(label, () {
    late _StorageHarness harness;

    setUp(() async {
      harness = create();
      await harness.setUp();
    });
    tearDown(() => harness.tearDown());

    test('usage accounts for every frame in scope', () async {
      final project = await harness.client.usage(_projectId);
      expect(project.frameCount, 3);
      expect(project.byteCount, 300);

      final job = await harness.client.usage(_projectId, jobId: _jobId);
      expect(job.frameCount, 3);

      final level =
          await harness.client.usage(_projectId, jobId: _jobId, level: _level);
      expect(level.frameCount, 3);
      expect(level.byteCount, 300);
    });

    test('usage for an unknown project is zero, not an error', () async {
      final usage = await harness.client.usage('nope');
      expect(usage.frameCount, 0);
      expect(usage.byteCount, 0);
    });

    test('listing surfaces the project and its job', () async {
      expect(await harness.client.listProjects(), contains(_projectId));
      expect(await harness.client.listJobs(_projectId), contains(_jobId));
    });

    test('a job with no manifest is reported incomplete', () async {
      final incomplete = await harness.client.listIncompleteJobs();
      expect(incomplete, isNotEmpty);
      expect(incomplete.first.projectId, _projectId);
      expect(incomplete.first.jobId, _jobId);
    });

    test('an idle job deletes cleanly and reports what it freed', () async {
      final result = await harness.client.deleteJob(_projectId, _jobId);
      expect(result.ok, isTrue);
      expect(result.guardedByActiveJob, isFalse);
      expect(result.filesDeleted, 3);
      expect(result.bytesFreed, 300);
      expect((await harness.client.usage(_projectId)).frameCount, 0);
    });

    test('THE ACTIVE-JOB GUARD: a delete during capture is refused', () async {
      await harness.setActive(true);
      final result = await harness.client.deleteProject(_projectId);
      expect(result.ok, isFalse);
      expect(result.code, 'active_job');
      expect(result.guardedByActiveJob, isTrue);
      // Nothing was taken out from under the running capture.
      expect((await harness.client.usage(_projectId)).frameCount, 3);
    });

    test('force overrides the guard', () async {
      await harness.setActive(true);
      final result =
          await harness.client.deleteProject(_projectId, force: true);
      expect(result.ok, isTrue);
      expect((await harness.client.usage(_projectId)).frameCount, 0);
    });

    test('purge is refused while a job is active', () async {
      await harness.setActive(true);
      final result = await harness.client.purgeProjectCaptureData(_projectId);
      expect(result.refusedByActiveJob, isTrue);
      expect(result.reclaimedBytes, 0);
    });

    test('purge removes the tree and reports the bytes reclaimed', () async {
      final result = await harness.client.purgeProjectCaptureData(_projectId);
      expect(result.ok, isTrue);
      expect(result.reclaimedBytes, 300);
    });

    test('purging a project with no data is a noop, not an ok', () async {
      final result = await harness.client.purgeProjectCaptureData('gone');
      expect(result.isNoop, isTrue);
      expect(result.ok, isFalse);
    });

    test('the orphan sweep keeps known projects and purges the rest', () async {
      final kept = await harness.client.sweepOrphanedCaptureData(<String>[
        _projectId,
      ]);
      expect(kept.purgedProjects, isEmpty);
      expect((await harness.client.usage(_projectId)).frameCount, 3);

      final swept = await harness.client.sweepOrphanedCaptureData(<String>[]);
      expect(swept.purgedProjects, contains(_projectId));
      expect((await harness.client.usage(_projectId)).frameCount, 0);
    });
  });
}

/// The in-memory capture tree both harnesses are built on, so the two
/// implementations are answering questions about the SAME data.
class _FakeTree {
  final Map<String, int> frames = <String, int>{
    'idb://$_projectId/$_jobId/$_level/f1.jpg': 100,
    'idb://$_projectId/$_jobId/$_level/f2.jpg': 100,
    'idb://$_projectId/$_jobId/$_level/f3.jpg': 100,
  };
  bool active = false;
  bool manifestComplete = false;

  Iterable<String> keysFor(String projectId, {String? jobId, String? level}) {
    final prefix = <String>[
      projectId,
      if (jobId != null) jobId,
      if (level != null) level,
    ].join('/');
    return frames.keys.where((k) => k.startsWith('idb://$prefix/'));
  }

  ({int files, int bytes}) delete(
    String projectId, {
    String? jobId,
    String? level,
  }) {
    final keys = keysFor(projectId, jobId: jobId, level: level).toList();
    var bytes = 0;
    for (final k in keys) {
      bytes += frames.remove(k) ?? 0;
    }
    return (files: keys.length, bytes: bytes);
  }

  bool hasProject(String projectId) => keysFor(projectId).isNotEmpty;
}

class _NativeStorageHarness implements _StorageHarness {
  static const _channel = MethodChannel(AppConfig.channelCaptureStorage);

  final _tree = _FakeTree();

  @override
  CaptureStorageClient get client => CaptureStorageClient();

  @override
  Future<void> setActive(bool active) async => _tree.active = active;

  @override
  Future<void> setUp() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      final args = (call.arguments as Map?)?.cast<String, Object?>() ??
          const <String, Object?>{};
      final projectId = args['projectId'] as String? ?? '';
      final jobId = args['jobId'] as String?;
      final level = args['level'] as String?;
      final force = args['force'] as bool? ?? false;

      switch (call.method) {
        case 'freeSpace':
          return 1024 * 1024 * 1024;
        case 'usage':
          final keys = _tree.keysFor(projectId, jobId: jobId, level: level);
          return <Object?, Object?>{
            'frameCount': keys.length,
            'byteCount': keys.fold<int>(0, (a, k) => a + _tree.frames[k]!),
          };
        case 'listProjects':
          return <String>[if (_tree.hasProject(_projectId)) _projectId];
        case 'listJobs':
          return <String>[if (_tree.hasProject(projectId)) _jobId];
        case 'listIncompleteJobs':
          if (_tree.manifestComplete || !_tree.hasProject(_projectId)) {
            return <Object?>[];
          }
          return <Object?>[
            <Object?, Object?>{
              'projectId': _projectId,
              'jobId': _jobId,
              'reason': _tree.active ? 'in_progress' : 'no_manifest',
            },
          ];
        case 'deleteLevel':
        case 'deleteJob':
        case 'deleteProject':
          if (!force && _tree.active && _tree.hasProject(projectId)) {
            return <Object?, Object?>{
              'ok': false,
              'code': 'active_job',
              'filesDeleted': 0,
              'bytesFreed': 0,
            };
          }
          final deleted = _tree.delete(
            projectId,
            jobId: call.method == 'deleteProject' ? null : jobId,
            level: call.method == 'deleteLevel' ? level : null,
          );
          return <Object?, Object?>{
            'ok': true,
            'code': 'ok',
            'filesDeleted': deleted.files,
            'bytesFreed': deleted.bytes,
          };
        case 'purgeProjectCaptureData':
          if (!force && _tree.active && _tree.hasProject(projectId)) {
            return <Object?, Object?>{
              'status': 'refused',
              'reclaimedBytes': 0,
            };
          }
          final purged = _tree.delete(projectId);
          return <Object?, Object?>{
            'status': purged.files == 0 ? 'noop' : 'ok',
            'reclaimedBytes': purged.bytes,
          };
        case 'sweepOrphanedCaptureData':
          final known =
              (args['knownProjectIds'] as List?)?.whereType<String>().toSet() ??
                  const <String>{};
          if (known.contains(_projectId) || !_tree.hasProject(_projectId)) {
            return <Object?, Object?>{
              'purgedProjects': <String>[],
              'reclaimedBytes': 0,
              'skipped': <String>[],
            };
          }
          if (_tree.active && !force) {
            return <Object?, Object?>{
              'purgedProjects': <String>[],
              'reclaimedBytes': 0,
              'skipped': <String>[_projectId],
            };
          }
          final swept = _tree.delete(_projectId);
          return <Object?, Object?>{
            'purgedProjects': <String>[_projectId],
            'reclaimedBytes': swept.bytes,
            'skipped': <String>[],
          };
        default:
          return null;
      }
    });
  }

  @override
  Future<void> tearDown() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}

/// Mirrors the web storage port's semantics over the same tree.
class _InMemoryStoragePort implements CaptureStoragePort {
  _InMemoryStoragePort(this._tree);

  final _FakeTree _tree;

  @override
  Future<int> freeSpaceBytes() async => 1024 * 1024 * 1024;

  @override
  Future<StorageUsage> usage(
    String projectId, {
    String? jobId,
    String? level,
  }) async {
    final keys = _tree.keysFor(projectId, jobId: jobId, level: level);
    return StorageUsage(
      frameCount: keys.length,
      byteCount: keys.fold<int>(0, (a, k) => a + _tree.frames[k]!),
    );
  }

  @override
  Future<List<String>> listProjects() async =>
      <String>[if (_tree.hasProject(_projectId)) _projectId];

  @override
  Future<List<String>> listJobs(String projectId) async =>
      <String>[if (_tree.hasProject(projectId)) _jobId];

  @override
  Future<List<IncompleteJob>> listIncompleteJobs() async {
    if (_tree.manifestComplete || !_tree.hasProject(_projectId)) {
      return const [];
    }
    return <IncompleteJob>[
      IncompleteJob(
        projectId: _projectId,
        jobId: _jobId,
        reason: _tree.active ? 'in_progress' : 'no_manifest',
      ),
    ];
  }

  @override
  Future<StorageDeleteResult> deleteLevel(
    String projectId,
    String jobId,
    String level, {
    bool force = false,
  }) =>
      _guarded(projectId, force,
          () => _tree.delete(projectId, jobId: jobId, level: level));

  @override
  Future<StorageDeleteResult> deleteJob(
    String projectId,
    String jobId, {
    bool force = false,
  }) =>
      _guarded(projectId, force, () => _tree.delete(projectId, jobId: jobId));

  @override
  Future<StorageDeleteResult> deleteProject(
    String projectId, {
    bool force = false,
  }) =>
      _guarded(projectId, force, () => _tree.delete(projectId));

  @override
  Future<PurgeResult> purgeProjectCaptureData(
    String projectId, {
    bool force = false,
  }) async {
    if (!force && _tree.active && _tree.hasProject(projectId)) {
      return const PurgeResult(status: 'refused', reclaimedBytes: 0);
    }
    final purged = _tree.delete(projectId);
    return PurgeResult(
      status: purged.files == 0 ? 'noop' : 'ok',
      reclaimedBytes: purged.bytes,
    );
  }

  @override
  Future<SweepResult> sweepOrphanedCaptureData(
    List<String> knownProjectIds, {
    bool force = false,
  }) async {
    final known = knownProjectIds.toSet();
    if (known.contains(_projectId) || !_tree.hasProject(_projectId)) {
      return const SweepResult();
    }
    final result = await purgeProjectCaptureData(_projectId, force: force);
    if (!result.ok) {
      return SweepResult(skipped: <String>[_projectId]);
    }
    return SweepResult(
      purgedProjects: <String>[_projectId],
      reclaimedBytes: result.reclaimedBytes,
    );
  }

  @override
  void setActiveScope({
    required String projectId,
    required String jobId,
    required String level,
  }) {}

  @override
  Future<void> setJobActive(
    String projectId,
    String jobId, {
    required bool active,
  }) async =>
      _tree.active = active;

  @override
  Future<void> markJobComplete(String projectId, String jobId) async =>
      _tree.manifestComplete = true;

  @override
  Future<Uint8List?> readFrameBytes(String path) async =>
      _tree.frames.containsKey(path) ? Uint8List(_tree.frames[path]!) : null;

  Future<StorageDeleteResult> _guarded(
    String projectId,
    bool force,
    ({int files, int bytes}) Function() delete,
  ) async {
    if (!force && _tree.active && _tree.hasProject(projectId)) {
      return const StorageDeleteResult(
        ok: false,
        code: 'active_job',
        filesDeleted: 0,
        bytesFreed: 0,
      );
    }
    final deleted = delete();
    return StorageDeleteResult(
      ok: true,
      code: 'ok',
      filesDeleted: deleted.files,
      bytesFreed: deleted.bytes,
    );
  }
}

class _InMemoryStorageHarness implements _StorageHarness {
  final _tree = _FakeTree();
  late final _InMemoryStoragePort _port = _InMemoryStoragePort(_tree);

  @override
  CaptureStorageClient get client => _PortBackedStorageClient(_port);

  @override
  Future<void> setActive(bool active) async => _tree.active = active;

  @override
  Future<void> setUp() async {}

  @override
  Future<void> tearDown() async {}
}

/// Same public surface as [CaptureStorageClient], over an injected port.
class _PortBackedStorageClient implements CaptureStorageClient {
  _PortBackedStorageClient(this._port);

  final CaptureStoragePort _port;

  @override
  Future<int> freeSpaceBytes() => _port.freeSpaceBytes();

  @override
  Future<StorageUsage> usage(String projectId,
          {String? jobId, String? level}) =>
      _port.usage(projectId, jobId: jobId, level: level);

  @override
  Future<List<String>> listProjects() => _port.listProjects();

  @override
  Future<List<String>> listJobs(String projectId) => _port.listJobs(projectId);

  @override
  Future<List<IncompleteJob>> listIncompleteJobs() =>
      _port.listIncompleteJobs();

  @override
  Future<StorageDeleteResult> deleteLevel(
    String projectId,
    String jobId,
    String level, {
    bool force = false,
  }) =>
      _port.deleteLevel(projectId, jobId, level, force: force);

  @override
  Future<StorageDeleteResult> deleteJob(
    String projectId,
    String jobId, {
    bool force = false,
  }) =>
      _port.deleteJob(projectId, jobId, force: force);

  @override
  Future<StorageDeleteResult> deleteProject(String projectId,
          {bool force = false}) =>
      _port.deleteProject(projectId, force: force);

  @override
  Future<PurgeResult> purgeProjectCaptureData(String projectId,
          {bool force = false}) =>
      _port.purgeProjectCaptureData(projectId, force: force);

  @override
  Future<SweepResult> sweepOrphanedCaptureData(List<String> knownProjectIds,
          {bool force = false}) =>
      _port.sweepOrphanedCaptureData(knownProjectIds, force: force);

  @override
  void setActiveScope({
    required String projectId,
    required String jobId,
    required String level,
  }) =>
      _port.setActiveScope(projectId: projectId, jobId: jobId, level: level);

  @override
  Future<void> setJobActive(String projectId, String jobId,
          {required bool active}) =>
      _port.setJobActive(projectId, jobId, active: active);

  @override
  Future<void> markJobComplete(String projectId, String jobId) =>
      _port.markJobComplete(projectId, jobId);

  @override
  Future<Uint8List?> readFrameBytes(String path) => _port.readFrameBytes(path);
}
