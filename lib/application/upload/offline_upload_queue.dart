// lib/application/upload/offline_upload_queue.dart
//
// The OFFLINE UPLOAD QUEUE coordinator: makes uploads resilient to network loss
// by QUEUEING jobs durably ("waiting for connection") instead of failing them,
// and AUTO-RESUMING them when connectivity returns — continuing from the
// persisted offset/ETags in the resumable [UploadProgressStore] (the wrapped
// runner/engine reads that store, so a resumed job never re-uploads confirmed
// parts). This is the P2 offline-outbox pattern (detect offline → durable queue
// → flush on reconnect) applied to the upload pipeline.
//
// OFFLINE DETECTION combines two signals:
//   • the connectivity API HINT (connectivity_plus via the app's watcher/
//     providers) — an interface being up does NOT prove the server is reachable;
//   • REAL transfer failures — a network-classified failure (shared 9F
//     classifier) re-queues the job and, when the hint still says "online"
//     (false positive), schedules a backoff re-probe so the queue can't stall
//     forever on a hint that never transitions.
// Connectivity transitions are DEBOUNCED so flapping never thrashes start/stop.
//
// THE KEY STATE DISTINCTION: [UploadJobState.userPaused] (explicit user intent)
// vs [UploadJobState.offlineQueued] (waiting for connection). A connectivity
// restore auto-resumes ONLY offline-queued jobs; a user-paused job stays paused
// until the user resumes it — a connectivity event never overrides user intent.
// Both states are DURABLE ([UploadQueueStore], Hive): relaunching offline stays
// queued; relaunching online resumes ([restore]).
//
// LAYERING: this coordinates; it transfers nothing. One drained job = one
// [UploadJobRunner.run] — in production the [ResilientUploadRunner] over the
// [ChunkedUploadManager] (which owns part-level retry, the resumable store, and
// pause/cancel mechanics via [UploadController]). NON-network failures keep
// their existing behaviour: the runner's backoff first, then a terminal
// [UploadJobState.failed] for Screen 9F — only NETWORK failures divert into the
// queue. NOT WIRED into the live capture→upload flow yet; the pipeline task
// composes runner + engine + this queue and overrides the providers.
//
// BACKGROUND (OS) DIMENSION: this in-app monitor covers the FOREGROUND.
// Background auto-resume rides the OS connectivity-constrained mechanisms —
// Android WorkManager (NetworkType.CONNECTED, see UploadResumeWorker.kt +
// UploadForegroundServiceClient.scheduleNetworkResume) and, when an iOS upload
// host exists, URLSession.waitsForConnectivity (no iOS upload host in this repo
// yet — deferred). Reconciliation rule (no double-run): the pipeline schedules
// the OS work when the app leaves the foreground with queued jobs and cancels it
// on drain-complete/cancel; in the foreground only THIS queue drives resume.
import 'dart:async';

import '../../data/local/upload_progress_box.dart';
import '../../data/local/upload_queue_box.dart';
import '../../domain/upload/upload_failure.dart';
import '../../domain/upload/upload_queue_entry.dart';
import '../../domain/upload/upload_session_spec.dart';
import '../../utils/analytics.dart';
import 'resilient_upload_runner.dart';

/// The transport seam one drained job runs through: a whole session attempt
/// WITH the session-level auto-retry already inside (production:
/// [ResilientUploadRunner] over a [ChunkedUploadManager]). Must be idempotent
/// across runs — it resumes from the durable [UploadProgressStore].
abstract interface class UploadJobRunner {
  Future<ResilientUploadOutcome> run(UploadSessionSpec session);
}

/// Detect offline → durable queue → auto-resume on connectivity restore.
class OfflineUploadQueue {
  OfflineUploadQueue({
    required UploadQueueStore store,
    required UploadJobRunner runner,
    UploadProgressStore? progressStore,
    bool initialOnline = true,
    Duration connectivityDebounce = const Duration(milliseconds: 500),
    Duration reachabilityBaseDelay = const Duration(seconds: 5),
    Duration reachabilityMaxDelay = const Duration(seconds: 60),
    Future<void> Function(Duration)? sleep,
    void Function(String name, Map<String, Object?> props)? analytics,
    String deviceType = 'mobile',
  })  : _store = store,
        _runner = runner,
        _progressStore = progressStore,
        _online = initialOnline,
        _lastHint = initialOnline,
        _debounce = connectivityDebounce,
        _reachabilityBaseDelay = reachabilityBaseDelay,
        _reachabilityMaxDelay = reachabilityMaxDelay,
        _sleep = sleep ?? Future.delayed,
        _analytics = analytics ?? Analytics.logEvent,
        _deviceType = deviceType;

