// lib/application/catalog/catalog_products_notifier.dart
import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_failure.dart';
import '../../data/repositories/catalog_products_repository.dart';
import '../../domain/entities/catalog_product.dart';
import '../../domain/entities/product_availability.dart';
import '../../domain/entities/product_type.dart';
import '../auth/auth_notifier.dart';
import '../common/pending_poll_loop.dart';

/// The category filter value that means "products with no category".
///
/// The backend reads the literal string `none` for this; a null
/// [CatalogProductQuery.categoryId] is the third, different thing — no category
/// filter at all.
const String kUncategorizedFilterId = 'none';

/// How many products one page asks for.
const int kProductPageSize = 20;

/// How long the search box waits before it becomes a request.
///
/// Server-side search is the only correct kind here (a client-side filter over
/// the loaded page would quietly stop matching past page 1), so every keystroke
/// is a potential round trip and this is what stops it being one.
const Duration kProductSearchDebounce = Duration(milliseconds: 300);

/// Sentinel for "argument not supplied" where null is itself a valid value.
const Object _unset = Object();

/// What the grid is currently asking the server for.
///
/// Every field here is part of the REQUEST, never a post-filter over what came
/// back. That is the whole contract of this class: a query the client applies
/// locally is a query that lies as soon as there is a second page.
@immutable
class CatalogProductQuery {
  const CatalogProductQuery({
    this.categoryId,
    this.type,
    this.availability,
    this.search = '',
    this.includeArchived = false,
  });

  /// A real category id, [kUncategorizedFilterId], or null for "any category".
  final String? categoryId;
  final ProductType? type;
  final ProductAvailability? availability;

  /// Raw text as typed. Trimmed at the request boundary, not here, so the field
  /// and the state never disagree about what the user has in the box.
  final String search;

  /// The Archived chip. Archived products are excluded by default.
  final bool includeArchived;

  String? get searchTerm {
    final trimmed = search.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Whether anything at all narrows this query.
  ///
  /// Drives the difference between "you have no products" and "nothing matches
  /// these filters" — two states that must never share copy, and the reason a
  /// first-run empty screen cannot say "clear filters".
  bool get isFiltered =>
      categoryId != null ||
      type != null ||
      availability != null ||
      includeArchived ||
      searchTerm != null;

  /// Number of active chips, for the "Filters (2)" affordance.
  int get activeFilterCount =>
      (categoryId != null ? 1 : 0) +
      (type != null ? 1 : 0) +
      (availability != null ? 1 : 0) +
      (includeArchived ? 1 : 0);

  CatalogProductQuery copyWith({
    Object? categoryId = _unset,
    Object? type = _unset,
    Object? availability = _unset,
    String? search,
    bool? includeArchived,
  }) =>
      CatalogProductQuery(
        categoryId: identical(categoryId, _unset)
            ? this.categoryId
            : categoryId as String?,
        type: identical(type, _unset) ? this.type : type as ProductType?,
        availability: identical(availability, _unset)
            ? this.availability
            : availability as ProductAvailability?,
        search: search ?? this.search,
        includeArchived: includeArchived ?? this.includeArchived,
      );

  @override
  bool operator ==(Object other) =>
      other is CatalogProductQuery &&
      other.categoryId == categoryId &&
      other.type == type &&
      other.availability == availability &&
      other.search == search &&
      other.includeArchived == includeArchived;

  @override
  int get hashCode =>
      Object.hash(categoryId, type, availability, search, includeArchived);
}

/// Everything the product grid renders from.
///
/// The four states the screen must tell apart are all derivable here, and none
/// of them is merely "the list is empty":
///   • [isLoading] with no items      → skeletons (first load / retry)
///   • [error] non-null               → the load failed outright
///   • empty + `query.isFiltered`     → nothing MATCHES (offer "clear filters")
///   • empty + unfiltered             → the catalog has no products at all
///
/// [appendError] is deliberately separate from [error]: a failed page 3 must
/// leave pages 1 and 2 on screen with a retry in the footer, not replace the
/// whole grid with an error.
@immutable
class CatalogProductsState {
  const CatalogProductsState({
    required this.query,
    this.items = const <CatalogProduct>[],
    this.nextCursor,
    this.isLoading = true,
    this.isAppending = false,
    this.error,
    this.appendError,
  });

