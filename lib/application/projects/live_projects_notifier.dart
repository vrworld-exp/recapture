// lib/application/projects/live_projects_notifier.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/live_projects_repository.dart';
import '../../domain/entities/live_project.dart';

/// Immutable state of the staff-only Live projects list: the loaded rows plus
/// the pagination position.
class LiveProjectsState {
  const LiveProjectsState({
    required this.items,
    required this.nextCursor,
    this.isLoadingMore = false,
  });

  final List<LiveProject> items;

  /// Cursor for the next page; null once the last page is loaded.
  final String? nextCursor;

  /// True while a load-more fetch is in flight (drives the list footer).
  final bool isLoadingMore;

  bool get hasMore => nextCursor != null;

  LiveProjectsState copyWith({
    List<LiveProject>? items,
    String? nextCursor,
    bool clearCursor = false,
    bool? isLoadingMore,
  }) {
    return LiveProjectsState(
      items: items ?? this.items,
      nextCursor: clearCursor ? null : (nextCursor ?? this.nextCursor),
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
    );
  }
}

/// Owns the staff Live projects list (cross-user captured projects) —
/// first page on build, cursor-paginated [loadMore], pull-to-[refresh].
/// Follows the projects-state-layer pattern: pure state, every byte of HTTP
/// (and error translation) lives in [LiveProjectsRepository].
class LiveProjectsNotifier extends AsyncNotifier<LiveProjectsState> {
  LiveProjectsRepository get _repo => ref.read(liveProjectsRepositoryProvider);

  @override
  Future<LiveProjectsState> build() async {
    final page = await _repo.list();
    return LiveProjectsState(items: page.items, nextCursor: page.nextCursor);
  }

  /// Loads the next page and appends it. No-op while one is already in
  /// flight or when the last page was reached. A failed load-more never
  /// blanks the list — the loaded rows stay and the error is rethrown for
  /// the screen's snackbar.
  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || !current.hasMore || current.isLoadingMore) return;

    state = AsyncData(current.copyWith(isLoadingMore: true));
    try {
      final page = await _repo.list(cursor: current.nextCursor);
      state = AsyncData(LiveProjectsState(
        items: [...current.items, ...page.items],
        nextCursor: page.nextCursor,
      ));
    } catch (_) {
      state = AsyncData(current.copyWith(isLoadingMore: false));
      rethrow;
    }
  }

  /// Reloads from the first page, keeping the current list visible on
  /// failure (rethrows for the screen's error surface).
  Future<void> refresh() async {
    final page = await _repo.list();
    state = AsyncData(
      LiveProjectsState(items: page.items, nextCursor: page.nextCursor),
    );
  }
}

/// The staff Live projects list. Only watched from staff-gated UI — the
/// backend additionally enforces the role on every request.
final liveProjectsProvider =
    AsyncNotifierProvider<LiveProjectsNotifier, LiveProjectsState>(
  LiveProjectsNotifier.new,
);
