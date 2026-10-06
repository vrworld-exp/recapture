// lib/application/upload/pending_upload_coordinator.dart
//
// The ONE owner of the path "capture waiting on the phone → uploaded project"
// (offline capture, Step B2). It connects pieces that already existed and were
// never wired together:
//
//   pendingCapturesProvider (what is waiting, durable, owner-scoped)
//        │  policy: canAutoUpload (Wi-Fi rule) / user taps
//        ▼
//   OfflineUploadQueue  ── durable job list, FIFO single-flight drain, 500 ms
//        │                 debounced connectivity, reachability back-off,
//        │                 userPaused ≠ offlineQueued, restore after a kill
//        ▼  (one drained job = one run of THIS class as the queue's runner)
//   UploadFlowOrchestrator ── the SAME pipeline the Summary's Upload runs:
//                             project (reused) → POST /jobs → chunked upload
//                             (resumable part ETags) → finalize → QUEUED
//
// No second upload engine and no second retry layer: transfer, part retry and
// session retry stay in ChunkedUploadManager / ResilientUploadRunner.
//
// HOW A RESUME AVOIDS A SECOND JOB. Each capture sends a STABLE POST /jobs
// Idempotency-Key ([PendingCapture.jobIdempotencyKey]). Re-running a capture
// after a network drop, an app kill or a reboot therefore REPLAYS the original
// job — same job id, same upload-progress key — and the engine continues from
// the part ETags it saved, instead of starting again from 0 under a new job.
//
// EXACTLY ONE SERVER PROJECT (Step B4). A capture of an offline-created project
// carries a `pending_…` id. The offline outbox is the ONLY creator of offline
// projects; before uploading such a capture this coordinator makes sure the
// outbox has a create for it (re-creating it from the capture after a logout
// cleared the outbox), drains the outbox, and uploads only once the project has
// been reconciled to its server id. The upload flow never receives a `pending_`
// id from here.
//
// ONE UPLOAD AT A TIME. The queue drains one job at a time, and every run waits
// for [UploadFlowNotifier.whenIdle] — the guard the Summary's own Upload shares.
//
// OWNER-SCOPED. The queue is rebuilt per signed-in user and only ever sees that
// user's captures. Signing out stops it; another user never uploads them.
//
// NATIVE ONLY. On web ([offlineCaptureCapabilityProvider] false) this does
// nothing at all.
//
// BACKGROUND (Step B5). In the foreground only the Dart queue drives resume.
// When the app goes to the background with captures waiting, the Android
// WorkManager resume request is scheduled (UNMETERED when only Wi-Fi-bound Full
// captures wait) and it is cancelled again on return / when nothing waits.
// ⚠ The native worker's transport is still the documented stub
// (UploadResumeWorker.runResumeStub): an upload resumes in the background while
// the app process is alive (the Dart queue keeps running, and the upload
// foreground service keeps the process alive during a transfer), but NOT after
// Android has killed the process — that needs a headless Flutter engine.
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/local/upload_queue_box.dart';
import '../../domain/capture/capture_flow_variant.dart';
import '../../domain/capture/capture_mode.dart';
import '../../domain/entities/capture_config.dart';
import '../../domain/entities/upload_progress.dart';
import '../../domain/upload/auto_upload_policy.dart';
import '../../domain/upload/capture_bundle.dart';
import '../../domain/upload/pending_capture.dart';
import '../../domain/upload/upload_failure.dart';
import '../../domain/upload/upload_queue_entry.dart';
import '../../domain/upload/upload_session_spec.dart';
import '../../platform/connectivity_watcher.dart';
import '../../platform/upload_foreground_service.dart';
import '../../utils/analytics.dart';
import '../capture/ledger/level_capture_ledger_registry.dart';
import '../capture/progression/level_progression_builder.dart';
import '../capture/progression/level_progression_provider.dart';
import '../connectivity/connectivity_providers.dart';
import '../offline/offline_queue_notifier.dart';
import '../projects/projects_notifier.dart';
import '../warmup/backend_warmup.dart';
import 'offline_capture_capability.dart';
import 'offline_upload_queue.dart';
import 'pending_capture_saver.dart';
import 'pending_captures_notifier.dart';
import 'resilient_upload_runner.dart';
import 'upload_auth_session.dart';
import 'upload_flow.dart';
import 'upload_jobs_backend.dart';
import 'upload_prefs_provider.dart';

/// Failure reasons a pending capture can carry beyond an
/// [UploadErrorCategory] wire name. Hand-mapped to card copy.
abstract final class PendingFailureCodes {
  /// The packed photos are not on the phone any more (app storage cleared).
  /// Delete is the only action — retrying could never succeed.
  static const filesMissing = 'FILES_MISSING';

  /// The project was deleted on the server before the upload.
  static const projectNotFound = 'PROJECT_NOT_FOUND';