  final CatalogProductQuery query;
  final List<CatalogProduct> items;

  /// Opaque server cursor. Null once the last page has been read.
  final String? nextCursor;

  /// A first-page load is in flight AND the grid should show skeletons. False
  /// during a pull-to-refresh, which keeps the current items visible.
  final bool isLoading;

  /// A next-page load is in flight (footer spinner).
  final bool isAppending;

  /// The first page failed — there is nothing to show.
  final CatalogFailure? error;

  /// A next page failed. The loaded pages are untouched.
  final CatalogFailure? appendError;

  bool get hasMore => nextCursor != null;

  /// No products came back and we are not still looking for them.
  bool get isEmpty => items.isEmpty && !isLoading && error == null;

  /// Nothing matched a query that was narrowed.
  bool get isFilteredEmpty => isEmpty && query.isFiltered;

  /// The catalog genuinely holds no products.
  bool get isFirstRunEmpty => isEmpty && !query.isFiltered;

  /// Whether dragging a card to a new place is meaningful right now.
  ///
  /// Only on the plain, unfiltered list. The server renumbers exactly the ids it
  /// is sent to 0..n-1, which is correct for a CONTIGUOUS block off the front of
  /// the list and wrong for a filtered subset — reordering the three products
  /// that happen to match "chair" would drag them ahead of everything else in
  /// the catalog. So the affordance is hidden rather than allowed to lie.
  bool get canReorder =>
      !query.isFiltered && error == null && !isLoading && items.length > 1;

  CatalogProductsState copyWith({
    CatalogProductQuery? query,
    List<CatalogProduct>? items,
    Object? nextCursor = _unset,
    bool? isLoading,
    bool? isAppending,
    Object? error = _unset,
    Object? appendError = _unset,
  }) =>
      CatalogProductsState(
        query: query ?? this.query,
        items: items ?? this.items,
        nextCursor: identical(nextCursor, _unset)
            ? this.nextCursor
            : nextCursor as String?,
        isLoading: isLoading ?? this.isLoading,
        isAppending: isAppending ?? this.isAppending,
        error: identical(error, _unset) ? this.error : error as CatalogFailure?,
        appendError: identical(appendError, _unset)
            ? this.appendError
            : appendError as CatalogFailure?,
      );
}

/// Owns the product grid: the query, the loaded pages, and every transition
/// between them.
///
/// Invariants:
///   - No HTTP here — everything goes through [CatalogProductsRepository].
///   - Filtering and searching are SERVER-side. Nothing in this class filters
///     [CatalogProductsState.items] locally.
///   - Every request carries a generation stamp; a response whose stamp is stale
///     (the filters moved while it was in flight) is DISCARDED, never appended.
///   - A failed append never destroys loaded pages.
///   - An optimistic reorder always has a rollback.
class CatalogProductsNotifier extends Notifier<CatalogProductsState> {
  Timer? _debounce;

  /// Watches dishes whose 3D model is still generating, so a card flips from
  /// "3D generating" to "AR ready" while the rep is still looking at it.
  ///
  /// The SHARED cadence, not a second one — see PendingPollLoop. Created lazily
  /// because a grid with nothing pending must never schedule a tick at all.
  PendingPollLoop? _modelPoll;

  /// Bumped by anything that invalidates in-flight work (a filter change, a new
  /// search, a refresh). A response carrying an older stamp is stale.
  int _generation = 0;

  bool _disposed = false;

  CatalogProductsRepository get _repo =>
      ref.read(catalogProductsRepositoryProvider);

  @override
  CatalogProductsState build() {
    // The grid is scoped to the session that loaded it. Watching this is what
    // makes a sign-out drop the previous user's products AND the next sign-in
    // load the new user's with skeletons — without it the provider loaded once
    // per app run and whatever it held then stayed on screen, unrefreshed and
    // with nothing to show a load was even pending.
    final session = ref.watch(sessionIdentityProvider);

    // A rebuild REUSES this notifier instance, so the per-session scratch state
    // is reset by hand. The generation bump is the important one: a page still
    // in flight from the previous session must not land in the new one's grid.
    _disposed = false;
    _generation++;
    _debounce?.cancel();
    _debounce = null;

    ref.onDispose(() {
      _disposed = true;
      _debounce?.cancel();
      // The loop dies with the screen. Without this it would keep polling on
      // behalf of a route nobody is looking at.
      _modelPoll?.stop();
    });

    // Signed out: an empty grid that is NOT loading, so nothing is requested
    // without a token and no skeletons sit spinning behind the auth screen.
    if (session == null) {
      return const CatalogProductsState(
        query: CatalogProductQuery(),
        isLoading: false,
      );
    }

    // The first page is fetched off the build, not inside it: build() must
    // return state synchronously, and the microtask lands after this provider
    // is fully initialised.
    scheduleMicrotask(() {
      if (_disposed) return;
      _load(showSkeleton: true);
    });

    return const CatalogProductsState(query: CatalogProductQuery());
  }

