// lib/application/upload/upload_flow.dart
//
// The REAL upload pipeline wiring — the one-shot orchestrator the Capture
// Summary's Upload CTA starts, composing the already-built (and unit-tested)
// pieces end-to-end:
//
//   pack (CaptureBundlePacker) → dev backend session (UploadAuthSession) →
//   POST /projects → POST /jobs (Idempotency-Key) → ChunkedUploadManager
//   (per-file presigned multipart via JobsMultipartUploadApi + bare-Dio S3
//   part PUTs) inside ResilientUploadRunner (SessionRetryPolicy auto-retry) →
//   POST /jobs/:id/finalize → QUEUED.
//
// SCREEN CONTRACT: Screen 9 stays a pure observer of the existing seams
// ([uploadProgressSourceProvider] / [uploadControllerProvider]), which now
// delegate to the ACTIVE flow's [UploadFlowProgress] and fall back to the
// no-op defaults when idle. The facade enforces the flow's terminal truth:
//   • the engine's `completed` is HELD (remapped to inProgress) until finalize
//     returns state == "QUEUED" — only then does Screen 9 see `completed` and
//     advance to Processing; a finalize failure surfaces as a stream error →
//     Screen 9F through the existing classifyUploadFailure path, never a
//     silent success;
//   • per-attempt `failed` snapshots are swallowed while the runner may still
//     auto-retry — only the runner's TERMINAL outcome (or a pre-engine
//     failure) reaches the screen, carrying its mapped category via
//     [UploadFlowFailure] (an [UploadFailureSignal]);
//   • cancel (Cancel → Keep as Draft, or the transfer Cancel button) reaches
//     the live engine (aborting in-flight part PUTs; local files retained) and,
//     pre-engine, cancels the pack / skips finalize.
//
// Every boundary (context resolution, packer, backend, engine) is injected so
// the orchestrator is unit-testable with fakes — no Hive/network/filesystem.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/local/active_session_box.dart';
import '../../data/local/upload_progress_box.dart';
import '../../domain/entities/capture_config.dart';
import '../../domain/entities/upload_progress.dart';
import '../../domain/upload/capture_bundle.dart';
import '../../domain/upload/capture_manifest.dart';
import '../../domain/upload/upload_failure.dart';
import '../../domain/upload/upload_session_spec.dart';
import '../capture/analytics/capture_level_session.dart';
import '../capture/capture_flow_variant_provider.dart';
import '../capture/ledger/level_capture_ledger_registry.dart';
import '../capture/ledger/level_capture_ledger_registry_provider.dart';
import '../capture/progression/level_progression.dart';
import '../capture/progression/level_progression_provider.dart';
import '../config/config_notifier.dart';
import '../connectivity/connectivity_providers.dart';
import '../projects/projects_notifier.dart';
import '../warmup/backend_warmup.dart';
import 'capture_bundle_packer.dart';
import 'chunked_upload_manager.dart';
import 'jobs_multipart_upload_api.dart';
import 'multipart_upload_api.dart';
import 'resilient_upload_runner.dart';
import 'upload_auth_session.dart';
import 'upload_controller.dart';
import 'upload_jobs_backend.dart';
import 'upload_progress_provider.dart';

import '../../domain/capture/capture_flow_variant.dart';

/// A terminal upload-flow failure carrying its ALREADY-MAPPED category — the
/// authoritative [UploadFailureSignal] `classifyUploadFailure` honors, so 9F
/// shows the runner's classification rather than re-guessing from a bare
/// status. [detail] is diagnostics-only (never rendered).
class UploadFlowFailure implements Exception, UploadFailureSignal {
  const UploadFlowFailure(this.uploadErrorCategory, {this.detail});

  @override
  final UploadErrorCategory uploadErrorCategory;

  final String? detail;

  @override
  String toString() => 'UploadFlowFailure(${uploadErrorCategory.wireName}'
      '${detail == null ? '' : ': $detail'})';
}

