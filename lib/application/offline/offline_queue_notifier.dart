// lib/application/offline/offline_queue_notifier.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/offline_queue_box.dart';
import '../../data/local/storage_providers.dart';
import '../../domain/entities/auth_state.dart';
import '../../domain/entities/offline_action.dart';
import '../../platform/connectivity_watcher.dart';
import '../../utils/analytics.dart';
import '../auth/auth_notifier.dart';
import '../connectivity/connectivity_providers.dart';

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

  @override
  OfflineQueueState build() {
    _restore(); // async, non-blocking

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
