// lib/application/projects/projects_notifier.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/projects_cache_box.dart';
import '../../data/local/storage_providers.dart';
import '../../data/repositories/projects_repository.dart';
import '../../domain/entities/create_project_options.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/project_status.dart';
import '../auth/auth_notifier.dart';
import '../../domain/entities/auth_state.dart';

/// Owns the user's project collection and is the single source of truth the
/// Projects List, Create, and Options screens read from. State is an
/// `AsyncValue<List<Project>>`:
///   - `AsyncLoading`  → first load / explicit reload (full skeleton)
///   - `AsyncData`     → loaded (empty list ⇒ empty state in the UI)
///   - `AsyncError`    → load failed (mutation failures never blank the list)
///
/// Invariants:
///   - The notifier never touches HTTP — everything goes through
///     [ProjectsRepository].
///   - All list mutations key off `project.id`, never indices captured before an
///     await (indices shift under concurrent ops).
///   - Optimistic mutations always have a rollback path.
///   - `refresh()` never emits `AsyncLoading` (keeps the current list visible).
///   - State resets to empty on `AuthUnauthenticated` (no cross-user leakage).
class ProjectsNotifier extends AsyncNotifier<List<Project>> {
  ProjectsRepository get _repo => ref.read(projectsRepositoryProvider);
  ProjectsCacheBox get _cache => ref.read(projectsCacheBoxProvider);

  List<Project> get _current => state.valueOrNull ?? const <Project>[];

  @override
  Future<List<Project>> build() async {
    // Clear the list the moment auth drops, so the next user never sees stale
    // data. Registered once per build; Riverpod tears it down automatically.
    // (The on-disk cache is cleared by AuthNotifier on logout.)
    ref.listen<AuthState>(authProvider, (_, next) {
      if (next is AuthUnauthenticated) {
        state = const AsyncData<List<Project>>([]);
      }
    });

    // Stale-while-revalidate: paint cached projects immediately (no skeleton),
    // then refresh in the background and update both state and cache.
    final cached = await _readCache();
    if (cached != null && cached.isNotEmpty) {
      _revalidate();
      return cached;
    }

    // Cold start (no usable cache) → normal load; seed the cache on success.
    final fresh = await _repo.list();
    await _writeCache(fresh);
    return fresh;
  }

  /// Background revalidation for the stale-while-revalidate path. Silent on
  /// failure — a failed background refresh keeps the cached list visible rather
  /// than blanking or erroring it.
  Future<void> _revalidate() async {
    try {
      final fresh = await _repo.list();
      state = AsyncData(fresh);
      await _writeCache(fresh);
    } catch (_) {/* keep cached data; revalidation is best-effort */}
  }

  /// Pull-to-refresh / post-action re-fetch. Does NOT emit `AsyncLoading`, so the
  /// current list stays visible (no skeleton). On success it updates state and
  /// the cache; on failure the last good list is preserved and the error is
  /// rethrown for the screen's offline modal (cache left untouched).
  Future<void> refresh() async {
    final fresh = await _repo.list(); // throws → list + cache untouched
    state = AsyncData(fresh);
    await _writeCache(fresh);
  }

  /// Creates a project and prepends it so it appears at the top of the list
  /// without a refetch. Not optimistic (there is nothing to show until the
  /// server confirms); rethrows on failure leaving the list untouched.
  Future<Project> create({
    required String name,
    required ObjectSize size,
    required CaptureMode mode,
  }) async {
    final created = await _repo.create(name: name, size: size, mode: mode);
    state = AsyncData<List<Project>>([created, ..._current]);
    return created;
  }

  /// Optimistically renames the project, then confirms with the repo. Rolls back
  /// to the original name on failure and rethrows for the offline modal.
  Future<void> rename(String id, String newName) async {
    final current = _current;
    final original = _firstWhereOrNull(current, id);
    if (original == null) {
      // Stale UI — the project is gone from this list. Reconcile via the repo
      // without touching state, so we neither crash nor resurrect a stale row.
      await _repo.rename(id, newName);
      return;
    }

    _replaceById(id, original.copyWith(name: newName, updatedAt: DateTime.now()));
    try {
      await _repo.rename(id, newName);
    } catch (_) {
      _replaceById(id, original); // rollback by id (index may have shifted)
      rethrow;
    }
  }

  /// Optimistically removes the project, then confirms with the repo. Restores
  /// the removed project (in its original position when still applicable) on
  /// failure and rethrows.
  Future<void> delete(String id) async {
    final current = _current;
    final index = current.indexWhere((p) => p.id == id);
    if (index == -1) {
      // Already gone (e.g. a rapid double-delete) — confirm with the repo but
      // make no further state change.
      await _repo.delete(id);
      return;
    }
    final removed = current[index];

    state = AsyncData<List<Project>>(
      [for (final p in current) if (p.id != id) p],
    );
    try {
      await _repo.delete(id);
    } catch (_) {
      // Rollback: re-insert by id at its original index when the list shape
      // still allows it, else append. Keyed off the live list (it may have
      // changed under a concurrent op).
      final list = [..._current];
      if (!list.any((p) => p.id == id)) {
        final insertAt = index <= list.length ? index : list.length;
        list.insert(insertAt, removed);
        state = AsyncData<List<Project>>(list);
      }
      rethrow;
    }
  }

  /// Re-queues a failed project. Optimistically flips its status to `processing`
  /// for instant feedback, confirms with the repo, and rolls back to the
  /// original status on failure.
  Future<void> retry(String id) async {
    final original = _firstWhereOrNull(_current, id);
    if (original == null) {
      await _repo.retry(id); // stale UI — reconcile without touching state
      return;
    }

    updateStatus(id, ProjectStatus.processing);
    try {
      await _repo.retry(id);
    } catch (_) {
      _replaceById(id, original); // restore the prior status
      rethrow;
    }
  }

  /// In-place single-project status update — used by retry and by refresh
  /// diffing. No-op (no crash) when [id] is not in the current list.
  void updateStatus(String id, ProjectStatus status, {Project? replacement}) {
    final current = _current;
    final existing = _firstWhereOrNull(current, id);
    if (existing == null) return;
    _replaceById(id, replacement ?? existing.copyWith(status: status));
  }

  // ── Internals (all id-keyed) ───────────────────────────────────────────────

  void _replaceById(String id, Project updated) {
    state = AsyncData<List<Project>>(
      [for (final p in _current) if (p.id == id) updated else p],
    );
  }

  static Project? _firstWhereOrNull(List<Project> list, String id) {
    for (final p in list) {
      if (p.id == id) return p;
    }
    return null;
  }

  // ── Cache (best-effort; never breaks the list) ─────────────────────────────

  Future<List<Project>?> _readCache() async {
    try {
      final cached = await _cache.read();
      return cached?.projects;
    } catch (_) {
      return null; // unreadable cache → behave as a cold start
    }
  }

  Future<void> _writeCache(List<Project> projects) async {
    try {
      await _cache.save(projects);
    } catch (_) {/* cache write failure must not affect the visible list */}
  }
}

/// App-wide projects state. The single source of truth for the project list.
final projectsProvider =
    AsyncNotifierProvider<ProjectsNotifier, List<Project>>(
  ProjectsNotifier.new,
);