/// Everything the orchestrator needs from the app session, resolved once at
/// flow start (injected as a whole so tests fabricate it directly).
class UploadFlowContext {
  const UploadFlowContext({
    required this.localProjectId,
    required this.projectName,
    required this.captureSessionId,
    required this.config,
    required this.progression,
    required this.registry,
    required this.variant,
    required this.workspaceRoot,
    this.objectSize = 'medium',
  });

  /// The LOCAL project id (Hive/session scope — not the remote id, which is
  /// minted by POST /projects during the flow).
  final String localProjectId;

  /// Names the remote project (POST /projects `name`).
  final String projectName;

  /// The capture funnel session id (analytics + manifest pairing).
  final String captureSessionId;

  final CaptureConfig config;
  final LevelProgression progression;
  final LevelCaptureLedgerRegistry registry;
  final CaptureFlowVariant variant;

  /// App-scoped documents root the packer stages/finalizes bundles under.
  final String workspaceRoot;

  /// Backend size enum for /projects (`size`) and /jobs (`objectSize`). The
  /// local Project entity carries no size yet — 'medium' until the create-
  /// project size selection is threaded through.
  final String objectSize;
}

/// The transport engine the orchestrator runs: the manager (progress feed +
/// pause/resume) wrapped in the session-level auto-retry runner (cancel +
/// terminal outcome). Interface so the sequence test uses a scripted fake.
abstract interface class UploadEngine {
  UploadProgressSource get progress;

  Future<ResilientUploadOutcome> run(UploadSessionSpec spec);

  void pause();

  void resume();

  void cancel();
}

/// Production [UploadEngine]: [ChunkedUploadManager] + [ResilientUploadRunner].
class RunnerUploadEngine implements UploadEngine {
  RunnerUploadEngine({required this.manager, required this.runner});

  final ChunkedUploadManager manager;
  final ResilientUploadRunner runner;

  @override
  UploadProgressSource get progress => manager;

  @override
  Future<ResilientUploadOutcome> run(UploadSessionSpec spec) =>
      runner.run(spec);

  @override
  void pause() => manager.pause();

  @override
  void resume() => manager.resume();

  /// Cancels through the RUNNER (which aborts the in-flight attempt AND wakes
  /// any backoff wait) — not the manager directly, or a cancel landing during
  /// a between-attempts backoff would be lost.
  @override
  void cancel() => runner.cancel();
}

/// The live flow's progress + control surface — what the app-wide seams
/// ([uploadProgressSourceProvider] / [uploadControllerProvider]) delegate to
/// while a flow exists. See the library doc for the terminal-truth rules it
/// enforces over the raw engine feed.
class UploadFlowProgress implements UploadProgressSource, UploadController {
  final StreamController<UploadProgress> _relay =
      StreamController<UploadProgress>.broadcast();
  UploadProgress _current = UploadProgress.initial;

  /// The engine's held-back `completed` snapshot (real totals) — released by
  /// [markCompleted] once finalize confirms QUEUED.
  UploadProgress? _held;
  UploadEngine? _engine;
  StreamSubscription<UploadProgress>? _sub;
  bool _terminal = false;

  /// Orchestrator hook: a cancel signal must reach the WHOLE flow (pack token,
  /// engine, finalize skip), not just the engine.
  void Function()? onCancelRequested;

  /// False once the flow reached completed/failed/cancelled — a terminal flow
  /// is replaced (not reused) by the next start.
  bool get isActive => !_terminal;

  /// The latest snapshot (test/diagnostic convenience; the screen streams).
  UploadProgress get current => _current;

  // ── UploadProgressSource ───────────────────────────────────────────────────

  @override
  Stream<UploadProgress> watch() async* {
    yield _current; // replay the current snapshot to a new subscriber
    yield* _relay.stream;
  }

  // ── UploadController (idempotent; safe pre-engine) ─────────────────────────

  @override
  void pause() => _engine?.pause();

