// lib/application/catalog/category_products_notifier.dart
import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_failure.dart';
import '../../data/repositories/catalog_products_repository.dart';
import '../../domain/entities/catalog_product.dart';
import 'catalog_categories_notifier.dart';
import 'catalog_notifier.dart';
import 'catalog_products_notifier.dart';

/// Products asked for per page while filling one category's list.
///
/// The server's hard bound is 100. This list is not the browsing grid — it is a
/// working set the user selects from and moves — so it fetches whole rather than
/// scrolling, and fetching whole in as few round trips as possible matters more
/// than a fast first paint.
const int kCategoryProductsPageSize = 100;

/// The most products one category's pane will load.
///
/// A ceiling rather than a promise: a catalog with more products in one category
/// than this is not a shape the manager is designed for, and paging forever is a
/// worse answer than saying so. The pane reports the truncation rather than
/// quietly showing a subset — a "Move all" over a silently-partial list is the
/// bug this exists to prevent.
const int kCategoryProductsMax = 1000;

/// One category's products, plus what the user has selected of them.
@immutable
class CategoryProductsState {
  const CategoryProductsState({
    this.items = const <CatalogProduct>[],
    this.selectedIds = const <String>{},
    this.isLoading = true,
    this.isMoving = false,
    this.truncated = false,
    this.error,
  });

  final List<CatalogProduct> items;

  /// Ids, not indices: a move re-reads the list underneath, and an index-based
  /// selection would then be pointing at whatever moved into that slot.
  final Set<String> selectedIds;

  final bool isLoading;

  /// A bulk move is in flight — the list is frozen rather than half-applied.
  final bool isMoving;

  /// The category holds more than [kCategoryProductsMax] products.
  final bool truncated;

  final CatalogFailure? error;

  bool get isEmpty => items.isEmpty && !isLoading && error == null;
  bool get hasSelection => selectedIds.isNotEmpty;
  bool isSelected(String id) => selectedIds.contains(id);

  CategoryProductsState copyWith({
    List<CatalogProduct>? items,
    Set<String>? selectedIds,
    bool? isLoading,
    bool? isMoving,
    bool? truncated,
    Object? error = _unset,
  }) =>
      CategoryProductsState(
        items: items ?? this.items,
        selectedIds: selectedIds ?? this.selectedIds,
        isLoading: isLoading ?? this.isLoading,
        isMoving: isMoving ?? this.isMoving,
        truncated: truncated ?? this.truncated,
        error: identical(error, _unset) ? this.error : error as CatalogFailure?,
      );

  static const Object _unset = Object();
}

/// The products inside ONE category — the category manager's detail pane
/// (feature 26's other half: moving products between categories).
///
/// Family argument: a real category id, or **null for the Uncategorized
/// bucket**. Null is not "no filter" here; the repository's `'none'` sentinel is
/// what goes on the wire, and translating it is this notifier's job so no screen
/// has to know the string.
///
/// Separate from [catalogProductsProvider] on purpose. That one is the browsing
/// grid: paginated, filtered by whatever chips the user has set, and shared by
/// the whole shell. Pointing it at a category to render this pane would move the
/// grid the user comes back to.
class CategoryProductsNotifier
    extends AutoDisposeFamilyNotifier<CategoryProductsState, String?> {
  CatalogProductsRepository get _repo =>
      ref.read(catalogProductsRepositoryProvider);

  bool _disposed = false;

  @override
  CategoryProductsState build(String? arg) {
    ref.onDispose(() => _disposed = true);
    Future.microtask(load);
    return const CategoryProductsState();
  }

  /// Reads the whole category, page by page.
  ///
  /// Archived products included: they are still IN the category, and a move that
  /// silently left them behind would leave rows pointing at a category the user
  /// believes they emptied.
  Future<void> load() async {
    state = state.copyWith(isLoading: true, error: null);

    final collected = <CatalogProduct>[];
    String? cursor;
    var truncated = false;

    try {
      while (true) {
        final page = await _repo.list(
          limit: kCategoryProductsPageSize,
          cursor: cursor,
          categoryId: arg ?? kUncategorizedFilterId,
          includeArchived: true,
        );
        if (_disposed) return;
        collected.addAll(page.items);
        cursor = page.nextCursor;
        if (cursor == null) break;
        if (collected.length >= kCategoryProductsMax) {
          truncated = true;
          break;
        }
      }
    } on CatalogFailure catch (failure) {
      if (_disposed) return;
      state = state.copyWith(isLoading: false, error: failure);
      return;
    }

    state = state.copyWith(
      items: collected,
      isLoading: false,
      truncated: truncated,
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

  /// Moves the selected products into [categoryId] (null = Uncategorized).
  ///
  /// Returns how many moved. Chunked to the server's per-call bound, and the
  /// whole thing is re-read afterwards rather than patched locally: a move
  /// changes the counts on TWO categories plus the uncategorized bucket, none of
  /// which this notifier owns.
  ///
  /// Throws [CatalogFailure] — a partial run is possible across chunks, so the
  /// re-read happens on the failure path too and what survived stays visible.
  Future<int> moveSelectedTo(String? categoryId) async {
    final ids = state.selectedIds.toList();
    if (ids.isEmpty || categoryId == arg) return 0;

    state = state.copyWith(isMoving: true);
    var moved = 0;
    try {
      for (var start = 0; start < ids.length; start += kBulkProductIdLimit) {
        final chunk = ids.sublist(
          start,
          (start + kBulkProductIdLimit).clamp(0, ids.length),
        );
        moved += await _repo.bulk(
          action: BulkProductAction.setCategory,
          ids: chunk,
          categoryId: categoryId,
        );
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

  /// Both category counts and the catalog header move when products do, and
  /// both are server aggregates. Best-effort — the move already succeeded.
  void _refreshSurroundings() {
    ref.read(catalogCategoriesProvider.notifier).refresh();
    ref.read(catalogProductsProvider.notifier).refresh();
    ref.read(catalogProvider.notifier).refresh().catchError((_) {});
  }
}

/// One category's products. Pass null for the Uncategorized bucket.
final categoryProductsProvider = NotifierProvider.autoDispose
    .family<CategoryProductsNotifier, CategoryProductsState, String?>(
  CategoryProductsNotifier.new,
);
