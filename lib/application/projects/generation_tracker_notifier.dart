// lib/application/projects/generation_tracker_notifier.dart
//
// Every 3D-model generation the APP is watching — not the screen.
//
// ── WHY THIS EXISTS NEXT TO [ownerModelStateProvider] ───────────────────────
// That one answers "what is the full model situation of the project I am
// looking at", and dies with the screen (`ref.onDispose(_stop)`) because
// polling on behalf of a route nobody is on is waste. This one answers a
// different question — "what work is the app waiting on, anywhere" — and so
// must outlive every route, survive backgrounding, and survive an app kill.
//
// They are deliberately NOT merged. Two providers polling the same endpoint for
// the same project would be double traffic and two sources of truth, so
// [suppress] is the seam that keeps them off each other: while the build screen
// is up, IT is the one asking, and the tracker skips that project (without
// forgetting it — the status bar still shows the entry).
//
// ── WHAT IS AND IS NOT DURABLE ─────────────────────────────────────────────
// Only project IDS survive a restart. Percent and status are the server's to
// state and go stale the moment the app dies, so a restored entry always starts
// as `running` with no percent and is immediately re-polled. The disk is a list
// of things to go ask about, never an answer.
//
// ── NOT A SPEND GATE ───────────────────────────────────────────────────────
// Tracking is purely additive observation. The three guards that decide whether
// a (paid) POST fires — the widget's in-flight latch,
// [OwnerGenerationRequestNotifier]'s `hasStarted`, and the server's idempotency
// key — are untouched, and nothing here may become a fourth.
import 'dart:async';

// `widgets.dart` re-exports foundation, which is where @immutable and
// @visibleForTesting come from — one import covers both.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/generation_tracker_box.dart';
import '../../data/local/storage_providers.dart';
import '../../data/repositories/projects_repository.dart';
import '../../domain/entities/auth_state.dart';
import '../../utils/analytics.dart';
import '../auth/auth_notifier.dart';
import 'projects_notifier.dart';

/// Poll cadence. Same INTENT as [OwnerModelStateNotifier]'s — short at first so
/// a quick generation feels immediate, backing off to a cheap steady tick — but
/// scoped to the TRACKER: one timer serves every watched project, so the
/// backoff describes how often the app checks in, not how often each project
/// is checked.
const _initialInterval = Duration(seconds: 3);
const _maxInterval = Duration(seconds: 10);

/// Hard stop, matching the screen-scoped notifier. At this cadence the cap runs
/// well past the backend's MESHY_TASK_TIMEOUT_MS, after which the worker gives
/// up and the record turns FAILED on its own — anything still pending here
/// means something is wrong, and polling forever would not fix it.
const _maxPolls = 120;

/// How long a SUCCEEDED entry lingers in the bar before clearing itself.
///
/// Failures deliberately have no equivalent: a failure the user never saw is
/// the worst outcome this feature can produce, so it stays until dismissed.
@visibleForTesting
const kGenerationSuccessLinger = Duration(seconds: 60);

/// Where a tracked generation is in its life, as the APP knows it.
enum TrackedGenerationStatus {
  /// Still being built (or we have not yet heard otherwise).
  running,

  /// A poll saw a viewable model.
  succeeded,

  /// A poll saw the run had failed.
  failed,

  /// The poll cap ran out with the run still pending. Distinct from [failed]:
  /// we do not know that it failed, only that we stopped asking.
  givenUp,
}

/// One generation the app is watching.
@immutable
class TrackedGeneration {
  const TrackedGeneration({
    required this.projectId,
    required this.projectName,
    required this.startedAt,
    this.percent,
    this.status = TrackedGenerationStatus.running,
  });

  final String projectId;

  /// Carried so the status bar can name the project without a list fetch.
  final String projectName;

  /// When the app started watching. Feeds the settled event's duration.
  final DateTime startedAt;

  /// The highest percent the server has ever reported for this run, or null
  /// when it has reported none. MONOTONIC — see [GenerationTrackerNotifier].
  final int? percent;

  final TrackedGenerationStatus status;

  bool get isRunning => status == TrackedGenerationStatus.running;
  bool get isTerminal => !isRunning;

