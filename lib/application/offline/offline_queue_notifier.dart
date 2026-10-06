// lib/application/offline/offline_queue_notifier.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/offline_queue_box.dart';
import '../../data/local/storage_providers.dart';
import '../../data/repositories/projects_repository.dart';
import '../../domain/entities/auth_state.dart';
import '../../domain/entities/create_project_options.dart';
import '../../domain/entities/offline_action.dart';
import '../../platform/connectivity_watcher.dart';
import '../../utils/analytics.dart';
import '../auth/auth_notifier.dart';
import '../connectivity/connectivity_providers.dart';
import '../projects/projects_notifier.dart';

/// Drop an action once it has failed this many drains, so a permanently-failing
/// action can never wedge the queue. Kept deliberately simple — no backoff.
const int kMaxOfflineAttempts = 5;

/// Immutable snapshot of the offline queue for UI/debug.
class OfflineQueueState {
  const OfflineQueueState({this.pending = const [], this.processing = false});

  /// FIFO list of actions awaiting a successful drain.
  final List<OfflineAction> pending;

  /// True while a drain is in flight (single-drain guard).
  final bool processing;

  int get pendingCount => pending.length;
}

/// Owns the persisted offline action queue and is the single source of truth for
/// "what deferred mutations are waiting". It can enqueue, persist, restore, and
/// drain actions; concrete per-action execution is a STUB ([_process]) wired in
/// by later tasks.
///
/// Invariants:
///   - Only one drain runs at a time ([OfflineQueueState.processing] guard).
///   - A failed drain RETAINS the action (increments attempts) — connectivity
///     reporting "online" does not prove the API is reachable, so nothing is
///     cleared on the strength of the interface alone.
///   - Persistence goes through [OfflineQueueBox] only; corruption degrades to
///     an empty queue.
///   - The queue clears on logout (no cross-user replay).
class OfflineQueueNotifier extends Notifier<OfflineQueueState> {
  OfflineQueueBox get _box => ref.read(offlineQueueBoxProvider);

  Future<void> _restored = Future<void>.value();