  // ── Filters ───────────────────────────────────────────────────────────────

  /// Pass [kUncategorizedFilterId] for the Uncategorized bucket, null to clear.
  void setCategory(String? categoryId) =>
      _applyQuery(state.query.copyWith(categoryId: categoryId));

  void setType(ProductType? type) =>
      _applyQuery(state.query.copyWith(type: type));

  void setAvailability(ProductAvailability? availability) =>
      _applyQuery(state.query.copyWith(availability: availability));

  void setIncludeArchived(bool includeArchived) =>
      _applyQuery(state.query.copyWith(includeArchived: includeArchived));

  /// Clears every filter AND the search box.
  void clearFilters() {
    _debounce?.cancel();
    _applyQuery(const CatalogProductQuery());
  }

  /// Types into the search box. The state updates immediately (so the field is
  /// never laggy) and the request is debounced.
  void search(String text) {
    if (text == state.query.search) return;
    state = state.copyWith(query: state.query.copyWith(search: text));

    _debounce?.cancel();
    _debounce = Timer(kProductSearchDebounce, () {
      if (_disposed) return;
      _load(showSkeleton: true);
    });
  }

  /// A filter change resets pagination — the cursor belonged to the old query.
  void _applyQuery(CatalogProductQuery query) {
    if (query == state.query) return;
    _debounce?.cancel();
    state = state.copyWith(query: query);
    _load(showSkeleton: true);
  }

  // ── Loading ───────────────────────────────────────────────────────────────

  /// Pull-to-refresh / return-to-screen. Keeps the current items on screen
  /// instead of flashing skeletons, and resets to page 1 because a cursor is
  /// only meaningful against the page it came from.
  Future<void> refresh() => _load(showSkeleton: false);

  /// Retry after a first-page failure — this one DOES show skeletons, because
  /// there is nothing on screen to preserve.
  Future<void> retry() => _load(showSkeleton: true);

  Future<void> _load({required bool showSkeleton}) async {
    final generation = ++_generation;
    final query = state.query;

    state = state.copyWith(
      isLoading: showSkeleton,
      isAppending: false,
      error: null,
      appendError: null,
    );

    try {
      final page = await _repo.list(
        limit: kProductPageSize,
        categoryId: query.categoryId,
        type: query.type,
        availability: query.availability,
        query: query.searchTerm,
        includeArchived: query.includeArchived,
      );
      if (_isStale(generation)) return;
      state = state.copyWith(
        items: page.items,
        nextCursor: page.nextCursor,
        isLoading: false,
      );
      // A fresh load is a fresh wait: reset the cadence so a dish that just
      // started generating is checked in 3s, not at whatever interval a
      // previous wait had backed off to.
      _restartModelPolling();
    } on CatalogFailure catch (failure) {
      if (_isStale(generation)) return;
      // A failed background refresh keeps what is on screen and reports itself
      // in the footer; only a failure with nothing behind it takes the screen.
      final blank = showSkeleton || state.items.isEmpty;
      state = state.copyWith(
        isLoading: false,
        error: blank ? failure : null,
        appendError: blank ? null : failure,
      );
    }
  }