  TrackedGeneration copyWith({int? percent, TrackedGenerationStatus? status}) {
    return TrackedGeneration(
      projectId: projectId,
      projectName: projectName,
      startedAt: startedAt,
      percent: percent ?? this.percent,
      status: status ?? this.status,
    );
  }

  TrackedGenerationRecord toRecord() => TrackedGenerationRecord(
        projectId: projectId,
        projectName: projectName,
        startedAt: startedAt,
      );
}

/// Immutable snapshot of everything the app is watching, keyed by projectId.
///
/// A plain [Map] in an immutable holder rather than an immutable-collections
/// package: the codebase has no such dependency and this task must not add one.
/// Insertion order is preserved, which is what makes "the single running entry"
/// and the bar's choice of which project to name deterministic.
@immutable
class GenerationTrackerState {
  const GenerationTrackerState({this.generations = const {}});

  final Map<String, TrackedGeneration> generations;

  bool get isEmpty => generations.isEmpty;
  bool get isNotEmpty => generations.isNotEmpty;

  List<TrackedGeneration> get running => [
        for (final g in generations.values)
          if (g.isRunning) g
      ];

  List<TrackedGeneration> withStatus(TrackedGenerationStatus status) => [
        for (final g in generations.values)
          if (g.status == status) g
      ];

  bool get hasRunning => generations.values.any((g) => g.isRunning);

  int get runningCount => running.length;

  GenerationTrackerState withEntry(TrackedGeneration entry) =>
      GenerationTrackerState(
        generations: {...generations, entry.projectId: entry},
      );

  GenerationTrackerState without(String projectId) => GenerationTrackerState(
        generations: {...generations}..remove(projectId),
      );
}

/// Where a track() call came from — an analytics property only, never a
/// behavioural switch.
enum GenerationTrackingSource {
  /// An explicit "Generate 3D model" / "Create a new version" press.
  manualButton,

  /// A capture finished and something was already running when we asked.
  postCapture,

  /// Restored from disk on launch.
  restored;

  String get analyticsValue => switch (this) {
        GenerationTrackingSource.manualButton => 'manual_button',
        GenerationTrackingSource.postCapture => 'post_capture',
        GenerationTrackingSource.restored => 'restored',
      };
}

/// The name shown when a caller genuinely does not know the project's name (the
/// post-capture flow has the id but not the name). A neutral placeholder beats
/// a wrong name.
const String kUnnamedTrackedProject = 'Your capture';

class GenerationTrackerNotifier extends Notifier<GenerationTrackerState> {
  /// ONE timer for the whole tracker. Not one per project — N projects must
  /// cost one wake-up per tick, not N.
  Timer? _timer;

  /// Tracker-scoped, not per project: the cap bounds how long the APP keeps
  /// asking, and a tick that polled nothing does not count against it.
  int _polls = 0;
  Duration _interval = _initialInterval;

  /// Set while a tick's requests are in flight, so a resume (or a fresh
  /// [track]) cannot start a second overlapping sweep.
  bool _polling = false;

  /// The app is backgrounded. A backgrounded app must not poll.
  bool _paused = false;

  /// Set from `ref.onDispose`. Every async continuation checks it before
  /// touching `state` — a Notifier throws if it is written after disposal, and
  /// an in-flight poll outliving the container is the normal case in tests.
  bool _disposed = false;

  /// The app shell has called [start], so the durable store is usable.
  ///
  /// Until then this is a purely in-memory tracker that touches no disk. See
  /// [start] for why that separation exists.
  bool _started = false;

  /// Projects whose own screen is polling them right now. Skipped by the poll
  /// loop; still fully tracked and still shown by the status bar.
  final Set<String> _suppressed = {};

  /// Per-project poll counts, for the settled event. Private rather than part
  /// of [TrackedGeneration] so a counter bump never rebuilds the UI.
  final Map<String, int> _pollsById = {};

  /// Self-clear timers for succeeded entries.
  final Map<String, Timer> _lingerTimers = {};

