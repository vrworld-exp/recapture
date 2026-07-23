// test/upload/upload_flow_test.dart
//
// The upload-flow ORCHESTRATOR against fakes (no network/filesystem/Hive):
//   • the happy sequence — pack → POST /projects → POST /jobs → session spec
//     (key containment under the plan's keyPrefix + the plan's manifestKey) →
//     engine run → finalize — with `completed` reaching the screen ONLY after
//     finalize returns QUEUED (the engine's own completed is held back);
//   • finalize failure / non-QUEUED state → a terminal failed outcome through
//     the progress stream (classifyUploadFailure path), never a silent success;
//   • a runner-terminal engine failure → an [UploadFlowFailure] carrying the
//     runner's mapped category (per-attempt failed snapshots are swallowed);
//   • cancel mid-flight → the engine is aborted and finalize NEVER runs;
//     cancel during pack → the pack token fires and no backend call is made;
//   • the STEP TIMELINE (watchTimeline) transitions at the same points, obeying
//     the same terminal truth: per-attempt failures show at most a retrying
//     note; only the terminal outcome fails/cancels the timeline.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry.dart';
import 'package:recapture/application/capture/progression/level_progression_builder.dart';
import 'package:recapture/application/upload/capture_bundle_packer.dart';
import 'package:recapture/application/upload/resilient_upload_runner.dart';
import 'package:recapture/application/upload/upload_flow.dart';
import 'package:recapture/application/upload/upload_jobs_backend.dart';
import 'package:recapture/application/upload/upload_progress_provider.dart';
import 'package:recapture/domain/capture/capture_flow_variant.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/upload_progress.dart';
import 'package:recapture/domain/upload/capture_bundle.dart';
import 'package:recapture/domain/upload/capture_manifest.dart';
import 'package:recapture/domain/upload/upload_failure.dart';
import 'package:recapture/domain/upload/upload_flow_steps.dart';
import 'package:recapture/domain/upload/upload_session_spec.dart';

// ── Fakes ─────────────────────────────────────────────────────────────────────

class _FakeEngineSource implements UploadProgressSource {
  final StreamController<UploadProgress> _c =
      StreamController<UploadProgress>.broadcast();
  UploadProgress current = UploadProgress.initial;

  @override
  Stream<UploadProgress> watch() async* {
    yield current;
    yield* _c.stream;
  }

  void emit(UploadProgress p) {
    current = p;
    _c.add(p);
  }
}

class _FakeEngine implements UploadEngine {
  final _FakeEngineSource source = _FakeEngineSource();
  final Completer<ResilientUploadOutcome> outcome =
      Completer<ResilientUploadOutcome>();
  final Completer<void> started = Completer<void>();
  UploadSessionSpec? spec;
  bool cancelled = false;

  @override
  UploadProgressSource get progress => source;

  @override
  Future<ResilientUploadOutcome> run(UploadSessionSpec s) {
    spec = s;
    started.complete();
    return outcome.future;
  }

  @override
  void pause() {}

  @override
  void resume() {}

  @override
  void cancel() {
    cancelled = true;
    if (!outcome.isCompleted) {
      outcome.complete(const ResilientUploadOutcome(
        status: ResilientUploadStatus.cancelled,
        attemptsUsed: 1,
      ));
    }
  }
}

class _FakeBackend implements UploadJobsBackend {
  _FakeBackend({this.finalizeState = 'QUEUED', this.finalizeError});

  final String finalizeState;
  final Object? finalizeError;

  final List<String> calls = [];
  Map<String, Object?>? jobArgs;
  int? finalizedWith;

  /// Snapshot hook so the test can pin what the SCREEN saw at finalize time.
  void Function()? onFinalize;

  @override
  Future<String> createProject({
    required String name,
    required String size,
    required String mode,
  }) async {
    calls.add('createProject');
    expect(mode, 'guided');
    return 'proj-1';
  }

  @override
  Future<CreatedUploadJob> createJob({
    required String projectId,
    required String objectSize,
    required String captureVariant,
    required String captureMode,
    required int expectedFilesCount,
    required String idempotencyKey,
  }) async {
    calls.add('createJob');
    jobArgs = {
      'projectId': projectId,
      'objectSize': objectSize,
      'captureVariant': captureVariant,
      'captureMode': captureMode,
      'expectedFilesCount': expectedFilesCount,
      'idempotencyKey': idempotencyKey,
    };
    return const CreatedUploadJob(
      jobId: 'job-1',
      keyPrefix: 'dev/u1/proj-1/job-1/',
      manifestKey: 'dev/u1/proj-1/job-1/capture_manifest.json',
    );
  }