  @override
  OfflineQueueState build() {
    _restored = _restore(); // async, non-blocking

    // Auto-drain when connectivity flips to online. The processing guard makes
    // flapping connectivity safe (overlapping drains are no-ops).
    ref.listen(connectivityStatusProvider, (_, next) {
      next.whenData((status) {
        if (status == AppConnectivityStatus.online) processQueue();
      });
    });

    // Clear on logout so a previous user's actions are never replayed.
    ref.listen<AuthState>(authProvider, (_, next) {
      if (next is AuthUnauthenticated) clear();
    });

    return const OfflineQueueState();
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Completes once the persisted queue has been loaded. Callers that ask
  /// "is there already a create for this project?" await it first, so a cold
  /// start never answers "no" before the disk did.
  Future<void> whenRestored() => _restored;

  /// Whether a `createProject` action for offline project [tempId] is waiting.
  bool hasCreateProjectFor(String tempId) => state.pending.any((a) =>
      a.type == OfflineActionType.createProject &&
      a.payload['tempId'] == tempId);

  /// Makes sure offline project [tempId] has a `createProject` action queued,
  /// re-creating it from a capture that is waiting for upload when it is gone.
  ///
  /// WHY IT CAN BE GONE: the queue is cleared on logout (no cross-user replay —
  /// unchanged), and an action is dropped after [kMaxOfflineAttempts] failed
  /// drains. A capture waiting on the phone for that project must still get
  /// its project, so the upload coordinator re-creates the action from the
  /// capture record when its OWNER is signed in again. The cross-user
  /// guarantee holds: only the signed-in owner's captures ever reach here.
  ///
  /// Duplicate-safe: the action id — and so the POST /projects Idempotency-Key —
  /// is derived from [tempId], so a re-created action replays the original
  /// project on the server instead of creating a second one.
  Future<void> ensureCreateProject({
    required String tempId,
    required String name,
    required String size,
    String mode = 'guided',
  }) async {
    await whenRestored();
    if (hasCreateProjectFor(tempId)) return;
    await enqueue(OfflineAction(
      id: createProjectActionIdFor(tempId),
      type: OfflineActionType.createProject,
      payload: {'tempId': tempId, 'name': name, 'size': size, 'mode': mode},
      createdAt: DateTime.now().toUtc(),
    ));
  }

  /// Appends [action] to the queue and persists. Does not drain — the drain is
  /// driven by connectivity returning (or a manual [processQueue]).
  Future<void> enqueue(OfflineAction action) async {
    final next = [...state.pending, action];
    state = OfflineQueueState(pending: next, processing: state.processing);
    await _persist(next);
    _log(event: 'enqueued', actionType: action.type, pendingCount: next.length);
  }

  /// Drains the queue once. No-ops cheaply when empty or already draining.
  /// Failed actions are retained with a bumped attempt count; actions over
  /// [kMaxOfflineAttempts] (and `unknown` types) are dropped. Actions enqueued
  /// while a drain is in flight are preserved and picked up by the next drain.
  Future<void> processQueue() async {
    if (state.processing || state.pending.isEmpty) return;
    final done = Completer<void>();
    _drainDone = done;
    try {
      await _processQueue();
    } finally {
      _drainDone = null;
      done.complete();
    }
  }

  Completer<void>? _drainDone;

  /// Runs a drain and returns once the queue is idle again — unlike
  /// [processQueue], it WAITS for a drain already in flight (and then drains
  /// once more, picking up anything enqueued meanwhile). Used by the upload
  /// coordinator, which must know an offline project's create has been
  /// attempted before it uploads into that project.
  Future<void> flush() async {
    final inFlight = _drainDone;
    if (inFlight != null) await inFlight.future;
    await processQueue();
  }

  Future<void> _processQueue() async {
    final batch = state.pending;
    state = OfflineQueueState(pending: batch, processing: true);
    _log(event: 'drain_started', pendingCount: batch.length);

    final retained = <OfflineAction>[];
    for (final action in batch) {
      final ok = await _process(action);
      if (ok) continue; // executed (or intentionally dropped, e.g. unknown)

      final bumped = action.incremented();
      if (bumped.attempts >= kMaxOfflineAttempts) {
        // Runaway action — drop it so it can't wedge the queue forever.
        _log(event: 'action_dropped', actionType: bumped.type, pendingCount: -1);
        continue;
      }
      retained.add(bumped);
    }

    // Preserve anything enqueued during the drain (not part of this batch).
    final batchIds = {for (final a in batch) a.id};
    final newcomers = [
      for (final a in state.pending)
        if (!batchIds.contains(a.id)) a,
    ];
    final remaining = [...retained, ...newcomers];

    await _persist(remaining);
    state = OfflineQueueState(pending: remaining, processing: false);
    _log(event: 'drain_finished', pendingCount: remaining.length);
  }

  /// Drops the queued `createProject` for offline project [tempId] (the user
  /// deleted it before it ever reached the server). No-op when absent.
  Future<void> removeCreateProjectFor(String tempId) async {
    await whenRestored();
    final next = [
      for (final a in state.pending)
        if (!(a.type == OfflineActionType.createProject &&
            a.payload['tempId'] == tempId))
          a,
    ];
    if (next.length == state.pending.length) return;
    state = OfflineQueueState(pending: next, processing: state.processing);
    await _persist(next);
  }

  /// Empties the queue (in memory and on disk). Used on logout.
  Future<void> clear() async {
    state = const OfflineQueueState();
    await _persist(const []);
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  /// STUB: real handlers are wired in by later tasks once the rename/delete/
  /// retry flows decide whether they support offline deferral.
  ///
  /// Contract: return `true` to remove the action (executed), `false` to RETAIN
  /// it (no silent data loss while handlers are stubbed). Known-but-unimplemented
  /// types therefore return `false`; `unknown` returns `true` so a stale type
  /// from another app version is dropped instead of wedging the queue.
  Future<bool> _process(OfflineAction action) async {
    switch (action.type) {
      case OfflineActionType.createProject:
        return _flushCreateProject(action);
      case OfflineActionType.renameProject:
      case OfflineActionType.deleteProject:
      case OfflineActionType.retryProject:
        // TODO(later-task): call the matching ProjectsNotifier/repository method
        // and return true on success. Retained by default — see constraints.
        return false;
      case OfflineActionType.unknown:
        return true; // drop unrecognized actions so they don't wedge the queue
    }
  }

  /// Flushes a queued offline create: POSTs it through the repository and, on
  /// success, reconciles the optimistic pending row (temp id → server id) in the
  /// projects state. Returns `true` to remove it from the queue, `false` to
  /// RETAIN for a later retry. A malformed payload (cannot be replayed) is
  /// dropped so it can never wedge the queue.
  Future<bool> _flushCreateProject(OfflineAction action) async {
    final name = action.payload['name'];
    final tempId = action.payload['tempId'];
    if (name is! String || tempId is! String) {
      return true; // unreplayable → drop (matches the `unknown` policy)
    }

    try {
      final created = await ref.read(projectsRepositoryProvider).create(
            name: name,
            size: objectSizeFromApi(action.payload['size'] as String? ?? ''),
            mode: captureModeFromApi(action.payload['mode'] as String? ?? ''),
            // The action id is derived from the temp id
            // ([createProjectActionIdFor]) — a retry after a lost response, or
            // a create re-made after a logout, replays the same project.
            idempotencyKey: action.id,
          );
      ref.read(projectsProvider.notifier).reconcilePendingCreate(tempId, created);
      return true;
    } catch (_) {
      return false; // network/server failure → keep it queued for the next drain
    }
  }

  /// Loads the persisted queue on startup. Prepends restored actions ahead of
  /// anything enqueued in the meantime (FIFO: persisted ones drain first), and
  /// no-ops when nothing was persisted (keeps a concurrent enqueue intact).
  Future<void> _restore() async {
    try {
      final restored = await _box.read();
      if (restored.isEmpty) return;
      state = OfflineQueueState(
        pending: [...restored, ...state.pending],
        processing: state.processing,
      );
    } catch (_) {/* corrupt/unreadable queue → stay empty */}
  }

  Future<void> _persist(List<OfflineAction> actions) async {
    try {
      await _box.save(actions);
    } catch (_) {/* persistence is best-effort; never break the in-memory queue */}
  }

  void _log({
    required String event,
    OfflineActionType? actionType,
    required int pendingCount,
  }) {
    // Never logs payloads — only outcome metadata.
    Analytics.logEvent('offline_queue_event', {
      'event': event,
      if (actionType != null) 'action_type': actionType.analyticsValue,
      'pending_count': pendingCount < 0 ? state.pendingCount : pendingCount,
      'device_type':
          defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
    });
  }
}

/// App-wide offline action queue. Always holds a valid (possibly empty) state.
final offlineQueueProvider =
    NotifierProvider<OfflineQueueNotifier, OfflineQueueState>(
  OfflineQueueNotifier.new,
);

/// The deterministic action id (and POST /projects Idempotency-Key) for the
/// offline create of [tempId]. Stable across logout/re-creation, so a retried or
/// re-created create can only ever replay the one server project.
String createProjectActionIdFor(String tempId) => 'project-$tempId';