  /// A plan / usage limit refused the upload. Photos stay; Retry after upgrade.
  static const planLimit = 'PLAN_LIMIT';

  /// An active Full upload parked because the phone moved to mobile data.
  static const waitingForWifi = 'WAITING_WIFI';
}

/// Who asked for an upload — analytics only.
enum PendingUploadTrigger { auto, manual, uploadAll }

/// The answer to an "Upload now" tap.
enum UploadNowResult {
  started,

  /// A Full capture on mobile data: show "This upload is about N MB. Use
  /// mobile data?" and call again with `confirmedMobileData: true`.
  needsMobileDataConfirm,

  /// No network at all.
  offline,

  /// The capture is gone, or cannot be retried (files missing).
  unavailable,
}

/// What the Summary's online Upload did.
enum SummaryUploadResult {
  /// The flow is running — go to the Uploading screen, as before.
  started,

  /// Another upload is running (or the offline project is not on the server
  /// yet): the capture was saved on the phone and will upload after it.
  savedForLater,
}

/// Coordinator state the cards read beside the pending list.
@immutable
class PendingUploadState {
  const PendingUploadState({this.activeLocalId, this.needsLogin = false});

  /// The capture uploading right now, if any.
  final String? activeLocalId;

  /// An upload failed on authentication. Nothing is discarded; the drain stops
  /// until the user signs in again ("Log in again to upload").
  final bool needsLogin;

  PendingUploadState copyWith({
    String? activeLocalId,
    bool clearActive = false,
    bool? needsLogin,
  }) =>
      PendingUploadState(
        activeLocalId: clearActive ? null : (activeLocalId ?? this.activeLocalId),
        needsLogin: needsLogin ?? this.needsLogin,
      );
}

/// Everything the coordinator touches outside Riverpod state. Production
/// defaults; tests override [pendingUploadDepsProvider] with fakes.
class PendingUploadDeps {
  const PendingUploadDeps({
    required this.backend,
    required this.engine,
    required this.documentsDir,
    required this.queueStore,
    this.foregroundService,
    this.warmUp,
    this.connectivityDebounce = const Duration(milliseconds: 500),
    this.sleep,
    this.observeLifecycle = true,
  });

  final UploadJobsBackend Function() backend;
  final UploadEngine Function(String jobId) engine;
  final Future<String> Function() documentsDir;
  final UploadQueueStore queueStore;
  final UploadForegroundServiceClient? foregroundService;
  final Future<void> Function()? warmUp;
  final Duration connectivityDebounce;
  final Future<void> Function(Duration)? sleep;
  final bool observeLifecycle;
}

final pendingUploadDepsProvider = Provider<PendingUploadDeps>((ref) {
  return PendingUploadDeps(
    backend: () => DioUploadJobsBackend(ref.read(uploadApiDioProvider)),
    engine: (jobId) => buildProductionUploadEngine(ref, jobId),
    documentsDir: () async => (await getApplicationDocumentsDirectory()).path,
    queueStore: HiveUploadQueueStore(),
    foregroundService: UploadForegroundServiceClient(),
    warmUp: () => ref.read(backendWarmupServiceProvider).warmUp(),
  );
});

/// keepAlive: the coordinator must outlive every screen.
final pendingUploadCoordinatorProvider =
    NotifierProvider<PendingUploadCoordinator, PendingUploadState>(
  PendingUploadCoordinator.new,
);