  /// Loads the next page. Safe to call on every scroll frame near the bottom —
  /// the guards below are what stop the boundary firing two identical requests.
  Future<void> loadMore() async {
    final cursor = state.nextCursor;
    if (cursor == null ||
        state.isAppending ||
        state.isLoading ||
        // A failed append waits for an explicit retry rather than hammering the
        // same cursor every time the user nudges the scroll view.
        state.appendError != null) {
      return;
    }

    // NOT a new generation: an append belongs to the query already on screen.
    // If that query changes while this is in flight the stamp goes stale and the
    // page is dropped — which is exactly the bug this guards against (a page of
    // the old filter appended under the new one).
    final generation = _generation;
    final query = state.query;

    state = state.copyWith(isAppending: true);

    try {
      final page = await _repo.list(
        limit: kProductPageSize,
        cursor: cursor,
        categoryId: query.categoryId,
        type: query.type,
        availability: query.availability,
        query: query.searchTerm,
        includeArchived: query.includeArchived,
      );
      if (_isStale(generation)) return;
      state = state.copyWith(
        items: _merge(state.items, page.items),
        nextCursor: page.nextCursor,
        isAppending: false,
      );
      // A later page can carry the first pending dish, so the loop has to be
      // re-evaluated on an append and not only on a first load.
      _scheduleModelPolling();
    } on CatalogFailure catch (failure) {
      if (_isStale(generation)) return;
      // Items untouched — the footer shows a retry, the grid keeps its pages.
      state = state.copyWith(isAppending: false, appendError: failure);
    }
  }

  /// Retries the page that failed, from the same cursor.
  Future<void> retryAppend() async {
    if (state.appendError == null) return;
    state = state.copyWith(appendError: null);
    await loadMore();
  }

  // ── Mutations the grid applies in place ───────────────────────────────────

  /// Replaces one product by id (an edit, a featured toggle, an archive that
  /// came back from the server). No-op when the id is not on screen — a product
  /// on an unloaded page is not a crash.
  void replace(CatalogProduct product) {
    if (!state.items.any((p) => p.id == product.id)) return;
    state = state.copyWith(
      items: [
        for (final item in state.items)
          if (item.id == product.id) product else item,
      ],
    );
  }

  /// Drops one product from the grid without a refetch.
  void removeById(String id) {
    if (!state.items.any((p) => p.id == id)) return;
    state = state.copyWith(
      items: [
        for (final item in state.items)
          if (item.id != id) item,
      ],
    );
  }

  /// Puts one product back at [index] — the inverse of [removeById], for an
  /// optimistic removal that has to be undone (a failed archive, an undo).
  void insertAt(int index, CatalogProduct product) {
    if (state.items.any((p) => p.id == product.id)) return;
    final items = [...state.items];
    items.insert(index.clamp(0, items.length), product);
    state = state.copyWith(items: items);
  }

  /// Archives a product (feature 19), optimistically.
  ///
  /// What "optimistic" means here depends on the current query, and both cases
  /// matter: with the Archived chip OFF the row LEAVES the grid, because that is
  /// what a refetch would do; with it ON the row stays and goes muted. Guessing
  /// the other way round would make the grid disagree with the server's own
  /// answer to the same query.
  ///
  /// Returns the index the row was at, so an undo can put it back where it was
  /// rather than on the end. Rethrows the [CatalogFailure] after rolling back —
  /// a failed archive must never leave the product hidden.
  Future<int> archive(String id) async {
    final index = state.items.indexWhere((p) => p.id == id);
    if (index == -1) {
      // Not on screen (an unloaded page, or another device got there first).
      // Confirm with the server and touch no state.
      await _repo.archive(id);
      return -1;
    }

    final previous = state.items;
    final product = previous[index];
    _applyArchived(index, product, archived: true);

    try {
      final updated = await _repo.archive(id);
      // Adopt the server's row where it is still on screen — `updatedAt` and
      // `syncStatus` are server-derived and the optimistic copy guessed neither.
      if (!_disposed && state.query.includeArchived) replace(updated);
    } on CatalogFailure {
      if (!_disposed) state = state.copyWith(items: previous);
      rethrow;
    }
    return index;
  }

  /// Restores an archived product (feature 20) — the exact inverse of [archive],
  /// including where the row goes: back to [index] when the caller knows it.
  Future<void> restore(String id, {int? index}) async {
    final current = state.items;
    final at = current.indexWhere((p) => p.id == id);
    final previous = current;

    if (at != -1) {
      _applyArchived(at, current[at], archived: false);
    }

    try {
      final updated = await _repo.restore(id);
      if (_disposed) return;
      if (at != -1) {
        replace(updated);
      } else if (index != null && !state.query.includeArchived) {
        // The undo path: the row was removed from an unarchived view, so putting
        // it back means re-inserting it where it came from.
        insertAt(index, updated);
      }
    } on CatalogFailure {
      if (!_disposed) state = state.copyWith(items: previous);
      rethrow;
    }
  }

