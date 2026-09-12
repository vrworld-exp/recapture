// lib/application/rep/rep_category_products_notifier.dart
//
// The detail half of the REP's category manager: the dishes inside one section
// of a delegated restaurant, and the picker of dishes that could be added to
// it. The owner's manager reads [categoryProductsProvider] and
// [categoryCandidatesProvider], both of which resolve "my catalog" from the
// token and page through `/catalog/products?categoryId=`. A rep has no catalog
// of their own and the delegated list route has no filter and no cursor — it
// answers the WHOLE menu in one read (up to `REP_PRODUCT_PAGE_SIZE`) — so both
// lists here are the one read, narrowed locally.
//
// SAME STATE TYPES AS THE OWNER, deliberately. [CategoryProductsState] and
// [CategoryCandidatesState] carry nothing owner-specific, and reusing them is
// what lets the rep manager screen be a copy of the owner's rather than a
// re-derivation of it.
import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_failure.dart';
import '../../data/repositories/catalog_products_repository.dart'
    show BulkProductAction, kBulkProductIdLimit;
import '../../data/repositories/rep_repository.dart';
import '../../domain/entities/catalog_product.dart';
import '../catalog/category_candidates_notifier.dart'
    show CategoryCandidatesState;
import '../catalog/category_products_notifier.dart'
    show CategoryProductsState, kCategoryDrainMaxPasses;
import 'rep_catalogs_notifier.dart';
import 'rep_restaurant_notifier.dart';

/// How many dishes `GET /rep/catalogs/:id/products` answers at most.
///
/// Mirrors the backend's `REP_PRODUCT_PAGE_SIZE`. There is no cursor past it,
/// so a menu at exactly this size MAY have more behind it — the pane says so
/// rather than quietly showing a subset, for the reason the owner's
/// `kCategoryProductsMax` exists: a "Move all" over a silently partial list is
/// the bug that flag prevents.
const int kRepProductPageSize = 100;

/// One section of one delegated restaurant.
///
/// A class rather than a bare record so the two providers below share a key
/// type with a name, and so [categoryId]'s null — the Uncategorized bucket, a
/// real place and not "no filter" — is spelled out where it is read.
@immutable
class RepCategoryKey {
  const RepCategoryKey({required this.catalogId, required this.categoryId});

  final String catalogId;

  /// A category id, or null for the Uncategorized bucket.
  final String? categoryId;

  @override
  bool operator ==(Object other) =>
      other is RepCategoryKey &&
      other.catalogId == catalogId &&
      other.categoryId == categoryId;

  @override
  int get hashCode => Object.hash(catalogId, categoryId);
}