  @override
  GenerationTrackerState build() {
    ref.onDispose(() {
      _disposed = true;
      _timer?.cancel();
      _timer = null;
      for (final timer in _lingerTimers.values) {
        timer.cancel();
      }
      _lingerTimers.clear();
    });

    // Clear on logout so one user never sees another's work — the same policy
    // (and the same trigger) as the offline action queue.
    ref.listen<AuthState>(authProvider, (_, next) {
      if (next is AuthUnauthenticated) clear();
    });

    // A backgrounded app must not poll; a foregrounded one must not wait a full
    // interval to find out what happened while it was away.
    //
    // NOTE: AppLifecycleListener reports TRANSITIONS only — launch is not a
    // resume — so the restore below polls once explicitly. Same reasoning as
    // backendWarmupProvider's explicit startup ping.
    final listener = AppLifecycleListener(
      onPause: _onAppPaused,
      onResume: () => unawaited(_onAppResumed()),
    );
    ref.onDispose(listener.dispose);

    return const GenerationTrackerState();
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Wakes the tracker: restores what was being watched when the app was last
  /// killed, and immediately re-asks the server about it.
  ///
  /// DELIBERATELY separate from [build]. Screens now construct this notifier
  /// merely to read the capture lock ([captureLockedProvider]) or to
  /// [suppress] a project, and none of those may imply disk IO — Hive is only
  /// guaranteed initialised after `main()` has done so, and a widget test that
  /// pumps the Projects Hub is not obliged to set it up. So constructing the
  /// tracker gives you an empty in-memory one, and the app shell — the single
  /// place that knows startup has happened — turns on persistence by calling
  /// this exactly once.
  ///
  /// Idempotent: a second call is a no-op, never a second restore.
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    await _restore();
  }

  /// Starts watching [projectId]. Call wherever a generation is KNOWN to have
  /// started.
  ///
  /// Idempotent: an already-tracked id is a no-op — never a second entry and
  /// never a second timer. This matters because the manual press and the
  /// post-capture probe can both discover the same run.
  void track(
    String projectId, {
    String? projectName,
    GenerationTrackingSource source = GenerationTrackingSource.manualButton,
  }) {
    if (projectId.isEmpty) return;
    if (state.generations.containsKey(projectId)) return;

    state = state.withEntry(
      TrackedGeneration(
        projectId: projectId,
        projectName: (projectName == null || projectName.isEmpty)
            ? kUnnamedTrackedProject
            : projectName,
        startedAt: DateTime.now(),
      ),
    );
    _pollsById[projectId] = 0;
    Analytics.logEvent('generation_tracking_started', {
      'source': source.analyticsValue,
    });

    // New work resets the cadence: the next check should be soon, not at
    // whatever slow interval a long-running sibling had backed off to.
    _polls = 0;
    _interval = _initialInterval;
    _persist();
    _schedule();
  }

  /// Stops showing [projectId] and stops asking about it. The tap target on a
  /// finished bar, the dismiss on a failed one, and the self-clear on a lingering
  /// success all land here.
  void dismiss(String projectId) {
    _lingerTimers.remove(projectId)?.cancel();
    _pollsById.remove(projectId);
    if (_disposed || !state.generations.containsKey(projectId)) return;
    state = state.without(projectId);
    _persist();
    _schedule();
  }

  /// Forgets everything, in memory and on disk. Logout.
  void clear() {
    for (final timer in _lingerTimers.values) {
      timer.cancel();
    }
    _lingerTimers.clear();
    _pollsById.clear();
    _suppressed.clear();
    _timer?.cancel();
    _timer = null;
    if (!_disposed) state = const GenerationTrackerState();
    _persist();
  }

  /// The project's own screen has taken over polling — skip it here.
  ///
  /// Does NOT untrack: the entry stays in state so the bar still shows it. This
  /// is the seam that stops the tracker and [ownerModelStateProvider] both
  /// hammering `GET /projects/:id` and racing each other into the
  /// projects-list invalidation.
  void suppress(String projectId) => _suppressed.add(projectId);

  /// The project's own screen is gone — resume asking about it.
  void unsuppress(String projectId) {
    if (!_suppressed.remove(projectId)) return;
    // The screen that was watching may have seen the run finish; and if the
    // tracker had backed off (or stopped, having had nothing pollable), it must
    // pick this project back up promptly.
    _polls = 0;
    _interval = _initialInterval;
    _schedule();
  }

  /// Whether [projectId] is currently being polled by someone else.
  @visibleForTesting
  bool isSuppressed(String projectId) => _suppressed.contains(projectId);