  @override
  Future<String> finalizeJob({
    required String jobId,
    required int reportedFilesCount,
  }) async {
    calls.add('finalizeJob');
    finalizedWith = reportedFilesCount;
    onFinalize?.call();
    final err = finalizeError;
    if (err != null) throw err;
    return finalizeState;
  }
}

/// Pre-engine failure: POST /projects throws (e.g. a 500 / dead network).
class _FailingProjectBackend extends _FakeBackend {
  @override
  Future<String> createProject({
    required String name,
    required String size,
    required String mode,
  }) async {
    calls.add('createProject');
    throw Exception('500 INTERNAL');
  }
}

/// Collected view of everything the flow's progress surface emitted —
/// byte/file snapshots, stream errors, AND every step-timeline emission.
class _ProgressLog {
  final List<UploadProgress> snapshots = [];
  final List<Object> errors = [];
  final List<UploadFlowTimeline> timelines = [];
  late final StreamSubscription<UploadProgress> _sub;
  late final StreamSubscription<UploadFlowTimeline> _timelineSub;

  _ProgressLog(UploadFlowProgress progress) {
    _sub = progress.watch().listen(snapshots.add, onError: errors.add);
    _timelineSub = progress.watchTimeline().listen(timelines.add);
  }

  Future<void> dispose() async {
    await _sub.cancel();
    await _timelineSub.cancel();
  }
}

/// Flattens the emitted timelines into the ordered list of step transitions
/// ('stepId:status', or 'stepId:info' for an info-only change) so a test can
/// pin the EXACT sequence the screen would render.
List<String> _timelineTransitions(List<UploadFlowTimeline> timelines) {
  final out = <String>[];
  var prev = UploadFlowTimeline.initial();
  for (final t in timelines) {
    for (final id in UploadFlowStepId.values) {
      final a = prev[id];
      final b = t[id];
      if (a.status != b.status) {
        out.add('${id.name}:${b.status.name}');
      } else if (a.info != b.info) {
        out.add('${id.name}:info');
      }
    }
    prev = t;
  }
  return out;
}

