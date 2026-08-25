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
import '../../dev/dev_log/dev_upload_log.dart';
import '../../domain/entities/capture_config.dart';
import '../../domain/entities/upload_progress.dart';
import '../../domain/upload/capture_bundle.dart';
import '../../domain/upload/capture_manifest.dart';
import '../../domain/upload/upload_failure.dart';
import '../../domain/upload/upload_flow_steps.dart';
import '../../domain/upload/upload_session_spec.dart';
import '../../utils/app_env.dart';
import '../../utils/byte_format.dart';
import '../capture/analytics/capture_level_session.dart';
import '../capture/capture_flow_variant_provider.dart';
import '../capture/capture_mode_provider.dart';
import '../capture/ledger/level_capture_ledger_registry.dart';
import '../capture/ledger/level_capture_ledger_registry_provider.dart';
import '../capture/progression/level_progression.dart';
import '../capture/progression/level_progression_builder.dart';
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
import '../../domain/capture/capture_mode.dart';
// `hide CaptureMode`: create_project_options defines an unrelated same-named
// enum (guided/manual, the PROJECT mode); we want only its ObjectSize +
// apiValue extension for reading the reused project's stored size.
import '../../domain/entities/create_project_options.dart' hide CaptureMode;

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
    this.mode = CaptureMode.full,
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

  /// The capture MODE the session ran under. Decides the per-ring counts the
  /// bundle contains, so it must reach both the job (`POST /jobs`) and the
  /// manifest — the server validates the bundle against the mode it was told.
  final CaptureMode mode;

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
  Future<ResilientUploadOutcome> run(UploadSessionSpec spec) async {
    final outcome = await runner.run(spec);
    if (outcome.status == ResilientUploadStatus.failed) {
      // Dev diagnostics: the RAW engine error behind the mapped category —
      // this is what a bare UNK-01 on 9F is hiding.
      DevUploadLog.instance.add(
        'engine failed (category=${(outcome.category ?? UploadErrorCategory.unknown).wireName}, '
        'retriesExhausted=${outcome.autoRetriesExhausted}, '
        'reason=${manager.lastFailureReason ?? '-'})',
        error: manager.lastFailureError,
      );
    }
    return outcome;
  }

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

  // ── Step timeline (Screen 9's live step tracker) ───────────────────────────
  // Broadcast-with-replay, matching the watch() idiom above. The orchestrator
  // transitions steps at the same points it logs to DevUploadLog; the terminal
  // methods below keep the timeline consistent with the flow's terminal truth
  // (fail → the running step goes red; cancel → the rest is struck; completed
  // → finalize flips done) so the two surfaces can never disagree.
  final StreamController<UploadFlowTimeline> _timelineRelay =
      StreamController<UploadFlowTimeline>.broadcast();
  UploadFlowTimeline _timeline = UploadFlowTimeline.initial();

  /// The engine's held-back `completed` snapshot (real totals) — released by
  /// [markCompleted] once finalize confirms QUEUED.
  UploadProgress? _held;
  UploadEngine? _engine;
  StreamSubscription<UploadProgress>? _sub;
  bool _terminal = false;

  /// Orchestrator hook: a cancel signal must reach the WHOLE flow (pack token,
  /// engine, finalize skip), not just the engine.
  void Function()? onCancelRequested;

  /// The id of the project the backend MINTED for this flow, once it exists.
  ///
  /// The one fact the post-upload screen cannot derive for itself: the local
  /// session's project id is a device-side id, and only `POST /projects` knows
  /// the remote one. Carried here rather than re-resolved downstream so the
  /// screen that offers "Generate 3D model" points at the project the photos
  /// actually went into — a re-derived id that missed would 404 a paid button.
  ///
  /// Null until the create-project step succeeds, and null forever on a flow
  /// that failed before it: the screen degrades to no button rather than to a
  /// broken one.
  String? remoteProjectId;

  /// False once the flow reached completed/failed/cancelled — a terminal flow
  /// is replaced (not reused) by the next start.
  bool get isActive => !_terminal;

  /// The latest snapshot (test/diagnostic convenience; the screen streams).
  UploadProgress get current => _current;

  /// The latest step-timeline snapshot (test/diagnostic convenience).
  UploadFlowTimeline get timeline => _timeline;

  // ── UploadProgressSource ───────────────────────────────────────────────────

  @override
  Stream<UploadProgress> watch() async* {
    yield _current; // replay the current snapshot to a new subscriber
    yield* _relay.stream;
  }

  /// The step-timeline feed Screen 9's tracker observes (replay-current, same
  /// idiom as [watch]). Live counters for the transfer step do NOT ride this
  /// stream — the screen composes them from the byte/file feed above.
  Stream<UploadFlowTimeline> watchTimeline() async* {
    yield _timeline;
    yield* _timelineRelay.stream;
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

  void _applyTimeline(UploadFlowTimeline next) {
    if (identical(next, _timeline)) return; // invalid transition → no-op
    _timeline = next;
    if (!_timelineRelay.isClosed) _timelineRelay.add(next);
  }

  /// Raw diagnostics never reach a production build's memory, matching the
  /// DevUploadLog gate — the timeline's devDetail is dev-flavor-only data.
  static List<String> _gatedDevDetail(List<String> lines) =>
      kAppEnvironment.isProduction ? const [] : lines;

  /// Orchestrator hook: step [id] began.
  void stepStarted(UploadFlowStepId id, {List<String> devDetail = const []}) {
    if (_terminal) return;
    _applyTimeline(_timeline.start(id, devDetail: _gatedDevDetail(devDetail)));
  }

  /// Orchestrator hook: step [id] finished. [info] must be prod-safe
  /// (counts/sizes only); raw ids/paths go in [devDetail].
  void stepCompleted(
    UploadFlowStepId id, {
    String? info,
    List<String> devDetail = const [],
  }) {
    if (_terminal) return;
    _applyTimeline(_timeline.complete(
      id,
      info: info,
      devDetail: _gatedDevDetail(devDetail),
    ));
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
          // Per-attempt failure — the runner may still auto-retry. The step
          // tracker shows AT MOST a retrying note; it flips to failed only on
          // the runner's TERMINAL outcome (via fail()).
          _applyTimeline(
              _timeline.updateInfo(UploadFlowStepId.transfer, 'Retrying…'));
        case UploadStatus.idle:
          break; // pre-start replay — the flow is already inProgress
        default:
          // A fresh attempt is moving again → clear any retrying note.
          if (p.status == UploadStatus.inProgress) {
            _applyTimeline(
                _timeline.updateInfo(UploadFlowStepId.transfer, null));
          }
          _push(p);
      }
    });
  }

  /// Finalize confirmed QUEUED → release the held completed snapshot. This is
  /// the ONLY way the screen ever sees `completed`.
  void markCompleted() {
    if (_terminal) return;
    _terminal = true;
    DevUploadLog.instance.add('flow COMPLETED (job QUEUED)');
    // Safety net: the finalize step flips done with the flow's completion
    // (a no-op when the orchestrator already completed it explicitly).
    _applyTimeline(_timeline.complete(UploadFlowStepId.finalize));
    _push((_held ?? _current).copyWith(status: UploadStatus.completed));
    unawaited(_sub?.cancel());
  }

  /// Terminal failure: the error OBJECT rides the stream (Screen 9 classifies
  /// it via classifyUploadFailure — raw detail is never rendered), followed by
  /// a failed snapshot for late subscribers.
  void fail(Object error) {
    if (_terminal) return;
    _terminal = true;
    // Dev diagnostics: EVERY terminal failure passes through here — this line
    // is what turns a bare 9F code into an actionable raw error in the panel.
    DevUploadLog.instance.add('flow FAILED', error: error);
    // The step that was running (or next up) goes red — with the raw error as
    // dev-only detail; the prod UI never renders it (9F stays mapped-only).
    _applyTimeline(_timeline.failRunning(
      devDetail: _gatedDevDetail(['${error.runtimeType}: $error']),
    ));
    if (!_relay.isClosed) _relay.addError(error);
    _push(_current.copyWith(status: UploadStatus.failed));
    unawaited(_sub?.cancel());
  }

  /// Terminal cancel (transfer aborted, local captures retained). No-op when
  /// the engine's own cancelled snapshot already came through.
  void markCancelled() {
    if (_terminal) return;
    _terminal = true;
    _applyTimeline(_timeline.cancelRemaining());
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
      progress.stepStarted(UploadFlowStepId.prepare);
      DevUploadLog.instance.add('flow started');

      // Kick the backend wake-up NOW so it overlaps the (potentially long)
      // pack below; awaited before the first real backend call. Best-effort:
      // its failure must never fail the flow (the real call just pays the
      // cold start itself).
      final warming = _warmUp?.call();

      final backend = _backendFactory();
      final ctx = await _resolveContext();
      _checkCancel();
      DevUploadLog.instance.add(
          'context resolved (project="${ctx.projectName}", '
          'localProjectId=${ctx.localProjectId.isEmpty ? '<empty>' : ctx.localProjectId}, '
          'sessionId=${ctx.captureSessionId.isEmpty ? '<empty>' : ctx.captureSessionId}, '
          'variant=${ctx.variant.id}, mode=${ctx.mode.id})');

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
      DevUploadLog.instance
          .add('bundle packed (${bundle.totalImages} images + manifest)');
      progress.stepCompleted(
        UploadFlowStepId.prepare,
        // images + manifest — the same count finalize verifies against.
        info: '${bundle.totalImages + 1} files · '
            '${formatMb(bundle.totalBytes)} MB',
        devDetail: [
          'bundle: ${bundle.path}',
          for (final e in bundle.perLevelCounts.entries)
            '${e.key}: ${e.value} images',
        ],
      );

      if (warming != null) {
        try {
          await warming;
        } catch (e) {
          // Warm-up is best-effort by contract; never mask the flow with it.
          DevUploadLog.instance.add('warmup failed (ignored)', error: e);
        }
      }
      _checkCancel();

      progress.stepStarted(UploadFlowStepId.createProject);
      final String remoteProjectId;
      if (_isReusableProjectId(ctx.localProjectId)) {
        // The project was ALREADY created at naming time (create_project_screen
        // → POST /projects, DRAFT). Reuse it so the single project transitions
        // DRAFT → UPLOADING → PROCESSING instead of stranding it as an empty
        // draft and spawning a duplicate. No POST /projects here — the name and
        // size are already correct on the server.
        remoteProjectId = ctx.localProjectId;
        DevUploadLog.instance.add(
            'reusing existing project (id=$remoteProjectId); skipping POST /projects; '
            'POST /jobs (expectedFiles=${bundle.totalImages + 1}) …');
        progress.remoteProjectId = remoteProjectId;
        progress.stepCompleted(
          UploadFlowStepId.createProject,
          info: 'Using existing project',
          devDetail: ['reused remoteProjectId=$remoteProjectId'],
        );
      } else {
        // No usable server project (empty/unresolvable id, or an offline
        // optimistic `pending_…` id that cannot own a job): create one now.
        // `mode` is the PROJECT capture-mode enum (guided|manual) — NOT the
        // full/meshy capture mode `ctx.mode` (that is only valid for POST
        // /jobs `captureMode`, which is sent below). The create form's
        // guided/manual choice is not carried into the upload context, so this
        // fallback sends the valid default 'guided'.
        DevUploadLog.instance.add('POST /projects …');
        remoteProjectId = await backend.createProject(
          name: ctx.projectName,
          size: ctx.objectSize,
          mode: 'guided',
        );
        _checkCancel();
        DevUploadLog.instance.add('project created (remoteId=$remoteProjectId); '
            'POST /jobs (expectedFiles=${bundle.totalImages + 1}) …');
        progress.remoteProjectId = remoteProjectId;
        progress.stepCompleted(
          UploadFlowStepId.createProject,
          devDetail: ['remoteProjectId=$remoteProjectId'],
        );
      }

      progress.stepStarted(UploadFlowStepId.createJob);
      final job = await backend.createJob(
        projectId: remoteProjectId,
        objectSize: ctx.objectSize,
        captureVariant: ctx.variant.id,
        captureMode: ctx.mode.id,
        // MUST equal the bundle's real content (exact-checked at finalize):
        // every staged image + the manifest.
        expectedFilesCount: bundle.totalImages + 1,
        idempotencyKey: _uuid(),
      );
      _checkCancel();

      DevUploadLog.instance.add('job created (jobId=${job.jobId})');
      progress.stepCompleted(
        UploadFlowStepId.createJob,
        devDetail: [
          'jobId=${job.jobId}',
          'keyPrefix=${job.keyPrefix}',
          'expectedFiles=${bundle.totalImages + 1}',
        ],
      );
      final spec = buildUploadSessionSpec(
        bundle: bundle,
        keyPrefix: job.keyPrefix,
        manifestKey: job.manifestKey,
        sessionId: job.jobId,
        fileSize: _fileSize,
      );
      DevUploadLog.instance.add(
          'upload spec built (${spec.totalFiles} files); starting transfer …');
      progress.stepStarted(UploadFlowStepId.transfer);

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
          DevUploadLog.instance
              .add('transfer complete; POST /jobs/${job.jobId}/finalize …');
          progress.stepCompleted(
            UploadFlowStepId.transfer,
            info: '${spec.totalFiles} files',
          );
          await _finalize(backend, job.jobId, spec.totalFiles);
      }
    } on _FlowCancelled {
      progress.markCancelled();
    } on BundlePackException catch (e, st) {
      if (e.isCancelled || _cancelRequested) {
        progress.markCancelled();
      } else {
        DevUploadLog.instance.add('bundle pack threw', error: e, stack: st);
        progress.fail(e);
      }
    } catch (e, st) {
      if (_cancelRequested) {
        progress.markCancelled();
      } else {
        DevUploadLog.instance.add('flow step threw', error: e, stack: st);
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
    progress.stepStarted(UploadFlowStepId.finalize);
    try {
      final state = await backend.finalizeJob(
        jobId: jobId,
        reportedFilesCount: reportedFilesCount,
      );
      DevUploadLog.instance.add('finalize returned state=$state');
      if (state != 'QUEUED') {
        progress.fail(UploadFlowFailure(
          UploadErrorCategory.server,
          detail: 'finalize returned state=$state',
        ));
        return;
      }
      progress.stepCompleted(
        UploadFlowStepId.finalize,
        devDetail: ['state=$state'],
      );
      progress.markCompleted();
    } catch (e) {
      // 422 VERIFICATION_FAILED / 409 / transport — classified by the screen.
      progress.fail(e);
    }
  }

  /// Whether [id] names a real, reusable SERVER project (created at naming
  /// time). A real project owns a job, so the flow reuses it and skips
  /// `POST /projects`. Excluded — and therefore routed to the create-project
  /// fallback — are the empty/unresolvable id and the offline optimistic
  /// `pending_…` id minted by ProjectsNotifier.create (projects_notifier.dart),
  /// which is a device-local placeholder the server has never seen.
  static bool _isReusableProjectId(String id) =>
      id.isNotEmpty && !id.startsWith(kPendingProjectIdPrefix);

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
    _install(orchestrator.progress);
    unawaited(orchestrator.run());
  }

  /// Installs a flow surface as the active one and wires the post-upload
  /// refresh: the flow's terminal `completed` (finalize confirmed QUEUED — the
  /// backend project now exists as PROCESSING with its photo count) triggers a
  /// [projectsProvider] refresh so the new project appears on All Projects
  /// without a restart. Application-layer wiring by design — no widget owns it.
  void _install(UploadFlowProgress progress) {
    state = progress;
    StreamSubscription<UploadProgress>? sub;
    sub = progress.watch().listen(
      (p) {
        switch (p.status) {
          case UploadStatus.completed:
            unawaited(_refreshProjectsAfterUpload());
            unawaited(sub?.cancel());
          case UploadStatus.failed:
          case UploadStatus.cancelled:
            unawaited(sub?.cancel()); // terminal without a new remote project
          default:
            break;
        }
      },
      // Terminal failures ride the stream as error objects (for Screen 9F's
      // classification) — irrelevant here, but they must not go unhandled.
      onError: (_, __) {},
    );
  }

  /// Test seam: installs [progress] exactly like [start] does, without
  /// constructing the production orchestrator (no Hive/network/filesystem).
  @visibleForTesting
  void installForTest(UploadFlowProgress progress) => _install(progress);

  /// Best-effort: a failed refresh never surfaces into the (already
  /// successful) upload flow — the Hub revalidates again on its next visit.
  Future<void> _refreshProjectsAfterUpload() async {
    try {
      await ref.read(projectsProvider.notifier).refresh();
    } catch (_) {/* keep the upload success; the list refreshes later */}
  }

  /// Reads the session context from the live providers/stores. Throws (into
  /// the orchestrator's catch → 9F) when no capture session is resolvable.
  Future<UploadFlowContext> _resolveContext() async {
    // The progression controller is NOT wired into the live capture flow (its
    // provider stays null on-device — the flow sequences A→B→C via GoRouter;
    // see level_progression_provider.dart's SCOPE note), so the snapshot is
    // derived from the SAME live sources the Summary gate reads: config +
    // flow variant + the per-level ledgers.
    var progression = ref.read(levelProgressionControllerProvider);
    if (progression == null) {
      progression = progressionFromLedger(
        ref.read(captureConfigProvider),
        variant: ref.read(captureFlowVariantProvider),
        registry: ref.read(levelCaptureLedgerRegistryProvider),
        mode: ref.read(captureModeProvider),
      );
      DevUploadLog.instance.add(
          'progression derived from ledger (${progression.levels.map((l) => '${l.levelCode}=${l.acceptedCount}').join(', ')})');
    }
    if (progression.levels.every((l) => l.acceptedCount == 0)) {
      throw StateError('no captured photos to upload');
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

    // Object SIZE is a property of the project (chosen at create, persisted
    // per project — the server Project DTO does not carry it back). Source it
    // so POST /jobs declares the SAME size the project was created with; the
    // server rejects a mismatch with SIZE_MISMATCH. Falls back to 'medium'
    // only for a legacy/never-persisted project (matching the prior hardcoded
    // default). Reads by whatever id resolved above (a real or a pending id —
    // create_project_screen persists it under either).
    var objectSize = 'medium';
    if (projectId.isNotEmpty) {
      try {
        final size = await ref
            .read(levelProgressionStoreProvider)
            .loadObjectSizeOrNull(projectId);
        if (size != null) objectSize = size.apiValue;
      } catch (_) {
        // Unreadable store → keep the 'medium' default.
      }
    }

    // Name the remote project from the local one when it is in the loaded
    // list; otherwise a dated fallback (the upload must not block on the list).
    // Only the FALLBACK create path (no real project) ever sends this name —
    // when an existing project is reused, POST /projects is skipped entirely
    // and the name is correct by construction.
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
      mode: ref.read(captureModeProvider),
      workspaceRoot: '${docs.path}/upload_workspace',
      objectSize: objectSize,
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
        captureModeId: context.mode.id,
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
