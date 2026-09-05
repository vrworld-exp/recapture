// lib/application/catalog/bulk_selection_notifier.dart
//
// Selection mode over the product grid, and the bulk runs it starts (feature
// 30, T-022).
//
// The hard part of this feature is not selecting things — it is REPORTING. The
// backend's `POST /catalog/products/bulk` is all-or-nothing per call: it counts
// the ids that are live products of the caller's catalog and, if that count does
// not match, applies nothing and answers `ID_SET_MISMATCH`. So a run of 20
// products with one row deleted on another device fails ENTIRELY, and a UI that
// forwarded that verdict would tell the user their 19 good products failed too.
//
// This class turns that into per-item outcomes the honest way: chunk, and on the
// one deterministic, id-scoped rejection the server has, BISECT the chunk until
// the offending ids are isolated. Every other failure (offline, 5xx, rate limit,
// a category that vanished) is not id-scoped, so splitting it would only
// multiply the same failure — those mark their whole chunk failed, with the
// server's own sentence attached.
//
// The result is never flattened: [BulkRunResult] carries the ids that worked and
// the ids that did not, and the screen retries only the latter.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_failure.dart';
import '../../data/repositories/catalog_products_repository.dart';
import '../../domain/entities/catalog_product.dart';
import 'catalog_products_notifier.dart';

/// How many extra requests one run may spend isolating the ids inside a chunk
/// the server rejected wholesale.
///
/// Bisection costs about `2 * log2(n)` requests per bad id, so this covers
/// several bad ids in a 200-id chunk and still bounds a pathological run — a
/// selection where EVERY id is stale would otherwise turn into 400 requests.
/// When the budget runs out the remaining ids are reported as FAILED rather than
/// quietly counted as successes, and [BulkRunResult.isolationExhausted] says so.
const int kBulkIsolationBudget = 48;

/// Everything selection mode renders from.
@immutable
class BulkSelectionState {
  const BulkSelectionState({
    this.isActive = false,
    this.ids = const <String>{},
    this.anchorId,
    this.clearedByFilterChange = false,
    this.scopedToLoaded = false,
    this.isRunning = false,
  });

  /// Whether the grid is in selection mode at all.
  ///
  /// Distinct from "nothing is selected": an active mode with an empty set is a
  /// real state (the user cleared the set and is picking again), and the cards
  /// must keep their checkboxes through it.
  final bool isActive;

  /// The selected product ids.
  ///
  /// IDS, not products, and that is what makes selection survive scrolling and
  /// pagination: a page that has not been loaded yet cannot evict a selection,
  /// and neither can a card being recycled off screen.
  final Set<String> ids;

  /// The last card the user activated — the fixed end of a `Shift+click` range.
  final String? anchorId;

  /// The selection was dropped because the filters moved. Rendered as a
  /// sentence, then cleared: silently emptying a selection is how a user
  /// presses Archive believing 20 rows are still chosen.
  final bool clearedByFilterChange;

  /// The last select-all covered only the LOADED products, not every product
  /// matching the filter. Said out loud for the same reason.
  final bool scopedToLoaded;

  /// A bulk run is in flight.
  final bool isRunning;

  int get count => ids.length;
  bool get isEmpty => ids.isEmpty;
  bool contains(String id) => ids.contains(id);

  BulkSelectionState copyWith({
    bool? isActive,
    Set<String>? ids,
    Object? anchorId = _unset,
    bool? clearedByFilterChange,
    bool? scopedToLoaded,
    bool? isRunning,
  }) =>
      BulkSelectionState(
        isActive: isActive ?? this.isActive,
        ids: ids ?? this.ids,
        anchorId:
            identical(anchorId, _unset) ? this.anchorId : anchorId as String?,
        clearedByFilterChange:
            clearedByFilterChange ?? this.clearedByFilterChange,
        scopedToLoaded: scopedToLoaded ?? this.scopedToLoaded,
        isRunning: isRunning ?? this.isRunning,
      );
}

const Object _unset = Object();

/// One product a bulk run could not apply its action to.
@immutable
class BulkItemFailure {
  const BulkItemFailure({
    required this.id,
    required this.name,
    required this.failure,
  });

  final String id;

  /// The product's name at the time the run started, so the report can say
  /// WHICH products failed. Falls back to the id when the row was not loaded —
  /// an unhelpful line is still better than a silently dropped one.
  final String name;

  final CatalogFailure failure;
}

/// What actually happened, per item.
///
/// The whole point of this type is that it cannot say "done" about a run that
/// was not: [succeeded] and [failed] are both explicit, and the screen renders
/// from both.
@immutable
class BulkRunResult {
  const BulkRunResult({
    required this.action,
    required this.succeeded,
    required this.failed,
    this.isolationExhausted = false,
  });

  final BulkProductAction action;
  final List<String> succeeded;
  final List<BulkItemFailure> failed;