class PendingUploadCoordinator extends Notifier<PendingUploadState>
    implements UploadJobRunner {
  PendingUploadDeps get _deps => ref.read(pendingUploadDepsProvider);
  PendingCapturesNotifier get _pending =>
      ref.read(pendingCapturesProvider.notifier);
  UploadFlowNotifier get _flow => ref.read(uploadFlowProvider.notifier);

  OfflineUploadQueue? _queue;
  String? _queueOwner;
  Future<void> _ready = Future<void>.value();
  int _ownerGen = 0;

  UploadFlowOrchestrator? _activeFlow;
  String? _activeLocalId;
  bool _policyHeld = false;
  final Map<String, PendingUploadTrigger> _triggers = {};
  final Map<String, DateTime> _startedAt = {};
  AppLifecycleListener? _lifecycle;
  bool _evaluateScheduled = false;

  @override
  PendingUploadState build() {
    if (!ref.watch(offlineCaptureCapabilityProvider)) {
      return const PendingUploadState();
    }

    _flow.pendingRetryHandler = _retryFromFailedScreen;

    ref.listen<String?>(currentUserIdProvider, (_, owner) {
      _onOwnerChanged(owner);
    }, fireImmediately: true);

    ref.listen<bool>(isOnlineProvider, (_, online) {
      _queue?.onConnectivityChanged(online);
      _onNetworkChanged();
    });
    ref.listen<AppNetworkType>(
        currentNetworkTypeProvider, (_, __) => _onNetworkChanged());
    ref.listen<AutoUploadSettings>(
        autoUploadSettingsProvider, (_, __) => _onNetworkChanged());
    ref.listen<List<PendingCapture>>(
        pendingCapturesProvider, (_, __) => _scheduleEvaluate());

    if (_deps.observeLifecycle) {
      _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    }
    ref.onDispose(() {
      _lifecycle?.dispose();
      _queue?.dispose();
      _queue = null;
    });
    return const PendingUploadState();
  }

  /// Completes once the current owner's queue has been restored. Tests and
  /// callers that need a settle point await it.
  Future<void> whenReady() => _ready;

  /// Resolves when the queue's in-flight drain (if any) finishes.
  Future<void> get idle async {
    await _ready;
    await (_queue?.idle ?? Future<void>.value());
  }

  // ── user actions ──────────────────────────────────────────────────────────

  /// "Upload now" / "Retry" / "Resume" on a card. Overrides the Wi-Fi rule; a
  /// Full capture on mobile data first needs the size confirm.
  Future<UploadNowResult> uploadNow(
    String localId, {
    PendingUploadTrigger trigger = PendingUploadTrigger.manual,
    bool confirmedMobileData = false,
  }) async {
    await _ready;
    var c = _pending.byLocalId(localId);
    final queue = _queue;
    if (c == null || queue == null) return UploadNowResult.unavailable;
    if (c.lastErrorCode == PendingFailureCodes.filesMissing) {
      return UploadNowResult.unavailable;
    }
    final network = _network;
    if (network == UploadNetwork.none) return UploadNowResult.offline;
    if (needsMobileDataConfirm(c, network, _settings)) {
      if (!confirmedMobileData) return UploadNowResult.needsMobileDataConfirm;
      Analytics.logEvent(AnalyticsEvents.mobileDataUploadConfirmed, {
        'size_mb': _mb(c.byteCount),
      });
    }

    c = await _pending.mutate(
      localId,
      (p) => p.copyWith(
        userPaused: false,
        mobileDataApproved: p.mobileDataApproved || confirmedMobileData,
        state: p.state == PendingCaptureState.uploading
            ? p.state
            : PendingCaptureState.waitingNetwork,
        clearLastErrorCode: p.state != PendingCaptureState.uploading,
      ),
    );
    if (c == null) return UploadNowResult.unavailable;
    if (state.needsLogin) state = state.copyWith(needsLogin: false);

    if (_activeLocalId == localId) {
      _activeFlow?.progress.resume(); // a paused / parked transfer moves on
      await queue.resumeUserPaused(localId);
      return UploadNowResult.started;
    }
    _triggers[localId] = trigger;
    await _ensureQueued(c);
    unawaited(queue.autoResumeQueued()); // forces a re-probe when queued
    return UploadNowResult.started;
  }

  /// "Upload all" on the Projects strip. Captures that would need the
  /// mobile-data confirm are returned rather than started.
  Future<List<String>> uploadAll() async {
    await _ready;
    final needConfirm = <String>[];
    for (final c in List.of(ref.read(pendingCapturesProvider))) {
      if (c.localId == _activeLocalId ||
          c.lastErrorCode == PendingFailureCodes.filesMissing) {
        continue;
      }
      final r =
          await uploadNow(c.localId, trigger: PendingUploadTrigger.uploadAll);
      if (r == UploadNowResult.needsMobileDataConfirm) {
        needConfirm.add(c.localId);
      }
    }
    return needConfirm;
  }

  /// "Pause": the transfer parks at a part boundary and is never resumed
  /// automatically — only [resume].
  Future<void> pause(String localId) async {
    await _ready;
    await _pending.mutate(localId, (p) => p.copyWith(userPaused: true));
    await _queue?.markUserPaused(localId);
    if (_activeLocalId == localId) _activeFlow?.progress.pause();
  }

  /// "Resume" after [pause].
  Future<UploadNowResult> resume(String localId) => uploadNow(localId);

  /// Deletes a never-uploaded capture: stops it if it is uploading, forgets it,
  /// and removes its photos from the phone. The caller has already shown the
  /// "removes the photos from this phone permanently" confirmation.
  Future<void> deletePending(String localId) async {
    await _ready;
    final c = _pending.byLocalId(localId);
    if (c == null) return;
    if (_activeLocalId == localId) {
      _activeFlow?.progress.cancel();
      await _flow.whenIdle();
    }
    await _queue?.cancel(localId);
    await _pending.remove(localId);
    await _deleteBundle(c);
    Analytics.logEvent(AnalyticsEvents.pendingCaptureDeleted, {
      'capture_mode': c.captureMode,
      'age_hours': _ageHours(c),
    });
  }

  /// "Upload as new project" after the old project was deleted on the server:
  /// the capture gets a new offline project (created by the outbox, as every
  /// offline project is) and a fresh job key, then uploads normally.
  Future<void> uploadAsNewProject(String localId) async {
    await _ready;
    final c = _pending.byLocalId(localId);
    if (c == null) return;
    final tempId = '$kPendingProjectIdPrefix'
        '${DateTime.now().toUtc().microsecondsSinceEpoch}';
    await ref.read(offlineQueueProvider.notifier).ensureCreateProject(
          tempId: tempId,
          name: c.projectName,
          size: c.objectSize,
        );
    await _pending.mutate(
      localId,
      (p) => p.copyWith(
        projectId: tempId,
        jobKeyGeneration: p.jobKeyGeneration + 1,
        state: PendingCaptureState.savedLocal,
        clearLastErrorCode: true,
        clearUploadSessionId: true,
      ),
    );
    await uploadNow(localId);
  }

  /// The Summary's Upload while ONLINE (native). Runs the normal flow — same
  /// screen, same taps — but packs into a durable bundle and records the
  /// capture first (inside the flow's prepare step), so an app kill
  /// mid-upload leaves a capture that resumes on the next launch.
  Future<SummaryUploadResult> uploadFromSummary() async {
    await _ready;
    final saver = ref.read(pendingCaptureSaverProvider);

    // Resolve an offline project to its server id BEFORE the flow, so the flow
    // reuses the project instead of creating one (B4).
    var ctx = await resolveLiveUploadContext(ref);
    if (ctx.localProjectId.startsWith(kPendingProjectIdPrefix)) {
      final serverId = await _resolveServerProjectId(
        tempId: ctx.localProjectId,
        name: ctx.projectName,
        size: ctx.objectSize,
      );
      if (serverId == null) {
        await saver.saveFinishedCapture();
        return SummaryUploadResult.savedForLater;
      }
      ctx = ctx.withProjectId(serverId);
    }
    if (_flow.isBusy) {
      await saver.saveFinishedCapture();
      return SummaryUploadResult.savedForLater;
    }

    final localId = randomUuidV4();
    final resolved = ctx;
    final orchestrator = UploadFlowOrchestrator(
      resolveContext: () async => resolved,
      pack: ({
        required context,
        required session,
        required device,
        cancelToken,
      }) async {
        final (_, bundle) = await saver.packAndRecord(
          context: context,
          localId: localId,
          initialState: PendingCaptureState.uploading,
          cancelToken: cancelToken,
        );
        return bundle;
      },
      backend: _deps.backend,
      engineFactory: _deps.engine,
      warmUp: _deps.warmUp,
      uuid: () => PendingCapture.jobKeyFor(localId),
    );
    if (!_flow.installPending(orchestrator, localId)) {
      await saver.saveFinishedCapture();
      return SummaryUploadResult.savedForLater;
    }
    _setActive(localId, orchestrator);
    unawaited(() async {
      await orchestrator.run();
      final outcome = await _settle(localId, orchestrator.progress);
      if (outcome.status == ResilientUploadStatus.failed) {
        // A network failure outside the queue: hand it to the queue so it
        // resumes on its own when the network returns.
        final c = _pending.byLocalId(localId);
        if (c != null) await _ensureQueued(c);
      }
      _scheduleEvaluate();
    }());
    return SummaryUploadResult.started;
  }

  // ── UploadJobRunner: one drained queue job ────────────────────────────────

  @override
  Future<ResilientUploadOutcome> run(UploadSessionSpec spec) async {
    final localId = spec.sessionId;
    var c = _pending.byLocalId(localId);
    if (c == null || state.needsLogin || c.userPaused) return _cancelled;
    final trigger = _triggers.remove(localId) ?? PendingUploadTrigger.auto;

    final network = _network;
    if (network == UploadNetwork.none) return _networkFailure;
    if (trigger == PendingUploadTrigger.auto &&
        !canAutoUpload(c, network, _settings)) {
      // Held by the Wi-Fi rule: back on the shelf until the network allows it
      // or the user taps Upload now.
      await _pending.mutate(
          localId, (p) => p.copyWith(state: PendingCaptureState.savedLocal));
      return _cancelled;
    }

    final dir = '${await _deps.documentsDir()}/${c.bundleRelPath}';
    if (!_bundleComplete(dir, c)) {
      await _markFailed(c, PendingFailureCodes.filesMissing);
      return _cancelled;
    }

    // B4: never upload into a `pending_` project.
    if (c.hasPendingProject) {
      final serverId = await _resolveServerProjectId(
        tempId: c.projectId,
        name: c.projectName,
        size: c.objectSize,
      );
      if (serverId == null) {
        await _pending.mutate(localId,
            (p) => p.copyWith(state: PendingCaptureState.waitingNetwork));
        return _networkFailure; // outbox could not create it yet → back off
      }
      c = await _pending.mutate(localId, (p) => p.copyWith(projectId: serverId));
      if (c == null) return _cancelled;
    }

    // One upload at a time, shared with the Summary's own Upload.
    final orchestrator = _orchestratorFor(c, dir);
    while (!_flow.installPending(orchestrator, localId)) {
      await _flow.whenIdle();
      if (_pending.byLocalId(localId) == null) return _cancelled;
    }

    c = await _pending.mutate(
      localId,
      (p) => p.copyWith(
        state: PendingCaptureState.uploading,
        attempts: p.attempts + 1,
        clearLastErrorCode: true,
      ),
    );
    if (c == null) {
      orchestrator.progress.cancel();
      return _cancelled;
    }
    Analytics.logEvent(AnalyticsEvents.pendingUploadStarted, {
      'capture_mode': c.captureMode,
      'trigger': trigger.name == 'uploadAll' ? 'upload_all' : trigger.name,
      'network': network == UploadNetwork.unmetered ? 'wifi' : 'cellular',
      'age_hours': _ageHours(c),
    });

    _setActive(localId, orchestrator);
    await orchestrator.run();
    return _settle(localId, orchestrator.progress);
  }

  // ── internals: outcomes ───────────────────────────────────────────────────

  static const _cancelled = ResilientUploadOutcome(
    status: ResilientUploadStatus.cancelled,
    attemptsUsed: 0,
  );

  static const _networkFailure = ResilientUploadOutcome(
    status: ResilientUploadStatus.failed,
    attemptsUsed: 0,
    category: UploadErrorCategory.network,
  );

  static const _succeeded = ResilientUploadOutcome(
    status: ResilientUploadStatus.succeeded,
    attemptsUsed: 1,
  );

  /// Turns a finished flow into the record's next state and the queue's
  /// outcome. Every non-network ending returns `cancelled` to the queue (it
  /// drops its job entry) — the RECORD is the durable truth for failures.
  Future<ResilientUploadOutcome> _settle(
    String localId,
    UploadFlowProgress progress,
  ) async {
    _clearActive(localId);
    final c = _pending.byLocalId(localId);
    switch (progress.current.status) {
      case UploadStatus.completed:
        if (c != null) {
          await _pending.mutate(localId,
              (p) => p.copyWith(state: PendingCaptureState.uploaded));
          Analytics.logEvent(AnalyticsEvents.pendingUploadCompleted, {
            'capture_mode': c.captureMode,
            'attempts': c.attempts,
            'age_hours': _ageHours(c),
            'duration_s': _durationS(localId),
          });
          // The card shows the SERVER status (Processing) from here on, so
          // let the list catch up before the pending label disappears.
          try {
            await ref.read(projectsProvider.notifier).refresh();
          } catch (_) {/* the list refreshes on its next visit */}
          await _pending.remove(localId);
          // Local photos go ONLY now that finalize returned QUEUED.
          await _deleteBundle(c);
        }
        _afterQueueChange();
        return _succeeded;

      case UploadStatus.cancelled:
        // The user stopped it (Cancel → Keep as Draft). Kept on the phone and
        // treated as paused: nothing restarts it behind their back.
        if (c != null) {
          await _pending.mutate(
            localId,
            (p) => p.copyWith(
                state: PendingCaptureState.savedLocal, userPaused: true),
          );
        }
        return _cancelled;

      default:
        final error = progress.terminalError;
        final category = classifyUploadFailure(error);
        if (c == null) {
          return category == UploadErrorCategory.network
              ? _networkFailure
              : _cancelled;
        }
        if (category == UploadErrorCategory.network) {
          await _pending.mutate(
            localId,
            (p) => p.copyWith(
              state: PendingCaptureState.waitingNetwork,
              lastErrorCode: UploadErrorCategory.network.wireName,
            ),
          );
          return _networkFailure;
        }
        if (_serverCode(error) == 'PLAN_EXPIRED') {
          // The job's upload plan is valid for UPLOAD_PLAN_TTL_SECONDS (24 h)
          // from JOB creation; a capture paused or offline longer than that
          // can never finish its old job. Move to a FRESH job key and go again
          // — the stable key would otherwise replay the expired job forever.
          await _pending.mutate(
            localId,
            (p) => p.copyWith(
              jobKeyGeneration: p.jobKeyGeneration + 1,
              state: PendingCaptureState.waitingNetwork,
              clearLastErrorCode: true,
              clearUploadSessionId: true,
            ),
          );
          return _networkFailure; // re-probed with back-off, then re-run
        }
        if (category == UploadErrorCategory.auth) {
          // C4: never discard over an auth failure. Keep the record, stop the
          // drain, ask for a login.
          state = state.copyWith(needsLogin: true);
          await _pending.mutate(localId,
              (p) => p.copyWith(state: PendingCaptureState.waitingNetwork));
          return _cancelled;
        }
        await _markFailed(c, _failureCode(error, category));
        return _cancelled;
    }
  }

  Future<void> _markFailed(PendingCapture c, String code) async {
    await _pending.mutate(
      c.localId,
      (p) => p.copyWith(state: PendingCaptureState.failed, lastErrorCode: code),
    );
    Analytics.logEvent(AnalyticsEvents.pendingUploadFailed, {
      'capture_mode': c.captureMode,
      'failure_reason': code,
      'attempts': c.attempts,
    });
  }

  /// The specific reason a server refusal names, mapped to a card label.
  static String _failureCode(Object? error, UploadErrorCategory category) {
    final code = _serverCode(error);
    // POST /jobs answers a missing (or deleted, or not-owned) project with a
    // 404 NOT_FOUND; the project is the only thing it looks up.
    if (code == 'PROJECT_NOT_FOUND' || code == 'NOT_FOUND') {
      return PendingFailureCodes.projectNotFound;
    }
    // Plan refusals: an explicit server code, or HTTP 402. NOT a 429 — that is
    // a rate limit, and "upgrade to upload" would be the wrong advice.
    if ((code != null && kPlanLimitServerCodes.contains(code)) ||
        _httpStatus(error) == 402) {
      return PendingFailureCodes.planLimit;
    }
    return code ?? category.wireName;
  }

  static int? _httpStatus(Object? error) =>
      error is DioException ? error.response?.statusCode : null;

  static String? _serverCode(Object? error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map && data['code'] is String) return data['code'] as String;
    }
    return null;
  }

  // ── internals: project resolution (B4) ────────────────────────────────────

  /// The server id for offline project [tempId], or null when the outbox
  /// could not create it yet. Never creates a project itself.
  Future<String?> _resolveServerProjectId({
    required String tempId,
    required String name,
    required String size,
  }) async {
    final store = ref.read(levelProgressionStoreProvider);
    final known = await store.reconciledIdFor(tempId);
    if (known != null) return known;

    final waitingOnIt = {
      for (final c in ref.read(pendingCapturesProvider))
        if (c.projectId == tempId) c.localId,
    };
    final outbox = ref.read(offlineQueueProvider.notifier);
    await outbox.ensureCreateProject(tempId: tempId, name: name, size: size);
    await outbox.flush();

    // reconcilePendingCreate re-keys the in-memory records synchronously (the
    // durable mapping is written just after) — so a capture that was waiting
    // on [tempId] and no longer names it names the server id.
    for (final c in ref.read(pendingCapturesProvider)) {
      if (waitingOnIt.contains(c.localId) && c.projectId != tempId) {
        return c.projectId;
      }
    }
    return store.reconciledIdFor(tempId);
  }

  // ── internals: queue + owner lifecycle ────────────────────────────────────

  void _onOwnerChanged(String? owner) {
    if (owner == _queueOwner) return;
    final gen = ++_ownerGen;
    // Stop the previous owner's work. An upload in flight under the old
    // session cannot finish without its tokens; it resumes (same job key) when
    // that owner signs in again.
    if (_activeFlow != null) {
      final flow = _activeFlow!;
      _activeFlow = null;
      _activeLocalId = null;
      flow.progress.cancel();
    }
    _queue?.dispose();
    _queue = null;
    _queueOwner = owner;
    _triggers.clear();
    state = const PendingUploadState();
    if (owner == null) {
      _ready = Future<void>.value();
      unawaited(_deps.foregroundService?.cancelNetworkResume());
      return;
    }
    _ready = _startFor(owner, gen);
  }

  Future<void> _startFor(String owner, int gen) async {
    await ref.read(pendingCapturesProvider.notifier).whenLoaded();
    if (gen != _ownerGen) return;
    final queue = OfflineUploadQueue(
      store: _OwnerScopedQueueStore(
        _deps.queueStore,
        owns: (id) => _pending.byLocalId(id) != null,
      ),
      runner: this,
      initialOnline: ref.read(isOnlineProvider),
      connectivityDebounce: _deps.connectivityDebounce,
      sleep: _deps.sleep,
      deviceType: defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
    );
    _queue = queue;
    // Records written as `uploading` by a process that died are not running.
    for (final c in List.of(ref.read(pendingCapturesProvider))) {
      if (c.state == PendingCaptureState.uploading) {
        await _pending.mutate(c.localId,
            (p) => p.copyWith(state: PendingCaptureState.waitingNetwork));
      }
    }
    await queue.restore();
    if (gen != _ownerGen) return;
    for (final c in List.of(ref.read(pendingCapturesProvider))) {
      if (c.state == PendingCaptureState.waitingNetwork) await _ensureQueued(c);
    }
    _scheduleEvaluate();
  }

  /// Makes sure [c] has a queue job (in the right paused/queued lane).
  Future<void> _ensureQueued(PendingCapture c) async {
    final queue = _queue;
    if (queue == null) return;
    UploadQueueEntry? entry;
    for (final e in queue.entries) {
      if (e.jobId == c.localId) entry = e;
    }
    final exists = entry != null;
    if (exists &&
        !c.userPaused &&
        entry.state == UploadJobState.userPaused) {
      // The user resumed: move the job back to the auto lane.
      await queue.resumeUserPaused(c.localId);
      return;
    }
    if (!exists) {
      // Paused BEFORE the job exists, so an online enqueue cannot start it.
      if (c.userPaused) {
        await queue.enqueuePaused(_specFor(c));
      } else {
        await queue.enqueue(_specFor(c));
      }
    } else if (c.userPaused) {
      await queue.markUserPaused(c.localId);
    }
  }

  static UploadSessionSpec _specFor(PendingCapture c) =>
      UploadSessionSpec(sessionId: c.localId, files: const []);

  void _scheduleEvaluate() {
    if (_evaluateScheduled) return;
    _evaluateScheduled = true;
    scheduleMicrotask(() {
      _evaluateScheduled = false;
      unawaited(_evaluate());
    });
  }

  /// Hands every capture the policy now allows to the queue.
  Future<void> _evaluate() async {
    final queue = _queue;
    if (queue == null || state.needsLogin) return;
    final network = _network;
    final settings = _settings;
    for (final c in List.of(ref.read(pendingCapturesProvider))) {
      if (c.state != PendingCaptureState.savedLocal || c.userPaused) continue;
      if (!canAutoUpload(c, network, settings)) continue;
      final moved = await _pending.mutate(c.localId,
          (p) => p.copyWith(state: PendingCaptureState.waitingNetwork));
      if (moved != null) await _ensureQueued(moved);
    }
  }

  void _onNetworkChanged() {
    final active = _activeLocalId;
    final flow = _activeFlow;
    if (active != null && flow != null) {
      final c = _pending.byLocalId(active);
      if (c != null && !c.userPaused) {
        final online = ref.read(isOnlineProvider);
        final allowed = canAutoUpload(c, _network, _settings);
        if (online && !allowed) {
          // Wi-Fi → mobile data mid-upload of a Full capture the user did not
          // approve: park at the next part boundary, continue on Wi-Fi.
          if (!_policyHeld) {
            _policyHeld = true;
            flow.progress.pause();
            unawaited(_pending.mutate(
              active,
              (p) => p.copyWith(
                state: PendingCaptureState.waitingNetwork,
                lastErrorCode: PendingFailureCodes.waitingForWifi,
              ),
            ));
          }
        } else if (online) {
          final wasHeld = _policyHeld;
          _policyHeld = false;
          // Also releases the engine's own connectivity auto-pause.
          flow.progress.resume();
          if (wasHeld || c.state == PendingCaptureState.waitingNetwork) {
            unawaited(_pending.mutate(
              active,
              (p) => p.copyWith(
                state: PendingCaptureState.uploading,
                clearLastErrorCode: true,
              ),
            ));
          }
        } else if (c.state == PendingCaptureState.uploading) {
          unawaited(_pending.mutate(active,
              (p) => p.copyWith(state: PendingCaptureState.waitingNetwork)));
        }
      }
    }
    _scheduleEvaluate();
  }

  void _setActive(String localId, UploadFlowOrchestrator flow) {
    _activeLocalId = localId;
    _activeFlow = flow;
    _policyHeld = false;
    _startedAt[localId] = DateTime.now();
    state = state.copyWith(activeLocalId: localId);
    unawaited(_deps.foregroundService?.start());
  }

  void _clearActive(String localId) {
    if (_activeLocalId == localId) {
      _activeLocalId = null;
      _activeFlow = null;
      _policyHeld = false;
      state = state.copyWith(clearActive: true);
      unawaited(_deps.foregroundService?.stop());
    }
  }

  void _afterQueueChange() {
    final waiting = ref.read(pendingCapturesProvider).any((c) =>
        c.state == PendingCaptureState.waitingNetwork ||
        c.state == PendingCaptureState.savedLocal);
    if (!waiting) unawaited(_deps.foregroundService?.cancelNetworkResume());
  }

  void _retryFromFailedScreen(String localId) {
    if (_pending.byLocalId(localId) != null) {
      unawaited(uploadNow(localId));
    } else {
      // Failed before the capture was recorded (e.g. during pack): the capture
      // is still in memory — run the Summary path again.
      unawaited(uploadFromSummary());
    }
  }

  // ── internals: B5 background ──────────────────────────────────────────────

  void _onLifecycle(AppLifecycleState s) {
    final fg = _deps.foregroundService;
    if (fg == null) return;
    switch (s) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        final waiting = ref.read(pendingCapturesProvider).where((c) =>
            !c.userPaused &&
            (c.state == PendingCaptureState.waitingNetwork ||
                c.state == PendingCaptureState.savedLocal));
        if (waiting.isEmpty) {
          unawaited(fg.cancelNetworkResume());
        } else {
          // UNMETERED when nothing waiting may use mobile data.
          final unmeteredOnly = waiting.every((c) =>
              !canAutoUpload(c, UploadNetwork.metered, _settings));
          unawaited(fg.scheduleNetworkResume(unmeteredOnly: unmeteredOnly));
        }
      case AppLifecycleState.resumed:
        // Foreground: only the Dart queue drives resume (no double-run).
        unawaited(fg.cancelNetworkResume());
        _onNetworkChanged();
        unawaited(_queue?.autoResumeQueued());
      default:
        break;
    }
  }

  // ── internals: helpers ────────────────────────────────────────────────────

  UploadNetwork get _network {
    if (!ref.read(isOnlineProvider)) return UploadNetwork.none;
    return switch (ref.read(currentNetworkTypeProvider)) {
      AppNetworkType.unmetered => UploadNetwork.unmetered,
      AppNetworkType.metered => UploadNetwork.metered,
      AppNetworkType.none => UploadNetwork.none,
    };
  }

  AutoUploadSettings get _settings => ref.read(autoUploadSettingsProvider);

  UploadFlowOrchestrator _orchestratorFor(PendingCapture c, String dir) {
    final variant = CaptureFlowVariant.fromId(c.flowVariant);
    final mode = CaptureMode.values.firstWhere(
      (m) => m.id == c.captureMode,
      orElse: () => CaptureMode.full,
    );
    final bundle = CaptureBundle(
      path: dir,
      manifestPath: '$dir/$kBundleManifestFileName',
      totalImages: c.frameCount,
      totalBytes: c.byteCount,
      perLevelCounts: c.perLevelCounts,
    );
    return UploadFlowOrchestrator(
      resolveContext: () async => UploadFlowContext(
        localProjectId: c.projectId, // a server id — never `pending_` here
        projectName: c.projectName,
        captureSessionId: c.localId,
        // config/progression/registry feed only the PACK step, which is
        // replaced below by the bundle packed at save time.
        config: CaptureConfig.bundledDefault,
        progression: initialProgressionFromConfig(
          CaptureConfig.bundledDefault,
          variant: variant,
        ),
        registry: LevelCaptureLedgerRegistry(),
        variant: variant,
        mode: mode,
        workspaceRoot: dir,
        objectSize: c.objectSize,
      ),
      pack: ({
        required context,
        required session,
        required device,
        cancelToken,
      }) async =>
          bundle,
      backend: _deps.backend,
      engineFactory: _deps.engine,
      warmUp: _deps.warmUp,
      uuid: () => c.jobIdempotencyKey,
    );
  }

  /// Every file the upload spec will name is on disk.
  static bool _bundleComplete(String dir, PendingCapture c) {
    try {
      if (c.perLevelCounts.isEmpty) return false;
      if (!File('$dir/$kBundleManifestFileName').existsSync()) return false;
      for (final e in c.perLevelCounts.entries) {
        for (var i = 1; i <= e.value; i++) {
          final rel = bundleImageRelPath(e.key, bundleImageFileName(e.key, i));
          if (!File('$dir/$rel').existsSync()) return false;
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _deleteBundle(PendingCapture c) async {
    try {
      final d = Directory('${await _deps.documentsDir()}/${c.bundleRelPath}');
      if (d.existsSync()) await d.delete(recursive: true);
    } catch (_) {/* best-effort: an orphan folder, never a lost upload */}
  }

  static int _mb(int bytes) => (bytes / (1024 * 1024)).round();

  static int _ageHours(PendingCapture c) =>
      DateTime.now().toUtc().difference(c.capturedAt).inHours;

  int _durationS(String localId) {
    final at = _startedAt.remove(localId);
    return at == null ? 0 : DateTime.now().difference(at).inSeconds;
  }
}

/// Server error codes that mean "your plan does not allow this upload".
///
/// ⚠ recapture-api enforces NO plan / usage limit on capture uploads today
/// (Oct 2026 — subscriptions gate catalog publishing only), so nothing sends
/// these yet. They are the names reserved for when one is added; hand-sync this
/// set with the server's code at that point (README Stage D3).
const Set<String> kPlanLimitServerCodes = {
  'PLAN_LIMIT_REACHED',
  'QUOTA_EXCEEDED',
  'SUBSCRIPTION_REQUIRED',
};

/// The shared upload-queue box seen through one owner's eyes: [list] returns
/// only that owner's jobs, so a restore never runs (or drops) another
/// account's captures. Writes pass through — they are only ever made for jobs
/// the owner's coordinator created.
class _OwnerScopedQueueStore implements UploadQueueStore {
  _OwnerScopedQueueStore(this._inner, {required this.owns});

  final UploadQueueStore _inner;
  final bool Function(String jobId) owns;

  @override
  Future<List<UploadQueueEntry>> list() async =>
      [for (final e in await _inner.list()) if (owns(e.jobId)) e];

  @override
  Future<UploadQueueEntry?> get(String jobId) async =>
      owns(jobId) ? _inner.get(jobId) : null;

  @override
  Future<void> put(UploadQueueEntry entry) => _inner.put(entry);

  @override
  Future<void> remove(String jobId) => _inner.remove(jobId);
}