/// Lets the async broadcast relay (+ the watch() generator hop) deliver every
/// pending event to the log before asserting.
Future<void> _flush([int microtasks = 6]) async {
  for (var i = 0; i < microtasks; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

// ── Fixtures ──────────────────────────────────────────────────────────────────

UploadFlowContext _context() => UploadFlowContext(
      localProjectId: 'local-p1',
      projectName: 'Chair scan',
      captureSessionId: 'cap-session-1',
      config: CaptureConfig.bundledDefault,
      progression: initialProgressionFromConfig(
        CaptureConfig.bundledDefault,
        variant: CaptureFlowVariant.withBottom,
      ),
      registry: LevelCaptureLedgerRegistry(),
      variant: CaptureFlowVariant.withBottom,
      workspaceRoot: '/ws',
    );

const _bundle = CaptureBundle(
  path: '/ws/bundles/cap-session-1',
  manifestPath: '/ws/bundles/cap-session-1/capture_manifest.json',
  totalImages: 3,
  totalBytes: 300,
  perLevelCounts: {'EYE': 2, 'TOP': 1},
);

class _Harness {
  _Harness({_FakeBackend? backend, PackBundleFn? pack})
      : backend = backend ?? _FakeBackend() {
    orchestrator = UploadFlowOrchestrator(
      resolveContext: () async {
        calls.add('resolveContext');
        return _context();
      },
      pack: pack ??
          ({
            required UploadFlowContext context,
            required ManifestSession session,
            required ManifestDevice device,
            BundleCancelToken? cancelToken,
          }) async {
            calls.add('pack');
            packSession = session;
            packToken = cancelToken;
            return _bundle;
          },
      backend: () => this.backend,
      engineFactory: (jobId) {
        calls.add('engineFactory($jobId)');
        return engine;
      },
      uuid: () => 'uuid-fixed',
      fileSize: (path) => 100,
    );
    this.backend.calls.clear();
    // Merge the backend's call log into ours for one ordered sequence.
    log = _ProgressLog(orchestrator.progress);
  }

  final List<String> calls = [];
  final _FakeBackend backend;
  final _FakeEngine engine = _FakeEngine();
  late final UploadFlowOrchestrator orchestrator;
  late final _ProgressLog log;
  ManifestSession? packSession;
  BundleCancelToken? packToken;
}

void main() {
  test('happy path: sequence, spec keys, and completed only after QUEUED',
      () async {
    final h = _Harness();
    UploadStatus? statusWhenFinalizeRan;
    h.backend.onFinalize =
        () => statusWhenFinalizeRan = h.orchestrator.progress.current.status;

    final done = h.orchestrator.run();
    await h.engine.started.future;
    await _flush(); // facade subscription reaches the engine feed

    // The engine reports transfer progress, then its own `completed` — which
    // must NOT reach observers as completed before finalize confirms QUEUED.
    h.engine.source.emit(const UploadProgress(
      status: UploadStatus.inProgress,
      bytesUploaded: 100,
      totalBytes: 400,
      filesUploaded: 1,
      totalFiles: 4,
    ));
    h.engine.source.emit(const UploadProgress(
      status: UploadStatus.completed,
      bytesUploaded: 400,
      totalBytes: 400,
      filesUploaded: 4,
      totalFiles: 4,
    ));
    await _flush(); // let the facade process the engine feed before finalize
    h.engine.outcome.complete(const ResilientUploadOutcome(
      status: ResilientUploadStatus.succeeded,
      attemptsUsed: 1,
    ));
    await done;
    await _flush();
    await h.log.dispose();

    // Sequence.
    expect(h.calls, ['resolveContext', 'pack', 'engineFactory(job-1)']);
    expect(h.backend.calls, ['createProject', 'createJob', 'finalizeJob']);

    // Job creation: exact count (images + manifest), variant id, fixed key.
    expect(h.backend.jobArgs, {
      'projectId': 'proj-1',
      'objectSize': 'medium',
      'captureVariant': 'with_bottom',
      'captureMode': 'full',
      'expectedFilesCount': 4,
      'idempotencyKey': 'uuid-fixed',
    });

    // The spec maps the bundle onto the plan: every key under keyPrefix, the
    // manifest at the plan's own manifestKey, sessionId = the backend job id.
    final spec = h.engine.spec!;
    expect(spec.sessionId, 'job-1');
    expect([
      for (final f in spec.files) f.key
    ], [
      'dev/u1/proj-1/job-1/images/EYE/eye_0001.jpg',
      'dev/u1/proj-1/job-1/images/EYE/eye_0002.jpg',
      'dev/u1/proj-1/job-1/images/TOP/top_0001.jpg',
      'dev/u1/proj-1/job-1/capture_manifest.json',
    ]);
    for (final f in spec.files) {
      expect(f.key, startsWith('dev/u1/proj-1/job-1/'));
      expect(f.size, 100);
    }
    expect(h.backend.finalizedWith, 4);

    // The manifest/bundle got the LOCAL ids (remote ids are minted later).
    expect(h.packSession!.projectId, 'local-p1');
    expect(h.packSession!.captureSessionId, 'cap-session-1');

    // Terminal truth: at finalize time the screen still saw inProgress; the
    // single completed snapshot arrives only after QUEUED, with real totals.
    expect(statusWhenFinalizeRan, UploadStatus.inProgress);
    final completed =
        h.log.snapshots.where((p) => p.status == UploadStatus.completed);
    expect(completed, hasLength(1));
    expect(h.log.snapshots.last.status, UploadStatus.completed);
    expect(h.log.snapshots.last.bytesUploaded, 400);
    expect(h.log.snapshots.last.filesUploaded, 4);
    expect(h.log.errors, isEmpty);
    expect(h.orchestrator.progress.isActive, isFalse);

    // Step timeline: every step flips running→done in flow order, nothing else.
    expect(_timelineTransitions(h.log.timelines), [
      'prepare:running',
      'prepare:done',
      'createProject:running',
      'createProject:done',
      'createJob:running',
      'createJob:done',
      'transfer:running',
      'transfer:done',
      'finalize:running',
      'finalize:done',
    ]);
    final tl = h.orchestrator.progress.timeline;
    expect(tl.isAllDone, isTrue);
    // Prod-safe info lines: counts/sizes only (bundle = 3 images + manifest).
    expect(tl[UploadFlowStepId.prepare].info, '4 files · 0.0 MB');
    expect(tl[UploadFlowStepId.transfer].info, '4 files');
    // Dev-only raw detail (test flavor is dev — the prod gate strips these).
    expect(tl[UploadFlowStepId.createProject].devDetail,
        contains('remoteProjectId=proj-1'));
    expect(tl[UploadFlowStepId.createJob].devDetail,
        contains('jobId=job-1'));
  });

  test(
      'partial without_bottom bundle (16+16): createJob gets the REAL count '
      '(33) and finalize reports it', () async {
    // The coverage-floor case: both rings finished at 16/18 segments (>= the
    // 80% floor of 15) — the bundle carries 32 images, and the flow must
    // declare exactly bundle.totalImages + 1, never the full variant total.
    const partialBundle = CaptureBundle(
      path: '/ws/bundles/cap-session-1',
      manifestPath: '/ws/bundles/cap-session-1/capture_manifest.json',
      totalImages: 32,
      totalBytes: 3200,
      perLevelCounts: {'EYE': 16, 'TOP': 16},
    );
    final h = _Harness(
      pack: ({
        required UploadFlowContext context,
        required ManifestSession session,
        required ManifestDevice device,
        BundleCancelToken? cancelToken,
      }) async =>
          partialBundle,
    );

    final done = h.orchestrator.run();
    await h.engine.started.future;
    await _flush();
    h.engine.outcome.complete(const ResilientUploadOutcome(
      status: ResilientUploadStatus.succeeded,
      attemptsUsed: 1,
    ));
    await done;
    await _flush();
    await h.log.dispose();

    expect(h.backend.jobArgs!['expectedFilesCount'], 33);
    // 32 images + the manifest ride the spec; finalize reports the same 33.
    expect(h.engine.spec!.files, hasLength(33));
    expect(h.backend.finalizedWith, 33);
    expect(h.log.snapshots.last.status, UploadStatus.completed);
  });

  test('finalize failure → failed status + stream error, never completed',
      () async {
    final failure = Exception('422 VERIFICATION_FAILED');
    final h = _Harness(backend: _FakeBackend(finalizeError: failure));

    final done = h.orchestrator.run();
    await h.engine.started.future;
    await _flush(); // facade subscription reaches the engine feed
    h.engine.outcome.complete(const ResilientUploadOutcome(
      status: ResilientUploadStatus.succeeded,
      attemptsUsed: 1,
    ));
    await done;
    await _flush();
    await h.log.dispose();

    expect(h.backend.calls, contains('finalizeJob'));
    expect(h.log.errors, [failure]); // raw error → classifyUploadFailure at 9
    expect(h.log.snapshots.last.status, UploadStatus.failed);
    expect(
      h.log.snapshots.any((p) => p.status == UploadStatus.completed),
      isFalse,
    );

    // Timeline: the FINALIZE step carries the failure; transfer stays done.
    final tl = h.orchestrator.progress.timeline;
    expect(tl[UploadFlowStepId.transfer].isDone, isTrue);
    expect(tl[UploadFlowStepId.finalize].isFailed, isTrue);
    expect(tl.hasFailure, isTrue);
  });

  test('finalize returning a non-QUEUED state is a failure, not a success',
      () async {
    final h = _Harness(backend: _FakeBackend(finalizeState: 'CREATED'));

    final done = h.orchestrator.run();
    await h.engine.started.future;
    await _flush(); // facade subscription reaches the engine feed
    h.engine.outcome.complete(const ResilientUploadOutcome(
      status: ResilientUploadStatus.succeeded,
      attemptsUsed: 1,
    ));
    await done;
    await _flush();
    await h.log.dispose();

    expect(h.log.errors.single, isA<UploadFlowFailure>());
    expect(h.log.snapshots.last.status, UploadStatus.failed);
    expect(h.orchestrator.progress
        .timeline[UploadFlowStepId.finalize].isFailed, isTrue);
  });

  test(
      'terminal engine failure carries the runner category; per-attempt '
      'failed snapshots are swallowed', () async {
    final h = _Harness();

    final done = h.orchestrator.run();
    await h.engine.started.future;
    await _flush(); // facade subscription reaches the engine feed

    // A mid-run per-attempt failure (the runner would auto-retry) must not
    // leak to the screen as a terminal failed status.
    h.engine.source.emit(const UploadProgress(
      status: UploadStatus.failed,
      bytesUploaded: 50,
      totalBytes: 400,
      filesUploaded: 0,
      totalFiles: 4,
    ));
    await _flush();
    expect(
      h.log.snapshots.any((p) => p.status == UploadStatus.failed),
      isFalse,
    );
    // The step tracker shows AT MOST a retrying note — the transfer step is
    // still RUNNING, not failed.
    final midRun = h.orchestrator.progress.timeline[UploadFlowStepId.transfer];
    expect(midRun.isRunning, isTrue);
    expect(midRun.info, 'Retrying…');

    h.engine.outcome.complete(const ResilientUploadOutcome(
      status: ResilientUploadStatus.failed,
      attemptsUsed: 4,
      category: UploadErrorCategory.network,
      autoRetriesExhausted: true,
    ));
    await done;
    await _flush();
    await h.log.dispose();

    final err = h.log.errors.single as UploadFlowFailure;
    expect(err.uploadErrorCategory, UploadErrorCategory.network);
    expect(classifyUploadFailure(err), UploadErrorCategory.network);
    expect(h.backend.calls, isNot(contains('finalizeJob')));

    // Only the runner's TERMINAL outcome fails the transfer step; finalize
    // was never reached so it stays pending.
    final tl = h.orchestrator.progress.timeline;
    expect(tl[UploadFlowStepId.transfer].isFailed, isTrue);
    expect(tl[UploadFlowStepId.finalize].isPending, isTrue);
  });

  test('cancel mid-transfer aborts the engine and NEVER finalizes', () async {
    final h = _Harness();

    final done = h.orchestrator.run();
    await h.engine.started.future;
    await _flush(); // facade subscription reaches the engine feed

    h.orchestrator.progress.cancel(); // the Cancel→Keep-as-Draft signal path
    await done;
    await _flush();
    await h.log.dispose();

    expect(h.engine.cancelled, isTrue);
    expect(h.backend.calls, isNot(contains('finalizeJob')));
    expect(h.log.snapshots.last.status, UploadStatus.cancelled);
    expect(h.log.errors, isEmpty);

    // Timeline: completed steps stay done; transfer + finalize are struck.
    final tl = h.orchestrator.progress.timeline;
    expect(tl[UploadFlowStepId.createJob].isDone, isTrue);
    expect(tl[UploadFlowStepId.transfer].isCancelled, isTrue);
    expect(tl[UploadFlowStepId.finalize].isCancelled, isTrue);
    expect(tl.isCancelled, isTrue);
  });

  test('cancel during pack fires the pack token; no backend call is made',
      () async {
    final gate = Completer<void>();
    late _Harness h;
    h = _Harness(
      pack: ({
        required UploadFlowContext context,
        required ManifestSession session,
        required ManifestDevice device,
        BundleCancelToken? cancelToken,
      }) async {
        h.packToken = cancelToken;
        await gate.future;
        if (cancelToken!.isCancelled) {
          throw const BundlePackException(BundlePackFailureReason.cancelled,
              stage: 'stage');
        }
        return _bundle;
      },
    );

    final done = h.orchestrator.run();
    await Future<void>.delayed(Duration.zero); // let the pack start
    h.orchestrator.progress.cancel();
    expect(h.packToken!.isCancelled, isTrue);
    gate.complete();
    await done;
    await _flush();
    await h.log.dispose();

    expect(h.backend.calls, isEmpty);
    expect(h.log.snapshots.last.status, UploadStatus.cancelled);
    expect(h.log.errors, isEmpty);

    // A cancel during pack strikes every step (prepare included).
    expect(
      h.orchestrator.progress.timeline.steps.every((s) => s.isCancelled),
      isTrue,
    );
  });

  test('pre-engine throw (createProject) fails THAT step; later steps pending',
      () async {
    final h = _Harness(backend: _FailingProjectBackend());

    await h.orchestrator.run();
    await _flush();
    await h.log.dispose();

    // The flow failed before the engine was ever built.
    expect(h.calls, ['resolveContext', 'pack']);
    expect(h.log.errors, hasLength(1));
    expect(h.log.snapshots.last.status, UploadStatus.failed);

    expect(_timelineTransitions(h.log.timelines), [
      'prepare:running',
      'prepare:done',
      'createProject:running',
      'createProject:failed',
    ]);
    final tl = h.orchestrator.progress.timeline;
    expect(tl[UploadFlowStepId.createJob].isPending, isTrue);
    expect(tl[UploadFlowStepId.transfer].isPending, isTrue);
    expect(tl[UploadFlowStepId.finalize].isPending, isTrue);
  });

  test('buildUploadSessionSpec rejects a key escaping the plan prefix', () {
    expect(
      () => buildUploadSessionSpec(
        bundle: _bundle,
        keyPrefix: 'dev/u1/proj-1/job-1/',
        manifestKey: 'dev/OTHER/capture_manifest.json', // outside the prefix
        sessionId: 'job-1',
        fileSize: (_) => 1,
      ),
      throwsStateError,
    );
  });
}