  final UploadQueueStore _store;
  final UploadJobRunner _runner;

  /// The byte-level resume bookkeeping (uploadId/ETags/offset), keyed by the
  /// same sessionId. The queue only ever CLEARS it (on cancel) — reading it is
  /// the engine's job.
  final UploadProgressStore? _progressStore;

  final Duration _debounce;
  final Duration _reachabilityBaseDelay;
  final Duration _reachabilityMaxDelay;
  final Future<void> Function(Duration) _sleep;
  final void Function(String, Map<String, Object?>) _analytics;
  final String _deviceType;

  final Map<String, UploadQueueEntry> _byId = {};
  final StreamController<List<UploadQueueEntry>> _snapshots =
      StreamController<List<UploadQueueEntry>>.broadcast();

  int _nextSeq = 0;
  bool _online; // last SETTLED (debounced) hint, corrected by real failures
  bool _lastHint; // last RAW hint seen (transition detection pre-debounce)
  int _connGen = 0; // debounce generation — a newer transition supersedes
  int _probeGen = 0; // pending reachability re-probe generation
  int _consecutiveNetworkFails = 0; // drives the re-probe backoff
  Future<void>? _activeDrain; // single-flight drain guard
  bool _disposed = false;

  // ── read side ────────────────────────────────────────────────────────────────

  /// Current entries in FIFO (seq-ascending) order.
  List<UploadQueueEntry> get entries =>
      _byId.values.toList()..sort((a, b) => a.seq.compareTo(b.seq));

  /// Snapshot stream (current state re-emitted on every transition). New
  /// subscribers should read [entries] first — the stream carries changes only.
  Stream<List<UploadQueueEntry>> watch() => _snapshots.stream;

  /// Resolves when the in-flight drain (if any) finishes. For tests and for
  /// callers that need a settle point; production code should not await uploads.
  Future<void> get idle => _activeDrain ?? Future<void>.value();

  // ── lifecycle ────────────────────────────────────────────────────────────────

  /// Loads the persisted queue on startup and reconciles interrupted runs:
  /// jobs persisted as uploading/retrying were killed mid-run → re-queued as
  /// offline-queued (their byte-level resume point survives in the resumable
  /// store); user-paused stays paused; stale terminal rows are dropped. If the
  /// device is online, queued jobs auto-resume immediately.
  Future<void> restore() async {
    final persisted = await _store.list();
    for (final raw in persisted) {
      final entry = reconcileOnRestore(raw);
      if (entry == null) {
        await _store.remove(raw.jobId); // stale terminal row
        continue;
      }
      _byId[entry.jobId] = entry;
      if (entry.state != raw.state) await _persist(entry);
      if (entry.seq >= _nextSeq) _nextSeq = entry.seq + 1;
    }
    _emitSnapshot();
    if (_online && _byId.values.any((e) => e.isAutoResumable)) {
      unawaited(autoResumeQueued());
    }
  }

  /// Releases resources. Pending debounces/probes become no-ops.
  void dispose() {
    _disposed = true;
    _connGen++;
    _probeGen++;
    _snapshots.close();
  }

  // ── write side ───────────────────────────────────────────────────────────────

  /// Tracks [spec] as a durable job. Online → starts draining (unawaited — the
  /// caller is not blocked on the transfer); offline → the job waits for
  /// connection (queued, NOT failed). Idempotent per sessionId.
  Future<void> enqueue(UploadSessionSpec spec) async {
    if (_disposed || _byId.containsKey(spec.sessionId)) return;
    final entry = UploadQueueEntry(
      jobId: spec.sessionId,
      spec: spec,
      state: UploadJobState.offlineQueued,
      seq: _nextSeq++,
    );
    _byId[entry.jobId] = entry;
    await _persist(entry);
    _emitSnapshot();
    if (_online) {
      unawaited(autoResumeQueued());
    } else {
      _emitQueued(entry, reason: 'offline_at_start');
    }
  }