  /// Permanently deletes a product (feature 21), optimistically.
  ///
  /// A double press is treated as success, not an error: the second call hits a
  /// row that is already gone, the backend answers the same indistinguishable
  /// NOT_FOUND it uses for "not yours", and the outcome the user wanted has
  /// happened either way.
  Future<void> delete(String id) async {
    final index = state.items.indexWhere((p) => p.id == id);
    final previous = state.items;
    if (index != -1) removeById(id);

    try {
      await _repo.delete(id);
    } on CatalogFailure catch (failure) {
      if (failure.isNotFound) return; // already gone — that IS the outcome
      if (!_disposed) state = state.copyWith(items: previous);
      rethrow;
    }
  }

  /// Applies a bulk run's SUCCEEDED ids to the loaded pages, in place.
  ///
  /// In place rather than a refetch, deliberately. A refetch resets to page 1,
  /// and a user who has scrolled through four pages to select forty products
  /// does not want the grid to snap back to twenty the moment the action lands.
  ///
  /// Only the ids the server agreed to are passed in — a failed item must stay
  /// exactly as it was, or the grid would show an archive that did not happen.
  void applyBulkOutcome({
    required BulkProductAction action,
    required List<String> ids,
    Object? categoryId = kCatalogUnchanged,
  }) {
    if (ids.isEmpty) return;
    final touched = ids.toSet();

    switch (action) {
      case BulkProductAction.delete:
        state = state.copyWith(
          items: [
            for (final item in state.items)
              if (!touched.contains(item.id)) item,
          ],
        );

      case BulkProductAction.archive:
      case BulkProductAction.restore:
        final archived = action == BulkProductAction.archive;
        // With the Archived chip ON the rows stay and change appearance; with it
        // OFF the query would no longer return the archived ones, so they leave.
        // Same rule as the single-row [archive], for the same reason: guessing
        // the other way makes the grid disagree with the server's own answer to
        // the query on screen.
        state = state.copyWith(
          items: [
            for (final item in state.items)
              if (!touched.contains(item.id))
                item
              else if (state.query.includeArchived)
                item.copyWith(isArchived: archived)
              else if (!archived)
                item,
          ],
        );

      case BulkProductAction.setCategory:
        final target = identical(categoryId, kCatalogUnchanged)
            ? null
            : categoryId as String?;
        final filter = state.query.categoryId;
        // A row moved OUT of the category being filtered on has left this view —
        // keeping it would show a "Chairs" filter listing something that is no
        // longer a chair. `kUncategorizedFilterId` is the literal the server
        // reads for "no category", so it is compared against a null target.
        bool stillMatches() {
          if (filter == null) return true;
          if (filter == kUncategorizedFilterId) return target == null;
          return filter == target;
        }

        state = state.copyWith(
          items: [
            for (final item in state.items)
              if (!touched.contains(item.id))
                item
              else if (stillMatches())
                item.copyWith(categoryId: target),
          ],
        );
    }
  }

  /// Flips one row's archived flag in place, or drops it when the current query
  /// would not have returned it.
  void _applyArchived(
    int index,
    CatalogProduct product, {
    required bool archived,
  }) {
    if (state.query.includeArchived) {
      state = state.copyWith(
        items: [
          for (var i = 0; i < state.items.length; i++)
            if (i == index)
              state.items[i].copyWith(isArchived: archived)
            else
              state.items[i],
        ],
      );
      return;
    }
    if (archived) {
      removeById(product.id);
    }
  }