  @override
  void resume() => _engine?.resume();

  @override
  void cancel() => onCancelRequested?.call();

  // ── Flow-side transitions ──────────────────────────────────────────────────

  void _push(UploadProgress next) {
    _current = next;
    if (!_relay.isClosed) _relay.add(next);
  }

  /// Flow kicked off (pre-engine): show an active-but-empty state instead of
  /// idle so Screen 9 renders "uploading" while the bundle packs.
  void markRunning() {
    if (_terminal) return;
    _push(_current.copyWith(status: UploadStatus.inProgress));
  }

  /// Binds the engine's feed, applying the hold/swallow rules (see class doc).
  void attachEngine(UploadEngine engine) {
    _engine = engine;
    _sub = engine.progress.watch().listen((p) {
      if (_terminal) return;
      switch (p.status) {
        case UploadStatus.completed:
          // Transfer done ≠ flow done: hold until finalize returns QUEUED.
          _held = p;
          _push(p.copyWith(status: UploadStatus.inProgress));
        case UploadStatus.failed:
          break; // per-attempt failure — the runner may still auto-retry
        case UploadStatus.idle:
          break; // pre-start replay — the flow is already inProgress
        default:
          _push(p);
      }
    });
  }

  /// Finalize confirmed QUEUED → release the held completed snapshot. This is
  /// the ONLY way the screen ever sees `completed`.
  void markCompleted() {
    if (_terminal) return;
    _terminal = true;
    _push((_held ?? _current).copyWith(status: UploadStatus.completed));
    unawaited(_sub?.cancel());
  }

  /// Terminal failure: the error OBJECT rides the stream (Screen 9 classifies
  /// it via classifyUploadFailure — raw detail is never rendered), followed by
  /// a failed snapshot for late subscribers.
  void fail(Object error) {
    if (_terminal) return;
    _terminal = true;
    if (!_relay.isClosed) _relay.addError(error);
    _push(_current.copyWith(status: UploadStatus.failed));
    unawaited(_sub?.cancel());
  }

  /// Terminal cancel (transfer aborted, local captures retained). No-op when
  /// the engine's own cancelled snapshot already came through.
  void markCancelled() {
    if (_terminal) return;
    _terminal = true;
    if (_current.status != UploadStatus.cancelled) {
      _push(_current.copyWith(status: UploadStatus.cancelled));
    }
    unawaited(_sub?.cancel());
  }
}

/// Signature of the injected pack step (production: [CaptureBundlePacker]).
typedef PackBundleFn = Future<CaptureBundle> Function({
  required UploadFlowContext context,
  required ManifestSession session,
  required ManifestDevice device,
  BundleCancelToken? cancelToken,
});

/// Builds one engine for the created backend job.
typedef UploadEngineFactory = UploadEngine Function(String jobId);

/// Maps the finalized bundle onto the job's upload plan: one [UploadFileSpec]
/// per image at `<keyPrefix>images/<RING>/<name>.jpg` (per-ring counts +
/// deterministic names come from the SAME planner that wrote the files) plus
/// the manifest at the plan's own manifestKey. Every key is containment-
/// checked against [keyPrefix] up front — the server rejects escapes with a
/// 400, so a bad plan must fail loudly here, not mid-transfer.
UploadSessionSpec buildUploadSessionSpec({
  required CaptureBundle bundle,
  required String keyPrefix,
  required String manifestKey,
  required String sessionId,
  int Function(String path)? fileSize,
}) {
  final sizeOf = fileSize ?? _fileSizeOnDisk;
  final files = <UploadFileSpec>[];

  void add(String path, String key) {
    if (!key.startsWith(keyPrefix)) {
      throw StateError(
          'upload key escapes the job keyPrefix: $key (prefix $keyPrefix)');
    }
    files.add(UploadFileSpec(path: path, key: key, size: sizeOf(path)));
  }

  for (final entry in bundle.perLevelCounts.entries) {
    final ring = entry.key;
    for (var i = 1; i <= entry.value; i++) {
      final rel = bundleImageRelPath(ring, bundleImageFileName(ring, i));
      add('${bundle.path}/$rel', '$keyPrefix$rel');
    }
  }
  add(bundle.manifestPath, manifestKey);

  return UploadSessionSpec(sessionId: sessionId, files: files);
}