  /// The isolation budget ran out, so some entries in [failed] may be innocent
  /// products that shared a chunk with a bad one. Reported honestly rather than
  /// hidden: they are still products the action did NOT reach.
  final bool isolationExhausted;

  int get requested => succeeded.length + failed.length;
  bool get isCompleteSuccess => failed.isEmpty && succeeded.isNotEmpty;
  bool get isCompleteFailure => succeeded.isEmpty && failed.isNotEmpty;
  bool get isPartial => succeeded.isNotEmpty && failed.isNotEmpty;

  List<String> get failedIds => [for (final item in failed) item.id];
}

/// Owns selection mode and the bulk runs it starts.
///
/// Invariants:
///   - No HTTP here — everything goes through [CatalogProductsRepository].
///   - Selection is a set of IDS and never a set of products, so it survives
///     scrolling, pagination and card recycling.
///   - Selection does NOT survive a filter change. The set is dropped and the
///     drop is ANNOUNCED — a filter change means the user is looking at a
///     different set of rows, and quietly carrying an invisible selection into
///     a destructive action is the worst failure this feature could have.
///   - A run never reports success it did not get. See the file header.
class BulkSelectionNotifier extends Notifier<BulkSelectionState> {
  CatalogProductsRepository get _repo =>
      ref.read(catalogProductsRepositoryProvider);

  @override
  BulkSelectionState build() {
    ref.listen<CatalogProductQuery>(
      catalogProductsProvider.select((s) => s.query),
      (previous, next) {
        // The FIRST notification is the initial query settling, not a change.
        if (previous == null || previous == next) return;
        _onFilterChanged();
      },
    );
    return const BulkSelectionState();
  }

  // ── Entering and leaving ──────────────────────────────────────────────────

  /// Enters selection mode, optionally selecting [id] (the long-press / the
  /// modifier-click that started it).
  void enter([String? id]) {
    state = BulkSelectionState(
      isActive: true,
      ids: id == null ? const <String>{} : {id},
      anchorId: id,
    );
  }

  /// Leaves selection mode and drops the selection.
  void exit() => state = const BulkSelectionState();

  /// Empties the selection but stays in selection mode.
  void clear() => state = state.copyWith(
        ids: const <String>{},
        anchorId: null,
        clearedByFilterChange: false,
        scopedToLoaded: false,
      );

  /// Acknowledges the "we cleared your selection / we only covered what is
  /// loaded" notes, so they are said once rather than pinned to the bar.
  void acknowledgeNotes() => state = state.copyWith(
        clearedByFilterChange: false,
        scopedToLoaded: false,
      );

  // ── Selecting ─────────────────────────────────────────────────────────────

  /// Toggles one product, and moves the range anchor to it.
  void toggle(String id) {
    if (!state.isActive) {
      enter(id);
      return;
    }
    final ids = {...state.ids};
    if (!ids.remove(id)) ids.add(id);
    state = state.copyWith(
      ids: ids,
      anchorId: id,
      clearedByFilterChange: false,
      scopedToLoaded: false,
    );
  }

  /// Adds every loaded product between the current anchor and [id] inclusive —
  /// the `Shift+click` gesture.
  ///
  /// Scoped to the LOADED order, which is the only order the client knows: a
  /// range over rows the user has not seen would select products they cannot
  /// name. With no anchor (or an anchor that has scrolled out of the loaded
  /// window) this degrades to a plain toggle rather than guessing a range.
  void selectRangeTo(String id) {
    final items = ref.read(catalogProductsProvider).items;
    final anchor = state.anchorId;
    final from = anchor == null
        ? -1
        : items.indexWhere((product) => product.id == anchor);
    final to = items.indexWhere((product) => product.id == id);

    if (from == -1 || to == -1) {
      toggle(id);
      return;
    }

    final lower = from < to ? from : to;
    final upper = from < to ? to : from;
    final ids = {...state.ids};
    for (var i = lower; i <= upper; i++) {
      ids.add(items[i].id);
    }
    // The anchor STAYS put, so dragging the shift-click further extends the same
    // range rather than starting a new one from where it last landed.
    state = state.copyWith(
      isActive: true,
      ids: ids,
      clearedByFilterChange: false,
      scopedToLoaded: false,
    );
  }

  /// Selects every LOADED product — `Ctrl/Cmd+A`, and the bar's Select all.
  ///
  /// Deliberately not "everything matching the filter": the server has no
  /// select-all endpoint, and applying an action to more products than the user
  /// has seen is not something a client should do on its own. The scope is
  /// flagged on the state so the bar can say so.
  void selectAllLoaded() {
    final items = ref.read(catalogProductsProvider).items;
    if (items.isEmpty) return;
    final hasMore = ref.read(catalogProductsProvider).hasMore;
    state = state.copyWith(
      isActive: true,
      ids: {for (final product in items) product.id},
      anchorId: items.first.id,
      clearedByFilterChange: false,
      scopedToLoaded: hasMore,
    );
  }