  /// Whether the poll timer is armed. Test-only observation.
  @visibleForTesting
  bool get isPolling => _timer != null;

  /// Runs exactly one cadence cycle — poll every eligible project, then do the
  /// cap and backoff bookkeeping the timer would have done.
  ///
  /// The seam tests drive instead of waiting out real 3-to-10-second timers.
  @visibleForTesting
  Future<void> debugTick() => _tick();

  // ── Cadence ───────────────────────────────────────────────────────────────

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    if (_disposed || _paused) return;
    if (!state.hasRunning) return; // nothing to ask about → no timer at all
    if (_polls >= _maxPolls) {
      _giveUpOnEverythingRunning();
      return;
    }
    _timer = Timer(_interval, _tick);
  }

  Future<void> _tick() async {
    final polled = await _pollOnce();
    // A tick that polled nothing (every running project is suppressed) must not
    // burn the cap or back the cadence off — the app has not actually asked.
    if (polled) {
      _polls++;
      final doubled = _interval * 2;
      _interval = doubled > _maxInterval ? _maxInterval : doubled;
    }
    _schedule();
  }

  /// Returns true when at least one request was actually made.
  Future<bool> _pollOnce() async {
    if (_disposed || _polling) return false;
    final targets = [
      for (final g in state.generations.values)
        if (g.isRunning && !_suppressed.contains(g.projectId)) g.projectId,
    ];
    if (targets.isEmpty) return false;

    _polling = true;
    try {
      final repository = ref.read(projectsRepositoryProvider);
      for (final id in targets) {
        if (_disposed) return true;
        try {
          final modelState = await repository.fetchModelState(id);
          _pollsById[id] = (_pollsById[id] ?? 0) + 1;
          _apply(id, modelState);
        } catch (_) {
          // A transient failure must not settle a perfectly healthy run as
          // failed — keep it running and retry next tick. A permanent failure
          // just runs out the poll cap.
        }
      }
    } finally {
      _polling = false;
    }
    return true;
  }

  void _apply(String projectId, OwnerModelState modelState) {
    if (_disposed) return;
    final current = state.generations[projectId];
    if (current == null || current.isTerminal) return;

    // A viewable model wins over everything else the payload says: a newer run
    // may still be in flight, but the thing the user was waiting for exists.
    if (modelState.hasViewableModel) {
      _settle(projectId, TrackedGenerationStatus.succeeded);
      return;
    }
    if (modelState.generation?.hasFailed ?? false) {
      _settle(projectId, TrackedGenerationStatus.failed);
      return;
    }

    // MONOTONIC. Progress writes are best-effort and fenced server-side, so a
    // stale percent arrives out of order; a bar that jumps 60% → 40% reads as a
    // bug. Same clamp ModelBuildingScreen applies, per project.
    final reported = modelState.generation?.progressPercent;
    if (reported == null) return;
    final best = current.percent;
    if (best != null && reported <= best) return;
    state = state.withEntry(current.copyWith(percent: reported));
  }

  void _settle(String projectId, TrackedGenerationStatus status) {
    final entry = state.generations[projectId];
    if (entry == null || entry.isTerminal) return;

    state = state.withEntry(entry.copyWith(status: status));

    Analytics.logEvent('generation_tracking_settled', {
      'outcome': switch (status) {
        TrackedGenerationStatus.succeeded => 'succeeded',
        TrackedGenerationStatus.failed => 'failed',
        TrackedGenerationStatus.givenUp => 'gave_up',
        // Unreachable — _settle is only ever called with a terminal status.
        TrackedGenerationStatus.running => 'running',
      },
      'duration_s': DateTime.now().difference(entry.startedAt).inSeconds,
      'polls': _pollsById[projectId] ?? 0,
    });

    // A settled generation changes the PROJECTS LIST, not just this entry:
    // `modelCount` is aggregated server-side into the list DTO, so the Models
    // button stays hidden until the list is re-fetched. ModelBuildingScreen
    // already does this for the user who is watching; the tracker does it for
    // the user who is somewhere else entirely.
    ref.invalidate(projectsProvider);

    // Only RUNNING entries are durable (see [_persist]), so settling here also
    // removes it from disk — a relaunch must not re-announce an outcome the
    // user has already been shown.
    _persist();

    if (status == TrackedGenerationStatus.succeeded) {
      _lingerTimers[projectId]?.cancel();
      _lingerTimers[projectId] =
          Timer(kGenerationSuccessLinger, () => dismiss(projectId));
    }
  }

  void _giveUpOnEverythingRunning() {
    for (final entry in state.running) {
      _settle(entry.projectId, TrackedGenerationStatus.givenUp);
    }
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  void _onAppPaused() {
    _paused = true;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _onAppResumed() async {
    _paused = false;
    // Poll IMMEDIATELY, not after one interval: minutes may have passed, and
    // the first thing a returning user should see is the truth. The cadence
    // resets too — a long background stretch should not leave the app on its
    // slowest tick.
    _polls = 0;
    _interval = _initialInterval;
    await _pollOnce();
    _schedule();
  }

  // ── Persistence ───────────────────────────────────────────────────────────

  /// Restores the WATCHED IDS and immediately re-asks.
  ///
  /// Nothing about the restored entries is believed beyond "we were watching
  /// this": they come back as `running` with no percent, and the poll that
  /// follows is what establishes the truth. The generation may well have
  /// finished, failed, or been superseded while the app was dead.
  Future<void> _restore() async {
    List<TrackedGenerationRecord> records;
    try {
      records = await ref.read(generationTrackerStoreProvider).read();
    } catch (_) {
      return; // a corrupt/unreadable store simply means nothing to resume
    }
    if (_disposed || records.isEmpty) return;

    final merged = {...state.generations};
    for (final record in records) {
      // A live track() during the restore wins — it has the fresher name and,
      // more importantly, must not be duplicated.
      if (merged.containsKey(record.projectId)) continue;
      merged[record.projectId] = TrackedGeneration(
        projectId: record.projectId,
        projectName: record.projectName.isEmpty
            ? kUnnamedTrackedProject
            : record.projectName,
        startedAt: record.startedAt,
      );
      _pollsById[record.projectId] = 0;
      Analytics.logEvent('generation_tracking_started', {
        'source': GenerationTrackingSource.restored.analyticsValue,
      });
    }
    if (merged.length == state.generations.length) return;
    state = GenerationTrackerState(generations: merged);

    _polls = 0;
    _interval = _initialInterval;
    await _pollOnce();
    _schedule();
  }

  /// Writes the RUNNING entries only.
  ///
  /// A terminal entry is deliberately not durable: its outcome has already been
  /// surfaced and now lives in the project itself, so restoring it would
  /// re-announce a finished model (or a dismissed failure) on every cold start.
  /// Everything on disk is therefore something we still do not know the answer
  /// to — exactly what [_restore] wants to re-ask about.
  ///
  /// Best-effort, like the offline queue's: persistence must never break the
  /// in-memory tracker. No-ops before [start] — see there for why the tracker
  /// must be usable without a disk.
  void _persist() {
    if (_disposed || !_started) return;
    final records = [for (final g in state.running) g.toRecord()];
    unawaited(() async {
      try {
        await ref.read(generationTrackerStoreProvider).save(records);
      } catch (_) {/* best-effort */}
    }());
  }
}

/// Every 3D-model generation the app is watching. App-scoped and NOT
/// autoDisposed — the whole point is to outlive the screen that started it.
final generationTrackerProvider =
    NotifierProvider<GenerationTrackerNotifier, GenerationTrackerState>(
  GenerationTrackerNotifier.new,
);

/// The pure lock predicate: a generation is only a reason to block a new
/// capture while it is actually RUNNING. Terminal entries linger in the bar so
/// the user can see how things ended, and a bar the user has not dismissed must
/// never keep them out of the camera.
bool captureLockedFor(GenerationTrackerState state) => state.hasRunning;

/// True while any tracked generation is still running — the capture lock.
///
/// Enforced in exactly two places: the router's entry-point redirect and the
/// Projects Hub's disabled CTAs. It stops you ENTERING capture; it never
/// interrupts one in progress.
final captureLockedProvider = Provider<bool>((ref) {
  return captureLockedFor(ref.watch(generationTrackerProvider));
});