int _fileSizeOnDisk(String path) {
  final f = File(path);
  return f.existsSync() ? f.lengthSync() : 0;
}

/// Thrown internally when a cancel lands between flow steps.
class _FlowCancelled implements Exception {
  const _FlowCancelled();
}

/// Owns ONE upload flow end-to-end (pack → project → job → engine → finalize).
/// Single-shot: [run] executes once; a retry is a NEW orchestrator.
class UploadFlowOrchestrator {
  UploadFlowOrchestrator({
    required Future<UploadFlowContext> Function() resolveContext,
    required PackBundleFn pack,
    // A FACTORY (invoked inside run()'s catch-all) so constructing the real
    // Dio — which reads env config — can never throw out of start().
    required UploadJobsBackend Function() backend,
    required UploadEngineFactory engineFactory,
    Future<void> Function()? warmUp,
    String Function()? uuid,
    int Function(String path)? fileSize,
    DateTime Function()? now,
  })  : _resolveContext = resolveContext,
        _pack = pack,
        _backendFactory = backend,
        _engineFactory = engineFactory,
        _warmUp = warmUp,
        _uuid = uuid ?? randomUuidV4,
        _fileSize = fileSize,
        _now = now ?? DateTime.now {
    progress.onCancelRequested = _requestCancel;
  }

  final Future<UploadFlowContext> Function() _resolveContext;
  final PackBundleFn _pack;
  final UploadJobsBackend Function() _backendFactory;
  final UploadEngineFactory _engineFactory;

  /// Best-effort backend wake-up (the Render dev instance sleeps when idle;
  /// a cold start outlasts the API timeouts). Awaited before the first
  /// backend call — concurrently with the pack — and never fails the flow.
  final Future<void> Function()? _warmUp;
  final String Function() _uuid;
  final int Function(String path)? _fileSize;
  final DateTime Function() _now;

  /// The progress/control surface the provider seams delegate to.
  final UploadFlowProgress progress = UploadFlowProgress();

  final BundleCancelToken _packCancel = BundleCancelToken();
  bool _cancelRequested = false;
  bool _started = false;
  UploadEngine? _engine;

  void _requestCancel() {
    _cancelRequested = true;
    _packCancel.cancel(); // aborts a pack in progress (staging cleaned up)
    _engine?.cancel(); // aborts in-flight part PUTs; local files retained
  }

  void _checkCancel() {
    if (_cancelRequested) throw const _FlowCancelled();
  }