  /// Replaces the selection with exactly [ids] — the retry path, which re-runs
  /// against the failed subset and nothing else.
  void selectOnly(Iterable<String> ids) => state = state.copyWith(
        isActive: true,
        ids: {...ids},
        anchorId: null,
        clearedByFilterChange: false,
        scopedToLoaded: false,
      );

  /// A filter or search change means a different set of rows. The selection goes
  /// with it — and says so.
  void _onFilterChanged() {
    if (!state.isActive || state.ids.isEmpty) return;
    state = state.copyWith(
      ids: const <String>{},
      anchorId: null,
      clearedByFilterChange: true,
      scopedToLoaded: false,
    );
  }

  // ── Running ───────────────────────────────────────────────────────────────

  /// Applies [action] to the selection and reports what happened, per item.
  ///
  /// [categoryId] is required by [BulkProductAction.setCategory] (null means
  /// Uncategorized) and must be left at [kCatalogUnchanged] for every other
  /// action — the server rejects it otherwise.
  ///
  /// Never throws: a failure is a [BulkRunResult] with entries in
  /// [BulkRunResult.failed], because "some of it failed" is the normal outcome
  /// this feature exists to report rather than an exceptional one.
  Future<BulkRunResult> run({
    required BulkProductAction action,
    Object? categoryId = kCatalogUnchanged,
  }) async {
    final ids = orderedSelection();
    if (ids.isEmpty) {
      return BulkRunResult(
        action: action,
        succeeded: const <String>[],
        failed: const <BulkItemFailure>[],
      );
    }

    // Captured BEFORE the run: the rows may leave the grid as a result of it,
    // and a report that can only say "3 products failed" is not a report.
    final names = {
      for (final product in ref.read(catalogProductsProvider).items)
        product.id: product.name,
    };

    state = state.copyWith(isRunning: true);

    final succeeded = <String>[];
    final failed = <BulkItemFailure>[];
    var budget = kBulkIsolationBudget;
    var exhausted = false;

    Future<void> apply(List<String> chunk) async {
      try {
        await _repo.bulk(action: action, ids: chunk, categoryId: categoryId);
        succeeded.addAll(chunk);
      } on CatalogFailure catch (failure) {
        // ID_SET_MISMATCH is the ONE failure that is both deterministic and
        // scoped to particular ids: the server refused the chunk because at
        // least one of them is not a live product of this catalog. Halving it
        // finds which. Every other failure — offline, 5xx, RATE_LIMITED, a
        // CATEGORY_NOT_FOUND that applies to the whole run — would fail
        // identically on every half, so splitting it would just make N failing
        // requests out of one.
        final splittable =
            failure.code == CatalogErrorCodes.idSetMismatch && chunk.length > 1;
        if (splittable && budget >= 2) {
          budget -= 2;
          final mid = chunk.length ~/ 2;
          await apply(chunk.sublist(0, mid));
          await apply(chunk.sublist(mid));
          return;
        }
        if (splittable) exhausted = true;
        failed.addAll([
          for (final id in chunk)
            BulkItemFailure(id: id, name: names[id] ?? id, failure: failure),
        ]);
      }
    }

    for (var start = 0; start < ids.length; start += kBulkProductIdLimit) {
      final end = start + kBulkProductIdLimit;
      await apply(ids.sublist(start, end > ids.length ? ids.length : end));
    }

    final result = BulkRunResult(
      action: action,
      succeeded: succeeded,
      failed: failed,
      isolationExhausted: exhausted,
    );

    // Only the ids that actually moved are applied to the grid. The failed ones
    // are left exactly as they were, and stay selected so a retry has something
    // to retry.
    if (succeeded.isNotEmpty) {
      ref.read(catalogProductsProvider.notifier).applyBulkOutcome(
            action: action,
            ids: succeeded,
            categoryId: categoryId,
          );
    }

    state = state.copyWith(
      isRunning: false,
      ids: {for (final item in failed) item.id},
      anchorId: null,
    );

    return result;
  }

  /// The selection in the order the grid shows it, with any ids that are no
  /// longer loaded appended.
  ///
  /// Ordered so the failure report reads in the same order as the grid, and so
  /// chunk boundaries are stable between a run and its retry. The tail matters:
  /// a selected product whose page was evicted is still selected, and dropping
  /// it here would silently shrink the action the user asked for.
  List<String> orderedSelection() {
    final items = ref.read(catalogProductsProvider).items;
    final selected = state.ids;
    final ordered = <String>[
      for (final CatalogProduct product in items)
        if (selected.contains(product.id)) product.id,
    ];
    final seen = ordered.toSet();
    return [
      ...ordered,
      for (final id in selected)
        if (!seen.contains(id)) id,
    ];
  }
}

/// Selection mode over the product grid.
final bulkSelectionProvider =
    NotifierProvider<BulkSelectionNotifier, BulkSelectionState>(
  BulkSelectionNotifier.new,
);