  /// Moves the product at [oldIndex] to [newIndex], optimistically, then writes
  /// the new order.
  ///
  /// [newIndex] follows the `ReorderableListView` convention — it counts
  /// positions in the list BEFORE the dragged row is removed — so both the phone
  /// list and the wide grid hand their raw indices straight here rather than
  /// each doing the off-by-one themselves.
  ///
  /// Only the loaded, contiguous block is sent: the server accepts a subset and
  /// renumbers it 0..n-1 among themselves, which preserves the order of
  /// everything past the last loaded page. Rolls back visibly and rethrows the
  /// [CatalogFailure] so the screen can say what happened.
  Future<void> reorder(int oldIndex, int newIndex) async {
    if (!state.canReorder) return;

    final previous = state.items;
    if (oldIndex < 0 || oldIndex >= previous.length) return;

    var target = newIndex > oldIndex ? newIndex - 1 : newIndex;
    if (target < 0) target = 0;
    if (target >= previous.length) target = previous.length - 1;
    if (target == oldIndex) return;

    final reordered = [...previous];
    reordered.insert(target, reordered.removeAt(oldIndex));

    // Positions are renumbered by the server to the array index; mirroring that
    // locally keeps a later in-place update from re-sorting the grid.
    final optimistic = [
      for (var i = 0; i < reordered.length; i++)
        reordered[i].copyWith(position: i),
    ];
    state = state.copyWith(items: optimistic);

    try {
      await _repo.reorder([for (final item in optimistic) item.id]);
    } on CatalogFailure {
      // Rollback is unconditional: the server rejects a mismatched id set
      // wholesale, so a failure means NOTHING moved.
      if (!_disposed) state = state.copyWith(items: previous);
      rethrow;
    }
  }

  // ── Watching a model finish ───────────────────────────────────────────────

  /// Whether any loaded dish is still waiting on a 3D model.
  ///
  /// The loop's ONLY stop condition, and the same getter the badge reads — so
  /// "the badge says generating" and "the loop is running" can never disagree.
  bool get _hasPendingModels => state.items.any((p) => p.isModelPending);

  /// Whether the grid is currently watching for a model to finish. Exposed for
  /// the tests that assert the loop starts, stops, and honours its cap.
  bool get isPollingModels => _modelPoll?.isRunning ?? false;

  void _restartModelPolling() {
    _modelPoll?.reset();
    _scheduleModelPolling();
  }

  void _scheduleModelPolling() {
    if (_disposed) return;
    if (!_hasPendingModels) {
      _modelPoll?.stop();
      return;
    }
    (_modelPoll ??= PendingPollLoop(poll: _pollModels))
        .scheduleIfPending(isPending: true);
  }

  /// One poll. Re-reads page 1 — where a rep's newly added dish is — and
  /// answers whether anything is still pending.
  ///
  /// NEVER THROWS, and never blanks the grid: a dropped request on restaurant
  /// wifi leaves the loaded items exactly as they are and the next tick tries
  /// again. A permanent failure runs out the loop's own cap rather than
  /// reporting an error for something the rep did not ask for.
  Future<bool> _pollModels() async {
    if (_disposed) return false;
    final generation = _generation;
    final query = state.query;

    try {
      final page = await _repo.list(
        limit: kProductPageSize,
        categoryId: query.categoryId,
        type: query.type,
        availability: query.availability,
        query: query.searchTerm,
        includeArchived: query.includeArchived,
      );
      if (_isStale(generation)) return false;

      // Merged rather than replaced: pages past the first are still on screen,
      // and a poll that dropped them would undo the user's scrolling.
      final refreshed = {for (final item in page.items) item.id: item};
      state = state.copyWith(
        items: [
          for (final item in state.items) refreshed[item.id] ?? item,
          for (final item in page.items)
            if (!state.items.any((existing) => existing.id == item.id)) item,
        ],
      );
      return _hasPendingModels;
    } on CatalogFailure {
      // Last-good-state. Keep waiting against what is already on screen.
      return !_disposed && _hasPendingModels;
    }
  }

  // ── Internals ─────────────────────────────────────────────────────────────

  bool _isStale(int generation) => _disposed || generation != _generation;

  /// Appends [next] to [current], dropping ids already on screen.
  ///
  /// The cursor is `(position, _id)` and positions move under reorders and
  /// concurrent edits, so a page CAN carry a row we already have. A duplicate
  /// key in a grid is a runtime error, not a cosmetic problem.
  static List<CatalogProduct> _merge(
    List<CatalogProduct> current,
    List<CatalogProduct> next,
  ) {
    final seen = {for (final item in current) item.id};
    return [
      ...current,
      for (final item in next)
        if (seen.add(item.id)) item,
    ];
  }
}

/// The product grid's state.
final catalogProductsProvider =
    NotifierProvider<CatalogProductsNotifier, CatalogProductsState>(
  CatalogProductsNotifier.new,
);