  /// Runs the whole flow. NEVER throws — every outcome (success, failure at
  /// any step, cancel) is reported through [progress] so Screen 9/9F always
  /// resolves; callers fire-and-forget.
  Future<void> run() async {
    if (_started) return;
    _started = true;
    try {
      progress.markRunning();

      // Kick the backend wake-up NOW so it overlaps the (potentially long)
      // pack below; awaited before the first real backend call. Best-effort:
      // its failure must never fail the flow (the real call just pays the
      // cold start itself).
      final warming = _warmUp?.call();

      final backend = _backendFactory();
      final ctx = await _resolveContext();
      _checkCancel();

      // Local ids for the bundle/manifest — the REMOTE ids are minted below;
      // the backend pairs files↔manifest by keys/photo entries, not these.
      final localJobId = ctx.captureSessionId.isNotEmpty
          ? ctx.captureSessionId
          : 'job_${_now().millisecondsSinceEpoch}';
      final bundle = await _pack(
        context: ctx,
        session: ManifestSession(
          projectId:
              ctx.localProjectId.isNotEmpty ? ctx.localProjectId : 'local',
          jobId: localJobId,
          captureSessionId: ctx.captureSessionId,
          completedAtIso: _now().toUtc().toIso8601String(),
        ),
        device: ManifestDevice(platform: _platformName),
        cancelToken: _packCancel,
      );
      _checkCancel();

      if (warming != null) {
        try {
          await warming;
        } catch (_) {
          // Warm-up is best-effort by contract; never mask the flow with it.
        }
      }
      _checkCancel();

      final remoteProjectId = await backend.createProject(
        name: ctx.projectName,
        size: ctx.objectSize,
        mode: 'guided',
      );
      _checkCancel();

      final job = await backend.createJob(
        projectId: remoteProjectId,
        objectSize: ctx.objectSize,
        captureVariant: ctx.variant.id,
        // MUST equal the bundle's real content (exact-checked at finalize):
        // every staged image + the manifest.
        expectedFilesCount: bundle.totalImages + 1,
        idempotencyKey: _uuid(),
      );
      _checkCancel();

      final spec = buildUploadSessionSpec(
        bundle: bundle,
        keyPrefix: job.keyPrefix,
        manifestKey: job.manifestKey,
        sessionId: job.jobId,
        fileSize: _fileSize,
      );

      final engine = _engineFactory(job.jobId);
      _engine = engine;
      progress.attachEngine(engine);
      if (_cancelRequested) {
        engine.cancel();
        progress.markCancelled();
        return;
      }

      final outcome = await engine.run(spec);
      switch (outcome.status) {
        case ResilientUploadStatus.cancelled:
          progress.markCancelled();
        case ResilientUploadStatus.failed:
          progress.fail(UploadFlowFailure(
            outcome.category ?? UploadErrorCategory.unknown,
            detail: 'auto-retries exhausted: ${outcome.autoRetriesExhausted}',
          ));
        case ResilientUploadStatus.succeeded:
          await _finalize(backend, job.jobId, spec.totalFiles);
      }
    } on _FlowCancelled {
      progress.markCancelled();
    } on BundlePackException catch (e) {
      if (e.isCancelled || _cancelRequested) {
        progress.markCancelled();
      } else {
        progress.fail(e);
      }
    } catch (e) {
      if (_cancelRequested) {
        progress.markCancelled();
      } else {
        progress.fail(e);
      }
    }
  }

  /// The commit gate: only a QUEUED response completes the flow. A cancel that
  /// raced past the engine's success skips finalize entirely (the job is left
  /// unfinalized server-side; the capture stays a local draft).
  Future<void> _finalize(
    UploadJobsBackend backend,
    String jobId,
    int reportedFilesCount,
  ) async {
    if (_cancelRequested) {
      progress.markCancelled();
      return;
    }
    try {
      final state = await backend.finalizeJob(
        jobId: jobId,
        reportedFilesCount: reportedFilesCount,
      );
      if (state != 'QUEUED') {
        progress.fail(UploadFlowFailure(
          UploadErrorCategory.server,
          detail: 'finalize returned state=$state',
        ));
        return;
      }
      progress.markCompleted();
    } catch (e) {
      // 422 VERIFICATION_FAILED / 409 / transport — classified by the screen.
      progress.fail(e);
    }
  }

  static String get _platformName =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
}

/// The ACTIVE upload flow's progress/control surface, or null when idle.
/// keepAlive (a plain Notifier) — the flow must outlive any one screen.
final uploadFlowProvider =
    NotifierProvider<UploadFlowNotifier, UploadFlowProgress?>(
  UploadFlowNotifier.new,
);

class UploadFlowNotifier extends Notifier<UploadFlowProgress?> {
  @override
  UploadFlowProgress? build() => null;