/// The dishes inside ONE section of a delegated restaurant, plus what the rep
/// has selected of them — the rep manager's detail pane.
///
/// Mirrors [CategoryProductsNotifier] method for method, so the screen built
/// over it is the owner's screen with the providers swapped. What differs is
/// only where the rows come from: one unfiltered read of the delegated menu,
/// narrowed here.
class RepCategoryProductsNotifier
    extends AutoDisposeFamilyNotifier<CategoryProductsState, RepCategoryKey> {
  RepRepository get _repo => ref.read(repRepositoryProvider);

  bool _disposed = false;

  @override
  CategoryProductsState build(RepCategoryKey arg) {
    ref.onDispose(() => _disposed = true);
    Future.microtask(load);
    return const CategoryProductsState();
  }

  /// Reads the menu and keeps the rows filed in this section.
  Future<void> load() async {
    state = state.copyWith(isLoading: true, error: null);

    final List<CatalogProduct> all;
    try {
      all = await _repo.products(arg.catalogId);
    } on CatalogFailure catch (failure) {
      if (_disposed) return;
      state = state.copyWith(isLoading: false, error: failure);
      return;
    }
    if (_disposed) return;

    final collected = [
      for (final product in all)
        if (product.categoryId == arg.categoryId) product,
    ];

    state = state.copyWith(
      items: collected,
      isLoading: false,
      truncated: all.length >= kRepProductPageSize,
      // Anything selected that is no longer here is dropped rather than carried
      // as a phantom the move would fail on.
      selectedIds: {
        for (final id in state.selectedIds)
          if (collected.any((p) => p.id == id)) id,
      },
    );
  }

  void toggle(String id) {
    final next = {...state.selectedIds};
    if (!next.remove(id)) next.add(id);
    state = state.copyWith(selectedIds: next);
  }

  void selectAll() =>
      state = state.copyWith(selectedIds: {for (final p in state.items) p.id});

  void clearSelection() =>
      state = state.copyWith(selectedIds: const <String>{});

  /// Moves the selected dishes into [categoryId] (null = Uncategorized) and
  /// returns how many moved.
  ///
  /// Chunked to the server's per-call bound, and the whole thing is re-read
  /// afterwards rather than patched locally: a move changes the counts on TWO
  /// sections plus the uncategorized bucket, none of which this notifier owns.
  ///
  /// Throws [CatalogFailure] — a partial run is possible across chunks, so the
  /// re-read happens on the failure path too and what survived stays visible.
  Future<int> moveSelectedTo(String? categoryId) async {
    final ids = state.selectedIds.toList();
    if (ids.isEmpty || categoryId == arg.categoryId) return 0;

    state = state.copyWith(isMoving: true);
    var moved = 0;
    try {
      moved = await _setCategory(ids, categoryId);
    } finally {
      if (!_disposed) {
        state = state.copyWith(isMoving: false, selectedIds: const <String>{});
        await load();
        _refreshSurroundings();
      }
    }
    return moved;
  }

  /// Adds dishes that live SOMEWHERE ELSE to this section, returning how many
  /// the server moved.
  ///
  /// The inbound half of [moveSelectedTo] and the same write — a dish has
  /// exactly one section, so "add to this one" is "set the section to this
  /// one". The ids come from the picker ([repCategoryCandidatesProvider]),
  /// which is why they are a parameter rather than this notifier's own
  /// selection. The count is the SERVER's, not `ids.length`: a dish can be
  /// deleted or moved by the owner's phone between the picker loading and the
  /// rep pressing Add.
  Future<int> addProducts(List<String> ids) async {
    if (ids.isEmpty) return 0;

    state = state.copyWith(isMoving: true);
    var added = 0;
    try {
      added = await _setCategory(ids, arg.categoryId);
    } finally {
      if (!_disposed) {
        // The selection is this section's OWN rows; the ids just added were
        // never part of it, so it is left alone rather than cleared.
        state = state.copyWith(isMoving: false);
        await load();
        _refreshSurroundings();
      }
    }
    return added;
  }

  /// Moves EVERY dish out of this section and into [categoryId]
  /// (null = Uncategorized), returning how many moved.
  ///
  /// Deliberately NOT `selectAll` + [moveSelectedTo], for the owner's reason:
  /// that pair can only move what the pane LOADED, and the delegated list stops
  /// at [kRepProductPageSize]. Draining by selection on a section bigger than
  /// that would move the first slice to the chosen destination and leave the
  /// rest for the delete endpoint to sweep into Uncategorized — the opposite of
  /// what the rep picked, reported as a success. So this re-reads and moves
  /// until the section reads back empty, capped so a server that keeps
  /// returning rows the bulk call reports as moved cannot spin it forever.
  ///
  /// Throws [CatalogFailure]. A partial drain is possible — the passes that
  /// landed stay landed — so the re-read happens on the failure path too.
  Future<int> moveAllTo(String? categoryId) async {
    if (categoryId == arg.categoryId) return 0;

    // Captured BEFORE the loop. This drain outlives the pane on a narrow
    // layout — it runs from the row menu, where nothing is watching this
    // provider — and `ref.read` on a disposed notifier throws.
    final repo = _repo;
    final catalogId = arg.catalogId;
    final from = arg.categoryId;

    state = state.copyWith(isMoving: true);
    var moved = 0;
    try {
      for (var pass = 0; pass < kCategoryDrainMaxPasses; pass++) {
        final all = await repo.products(catalogId);
        final here = [
          for (final product in all)
            if (product.categoryId == from) product.id,
        ];
        if (here.isEmpty) break;

        final justMoved = await _setCategory(here, categoryId, repo: repo);
        // A non-empty page that moved nothing is a drain making no progress.
        // Stop, rather than re-read the same page until the cap.
        if (justMoved == 0) break;
        moved += justMoved;
        // The list was the whole menu, so one pass that moved all of it is the
        // whole drain; only a menu at the page bound can have more behind it.
        if (all.length < kRepProductPageSize) break;
      }
    } finally {
      if (!_disposed) {
        state = state.copyWith(isMoving: false, selectedIds: const <String>{});
        await load();
        _refreshSurroundings();
      }
    }
    return moved;
  }

  /// One SET_CATEGORY over [ids], chunked to [kBulkProductIdLimit].
  ///
  /// [repo] is passed by the drain, which must not touch `ref` after the pane
  /// it runs from has gone.
  Future<int> _setCategory(
    List<String> ids,
    String? categoryId, {
    RepRepository? repo,
  }) async {
    final target = repo ?? _repo;
    var affected = 0;
    for (var start = 0; start < ids.length; start += kBulkProductIdLimit) {
      final chunk = ids.sublist(
        start,
        (start + kBulkProductIdLimit).clamp(0, ids.length),
      );
      affected += await target.bulkProducts(
        arg.catalogId,
        action: BulkProductAction.setCategory,
        ids: chunk,
        categoryId: categoryId,
      );
    }
    return affected;
  }

  /// Both section counts, the dish list and the publish bar's draft flag move
  /// when dishes do, and all are server-derived. Best-effort — the move already
  /// succeeded.
  void _refreshSurroundings() {
    final catalogId = arg.catalogId;
    ref.read(repCategoriesProvider(catalogId).notifier).refresh();
    ref.read(repCatalogProductsProvider(catalogId).notifier).refresh();
    ref.invalidate(repCatalogDocumentProvider(catalogId));
  }
}