  /// The connectivity HINT (wire to the app's connectivity stream). Debounced:
  /// rapid flapping coalesces to the last settled value, and only a settled
  /// offline→online transition triggers a drain — no start/stop thrash.
  void onConnectivityChanged(bool online) {
    if (_disposed || online == _lastHint) return;
    _lastHint = online;
    final gen = ++_connGen;
    unawaited(() async {
      await _sleep(_debounce);
      if (_disposed || gen != _connGen) return; // superseded by a newer flap
      _online = online;
      if (online) {
        _consecutiveNetworkFails = 0;
        _probeGen++; // a real transition replaces any pending re-probe
        await autoResumeQueued();
      }
    }());
  }

  /// Reachability inference for a failure surfaced OUTSIDE a drain (e.g. the
  /// live pipeline's first run): the interface may claim "online", but a real
  /// network failure proves otherwise → re-queue the job (waiting, not failed)
  /// and re-probe with backoff if the hint never transitions. User-paused and
  /// terminal jobs are left untouched.
  Future<void> onUploadNetworkFailure(String jobId) async {
    final current = _byId[jobId];
    if (_disposed ||
        current == null ||
        current.isTerminal ||
        current.state == UploadJobState.userPaused) {
      return;
    }
    await _commit(current.copyWith(
      state: UploadJobState.offlineQueued,
      lastErrorCategory: UploadErrorCategory.network,
    ));
    _emitQueued(_byId[jobId]!, reason: 'network_failure');
    _consecutiveNetworkFails++;
    if (_online) _scheduleReachabilityProbe();
  }

  /// Records explicit user intent: the job stays paused across connectivity
  /// restores AND restarts until [resumeUserPaused]. (Suspending an in-flight
  /// transfer remains the engine's [UploadController.pause]; this persists the
  /// intent so the queue never auto-resumes over it.)
  Future<void> markUserPaused(String jobId) async {
    final current = _byId[jobId];
    if (current == null || current.isTerminal) return;
    await _commit(current.copyWith(state: UploadJobState.userPaused));
  }

  /// Manual resume of a user-paused job. Online → runs now; offline → it
  /// re-enters the auto lane ("waiting for connection") since the user asked
  /// for it to continue.
  Future<void> resumeUserPaused(String jobId) async {
    final current = _byId[jobId];
    if (_disposed ||
        current == null ||
        current.state != UploadJobState.userPaused) {
      return;
    }
    await _commit(current.copyWith(state: UploadJobState.offlineQueued));
    if (_online) await autoResumeQueued();
  }

  /// Clears a job entirely: the queue entry AND its byte-level resume
  /// bookkeeping. The local captured data is retained (this aborts a TRANSFER,
  /// not a delete). Aborting an in-flight transfer is the engine's cancel; this
  /// clears the queue's record so nothing auto-resumes it.
  Future<void> cancel(String jobId) async {
    final removed = _byId.remove(jobId);
    if (removed == null) return;
    await _store.remove(jobId);
    await _progressStore?.clearSession(jobId);
    _emitSnapshot();
  }

  // ── drain ────────────────────────────────────────────────────────────────────

  /// Drains offline-queued jobs in FIFO order (single-flight; a concurrent call
  /// returns the in-flight drain). User-paused jobs are SKIPPED by definition.
  /// Stops early when a job hits a network failure — the network is down (or
  /// unreachable), so the rest stay queued for the next restore/probe.
  Future<void> autoResumeQueued() {
    final existing = _activeDrain;
    if (existing != null) return existing;
    if (_disposed) return Future<void>.value();
    final drain = _drain().whenComplete(() => _activeDrain = null);
    _activeDrain = drain;
    return drain;
  }

  Future<void> _drain() async {
    while (!_disposed) {
      final queued = autoResumableJobs(_byId.values);
      if (queued.isEmpty) return; // re-read each pass → picks up newcomers
      if (!await _runJob(queued.first)) return;
    }
  }