  /// Starts the upload flow (the Summary Upload CTA / 9F Retry entry point).
  /// Fire-and-forget: the flow surface is installed SYNCHRONOUSLY (so the
  /// Uploading screen binds to it on arrival) and every error flows through
  /// the progress stream — this never throws. No-op while a flow is active;
  /// a terminal flow is replaced by a fresh run over the same captures.
  void start() {
    final current = state;
    if (current != null && current.isActive) return;

    final orchestrator = UploadFlowOrchestrator(
      resolveContext: _resolveContext,
      pack: _packWithPacker,
      backend: () => DioUploadJobsBackend(ref.read(uploadApiDioProvider)),
      engineFactory: _buildEngine,
      // The Render dev backend sleeps when idle and a capture session easily
      // outlasts its idle window — wake it before the first flow call so the
      // token refresh/createProject don't time out into 9F.
      warmUp: () => ref.read(backendWarmupServiceProvider).warmUp(),
    );
    state = orchestrator.progress;
    unawaited(orchestrator.run());
  }

  /// Reads the session context from the live providers/stores. Throws (into
  /// the orchestrator's catch → 9F) when no capture session is resolvable.
  Future<UploadFlowContext> _resolveContext() async {
    final progression = ref.read(levelProgressionControllerProvider);
    if (progression == null) {
      throw StateError('no active capture progression to upload');
    }

    final session = ref.read(captureLevelSessionProvider);
    var projectId = session?.projectId ?? '';
    if (projectId.isEmpty) {
      try {
        projectId = (await ActiveSessionBox().read())?.projectId ?? '';
      } catch (_) {
        // No resumable-session marker → fall through to the empty id.
      }
    }

    // Name the remote project from the local one when it is in the loaded
    // list; otherwise a dated fallback (the upload must not block on the list).
    String projectName = '';
    final projects = ref.read(projectsProvider).valueOrNull;
    if (projects != null) {
      for (final p in projects) {
        if (p.id == projectId) {
          projectName = p.name;
          break;
        }
      }
    }
    if (projectName.isEmpty) {
      final now = DateTime.now();
      projectName =
          'ReCapture ${now.year}-${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')} '
          '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}';
    }

    final docs = await getApplicationDocumentsDirectory();
    return UploadFlowContext(
      localProjectId: projectId,
      projectName: projectName,
      captureSessionId: session?.sessionId ?? '',
      config: ref.read(captureConfigProvider),
      progression: progression,
      registry: ref.read(levelCaptureLedgerRegistryProvider),
      variant: ref.read(captureFlowVariantProvider),
      workspaceRoot: '${docs.path}/upload_workspace',
    );
  }

  Future<CaptureBundle> _packWithPacker({
    required UploadFlowContext context,
    required ManifestSession session,
    required ManifestDevice device,
    BundleCancelToken? cancelToken,
  }) =>
      CaptureBundlePacker(workspaceRoot: context.workspaceRoot).pack(
        session: session,
        device: device,
        config: context.config,
        progression: context.progression,
        registry: context.registry,
        flowVariantId: context.variant.id,
        cancelToken: cancelToken,
      );

  UploadEngine _buildEngine(String jobId) {
    final deviceType =
        defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
    final manager = ChunkedUploadManager(
      api: JobsMultipartUploadApi(
        dio: ref.read(uploadApiDioProvider),
        jobId: jobId,
      ),
      s3: DioS3PartClient(),
      store: HiveUploadProgressStore(),
      // Connectivity gate: parts park (auto-pause) instead of burning retries
      // into a dead network; the user resumes from the upload controls.
      isOnline: () => ref.read(isOnlineProvider),
      deviceType: deviceType,
    );
    return RunnerUploadEngine(
      manager: manager,
      runner: ResilientUploadRunner(
        attempt: ManagerUploadAttempt(manager),
        deviceType: deviceType,
      ),
    );
  }
}

/// RFC-4122 v4 UUID from a CSPRNG — the /jobs Idempotency-Key.
String randomUuidV4() {
  final rng = Random.secure();
  final bytes = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    bytes[i] = rng.nextInt(256);
  }
  bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant 10
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
