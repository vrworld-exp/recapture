// lib/application/upload/pending_captures_notifier.dart
//
// The SINGLE SOURCE OF TRUTH for "which finished captures are waiting for
// upload" — the Projects cards, the header strip, the Summary screen, the
// logout dialog and the upload coordinator all read this list and nothing
// else. Backed by the durable [PendingCaptureStore].
//
// OWNER-SCOPED. The list holds only the signed-in user's captures. It is
// rebuilt whenever the signed-in user changes: signing out empties it (the
// records stay on disk for their owner), and signing in loads that user's
// records. Another account on the same phone never sees, counts or uploads
// them.
//
// NATIVE ONLY. When [offlineCaptureCapabilityProvider] is false (web) the list
// is always empty and the store is never opened.
//
// Order is oldest capture first — the order the cards list them and the order
// the coordinator drains them.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/pending_capture_box.dart';
import '../../data/local/storage_providers.dart';
import '../../domain/upload/pending_capture.dart';
import '../auth/auth_notifier.dart';
import 'offline_capture_capability.dart';

/// The signed-in user's id, or null when signed out / still restoring / the
/// session carries no id. Pending captures are never written without one.
final currentUserIdProvider = Provider<String?>((ref) {
  final id = ref.watch(authProvider.select((s) => s.sessionOrNull?.userId));
  return (id == null || id.isEmpty) ? null : id;
});

final pendingCapturesProvider =
    NotifierProvider<PendingCapturesNotifier, List<PendingCapture>>(
  PendingCapturesNotifier.new,
);

class PendingCapturesNotifier extends Notifier<List<PendingCapture>> {
  PendingCaptureStore get _store => ref.read(pendingCaptureStoreProvider);

  String? _owner;
  Future<void> _loaded = Future<void>.value();

  /// Bumped on every rebuild so a load that finishes after the user changed is
  /// discarded instead of showing one account's captures to another.
  int _generation = 0;

  @override
  List<PendingCapture> build() {
    final gen = ++_generation;
    if (!ref.watch(offlineCaptureCapabilityProvider)) {
      _owner = null;
      return const [];
    }
    _owner = ref.watch(currentUserIdProvider);
    if (_owner == null) return const [];
    _loaded = _load(gen, _owner!);
    return const [];
  }

  /// Completes once the signed-in user's records have been read from disk.
  /// Callers that COUNT (the 5-capture limit, the logout dialog) await this so
  /// a cold start never reads "0 waiting" before the store answered.
  Future<void> whenLoaded() => _loaded;

  /// The owner the current list belongs to (null = nobody signed in, or web).
  String? get ownerUserId => _owner;

  /// The record for [localId], if it belongs to the signed-in user.
  PendingCapture? byLocalId(String localId) {
    for (final c in state) {
      if (c.localId == localId) return c;
    }
    return null;
  }

  /// The newest pending capture for [projectId], if any — what a project card
  /// shows in place of the server status.
  PendingCapture? forProject(String projectId) {
    PendingCapture? found;
    for (final c in state) {
      if (c.projectId == projectId) found = c; // list is oldest-first
    }
    return found;
  }

  /// Inserts or replaces [capture]. Persists first, so the list never shows a
  /// record the next launch would not. A capture owned by someone other than
  /// the signed-in user is refused — that is the cross-account guarantee.
  Future<void> upsert(PendingCapture capture) async {
    if (_owner == null || capture.ownerUserId != _owner) {
      throw StateError('pending capture is not owned by the signed-in user');
    }
    await _store.put(capture);
    _apply(capture);
  }

  /// Applies [change] to the record for [localId] and persists the result.
  /// Returns the updated record, or null when it no longer exists (deleted
  /// underneath the caller) — a transition on a gone record is a no-op.
  Future<PendingCapture?> mutate(
    String localId,
    PendingCapture Function(PendingCapture current) change,
  ) async {
    final current = byLocalId(localId) ?? await _ownedFromStore(localId);
    if (current == null) return null;
    final next = change(current).copyWith(updatedAt: DateTime.now().toUtc());
    await _store.put(next);
    _apply(next);
    return next;
  }

  /// An offline-created project was reconciled ([tempId] → [serverId]): every
  /// waiting capture of it adopts the server id. The in-memory list moves
  /// FIRST (synchronously), so a caller that just watched the outbox flush
  /// sees the server id at once; the store follows. Records of other owners on
  /// disk are left for their owner's next login (the durable temp → server
  /// mapping in LevelProgressionStore covers them).
  Future<void> reKeyProject(String tempId, String serverId) async {
    if (tempId == serverId) return;
    final moved = [
      for (final c in state)
        if (c.projectId == tempId)
          c.copyWith(projectId: serverId, updatedAt: DateTime.now().toUtc()),
    ];
    if (moved.isEmpty) return;
    for (final c in moved) {
      _apply(c);
    }
    for (final c in moved) {
      try {
        await _store.put(c);
      } catch (_) {/* the durable mapping still resolves it on next drain */}
    }
  }

  /// Removes the record (upload confirmed, or the user deleted the capture).
  /// Removing the photos on disk is the caller's job — this is bookkeeping.
  Future<void> remove(String localId) async {
    await _store.remove(localId);
    state = [
      for (final c in state)
        if (c.localId != localId) c,
    ];
  }

  // ── internals ─────────────────────────────────────────────────────────────

  Future<void> _load(int gen, String owner) async {
    List<PendingCapture> loaded;
    try {
      loaded = await _store.listFor(owner);
    } catch (_) {
      loaded = const []; // unreadable store → nothing waiting, never a crash
    }
    if (gen != _generation) return; // the user changed while we were reading
    // Merge: anything written in memory while the load ran wins over disk.
    final byId = {for (final c in loaded) c.localId: c};
    for (final c in state) {
      byId[c.localId] = c;
    }
    state = pendingCapturesOwnedBy(byId.values, owner);
  }

  Future<PendingCapture?> _ownedFromStore(String localId) async {
    try {
      final c = await _store.get(localId);
      return (c != null && c.ownerUserId == _owner) ? c : null;
    } catch (_) {
      return null;
    }
  }

  void _apply(PendingCapture capture) {
    if (capture.ownerUserId != _owner) return;
    state = pendingCapturesOwnedBy(
      [
        for (final c in state)
          if (c.localId != capture.localId) c,
        capture,
      ],
      _owner,
    );
  }
}