  /// Runs one job to a terminal outcome. Returns false to STOP the drain
  /// (network gone); true to continue with the next queued job.
  Future<bool> _runJob(UploadQueueEntry entry) async {
    final isResume = entry.attempts > 0;
    final running = entry.copyWith(
      state: isResume ? UploadJobState.retrying : UploadJobState.uploading,
      attempts: entry.attempts + 1,
    );
    await _commit(running);
    if (isResume) {
      _analytics(AnalyticsEvents.uploadOfflineAutoResumed, {
        'session_id': entry.jobId,
        'attempt': running.attempts,
        'pending_count': _pendingCount,
        'device_type': _deviceType,
      });
    }

    ResilientUploadOutcome outcome;
    try {
      outcome = await _runner.run(entry.spec);
    } catch (e) {
      // A runner must resolve, not throw — but never let a violation wedge the
      // queue: classify and fold into the normal outcome handling.
      outcome = ResilientUploadOutcome(
        status: ResilientUploadStatus.failed,
        attemptsUsed: 0,
        category: classifyUploadFailure(e),
      );
    }

    // Re-read: the job may have been cancelled or user-paused DURING the run.
    final current = _byId[entry.jobId];
    // cancelled underneath us — nothing to record
    if (current == null) return true;

    switch (outcome.status) {
      case ResilientUploadStatus.succeeded:
        _consecutiveNetworkFails = 0;
        _byId.remove(entry.jobId);
        await _store.remove(entry.jobId);
        _emitSnapshot();
        return true;

      case ResilientUploadStatus.cancelled:
        // The engine reported a user cancel (signalled via UploadController);
        // mirror [cancel] so nothing lingers to auto-resume.
        _byId.remove(entry.jobId);
        await _store.remove(entry.jobId);
        await _progressStore?.clearSession(entry.jobId);
        _emitSnapshot();
        return true;

      case ResilientUploadStatus.failed:
        final category = outcome.category ?? UploadErrorCategory.unknown;
        if (category == UploadErrorCategory.network) {
          // Offline (or unreachable): QUEUE, never fail. The persisted
          // offset/ETags are retained — the next run resumes from them. User
          // intent expressed mid-run wins over the re-queue.
          if (current.state != UploadJobState.userPaused) {
            await _commit(current.copyWith(
              state: UploadJobState.offlineQueued,
              lastErrorCategory: category,
            ));
            _emitQueued(_byId[entry.jobId]!, reason: 'network_failure');
          }
          _consecutiveNetworkFails++;
          if (_online) {
            // Hint says online but the transfer says otherwise (false
            // positive) — no transition will come, so re-probe with backoff.
            _scheduleReachabilityProbe();
          }
          return false; // network is down — the rest stay queued
        }
        // NON-network terminal failure (runner backoff already exhausted):
        // Screen 9F's territory, not the queue's. One job's terminal failure
        // doesn't block the jobs behind it.
        if (current.state != UploadJobState.userPaused) {
          await _commit(current.copyWith(
            state: UploadJobState.failed,
            lastErrorCategory: category,
          ));
        }
        return true;
    }
  }

  /// Backoff re-probe for connectivity-API false positives: after
  /// [_reachabilityBaseDelay] * 2^(fails-1) (capped at [_reachabilityMaxDelay]),
  /// try draining again — unless superseded by a real online transition, a newer
  /// failure, or dispose.
  void _scheduleReachabilityProbe() {
    final gen = ++_probeGen;
    final exp = _consecutiveNetworkFails < 1 ? 0 : _consecutiveNetworkFails - 1;
    var ms = _reachabilityBaseDelay.inMilliseconds;
    for (var i = 0; i < exp; i++) {
      ms *= 2;
      if (ms >= _reachabilityMaxDelay.inMilliseconds) break;
    }
    if (ms > _reachabilityMaxDelay.inMilliseconds) {
      ms = _reachabilityMaxDelay.inMilliseconds;
    }
    unawaited(() async {
      await _sleep(Duration(milliseconds: ms));
      if (_disposed || gen != _probeGen || !_online) return;
      await autoResumeQueued();
    }());
  }

  // ── internals ────────────────────────────────────────────────────────────────

  int get _pendingCount =>
      _byId.values.where((e) => e.isWaitingForConnection).length;

  Future<void> _commit(UploadQueueEntry entry) async {
    _byId[entry.jobId] = entry;
    await _persist(entry);
    _emitSnapshot();
  }

  Future<void> _persist(UploadQueueEntry entry) async {
    try {
      await _store.put(entry);
    } catch (_) {
      /* persistence is best-effort; never break the in-memory queue */
    }
  }

  void _emitSnapshot() {
    if (!_snapshots.isClosed) _snapshots.add(entries);
  }

  void _emitQueued(UploadQueueEntry entry, {required String reason}) {
    _analytics(AnalyticsEvents.uploadOfflineQueued, {
      'session_id': entry.jobId,
      'reason': reason,
      'pending_count': _pendingCount,
      'device_type': _deviceType,
    });
  }
}