/// One section's dishes on one delegated restaurant. A null `categoryId` in
/// the key is the Uncategorized bucket.
final repCategoryProductsProvider = NotifierProvider.autoDispose
    .family<RepCategoryProductsNotifier, CategoryProductsState, RepCategoryKey>(
  RepCategoryProductsNotifier.new,
);

/// The dishes that could be ADDED to one section — everything on the menu that
/// is not already in it — plus what the rep has ticked.
///
/// The key's `categoryId` is never null here: the Uncategorized bucket is the
/// ABSENCE of a section, so "add dishes to it" is a removal, and it already has
/// a name and a place — Move to… → Uncategorized, from the section the dishes
/// are actually in.
///
/// Reads only. The write is [RepCategoryProductsNotifier.addProducts], on the
/// notifier that owns the destination list.
class RepCategoryCandidatesNotifier
    extends AutoDisposeFamilyNotifier<CategoryCandidatesState, RepCategoryKey> {
  RepRepository get _repo => ref.read(repRepositoryProvider);

  bool _disposed = false;

  @override
  CategoryCandidatesState build(RepCategoryKey arg) {
    ref.onDispose(() => _disposed = true);
    Future.microtask(load);
    return const CategoryCandidatesState();
  }

  /// Reads the menu and keeps what is NOT already in the destination.
  Future<void> load() async {
    state = state.copyWith(isLoading: true, error: null);

    final List<CatalogProduct> all;
    try {
      all = await _repo.products(arg.catalogId);
    } on CatalogFailure catch (failure) {
      if (_disposed) return;
      state = state.copyWith(isLoading: false, error: failure);
      return;
    }
    if (_disposed) return;

    final collected = [
      for (final product in all)
        if (product.categoryId != arg.categoryId) product,
    ];

    state = state.copyWith(
      items: collected,
      scanned: all.length,
      isLoading: false,
      truncated: all.length >= kRepProductPageSize,
      // A dish that moved into this section from somewhere else while the
      // picker was open is no longer addable, and carrying it as a phantom
      // would put it in the count on the button.
      selectedIds: {
        for (final id in state.selectedIds)
          if (collected.any((product) => product.id == id)) id,
      },
    );
  }

  void setQuery(String query) => state = state.copyWith(query: query);

  void toggle(String id) {
    final next = {...state.selectedIds};
    if (!next.remove(id)) next.add(id);
    state = state.copyWith(selectedIds: next);
  }

  /// Selects everything the filter is currently showing — and leaves anything
  /// already ticked but filtered OUT alone.
  void selectAllVisible() => state = state.copyWith(
        selectedIds: {
          ...state.selectedIds,
          for (final product in state.visible) product.id,
        },
      );

  void clearSelection() =>
      state = state.copyWith(selectedIds: const <String>{});
}

/// The add-dishes picker's list, for one destination section.
final repCategoryCandidatesProvider = NotifierProvider.autoDispose.family<
    RepCategoryCandidatesNotifier, CategoryCandidatesState, RepCategoryKey>(
  RepCategoryCandidatesNotifier.new,
);
