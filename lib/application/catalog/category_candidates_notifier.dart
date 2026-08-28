// lib/application/catalog/category_candidates_notifier.dart
import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_failure.dart';
import '../../data/repositories/catalog_products_repository.dart';
import '../../domain/entities/catalog_product.dart';

/// Products asked for per page while filling the add-products picker.
const int kCategoryCandidatesPageSize = 100;

/// The most products the picker will scan before it stops and says so.
///
/// Counted in products SCANNED, not products offered: the filtering happens on
/// this side, so a catalog whose first pages are all already in this category
/// still costs its round trips. The number matches [kCategoryProductsMax] for
/// the same reason that one exists — past it, a checkbox list is the wrong
/// tool, and saying so beats a silently partial one.
const int kCategoryCandidatesMax = 1000;

/// The products that could be ADDED to one category — everything in the catalog
/// that is not already in it — plus what the user has ticked.
///
/// The other half of feature 26. [CategoryProductsNotifier] answers "what is in
/// this category, and where else could it go"; this answers "what is NOT in it
/// yet", which is the question a category the user has just created asks. They
/// stay separate because they are separate lists with separate lifetimes: this
/// one exists only while the picker is open, and it is disposed with it.
///
/// Family argument: the destination category's id. Never null — the
/// Uncategorized bucket is the ABSENCE of a category, so "add products to it"
/// is a removal, and it already has a name and a place: Move to… →
/// Uncategorized, from the category the products are actually in.
@immutable
class CategoryCandidatesState {
  const CategoryCandidatesState({
    this.items = const <CatalogProduct>[],
    this.selectedIds = const <String>{},
    this.query = '',
    this.isLoading = true,
    this.truncated = false,
    this.scanned = 0,
    this.error,
  });

  /// Everything scanned that is not already in the destination category, in the
  /// catalog's own order. Archived products included — an archived product is
  /// still a product that needs a category before it can be restored and
  /// published, and the row says which ones they are.
  final List<CatalogProduct> items;

  /// Ids, not indices: [visible] changes as the user types, and a selection
  /// counted by position would point at a different product each keystroke.
  final Set<String> selectedIds;

  /// The name filter, applied to [items] here rather than re-fetched. The whole
  /// set is already loaded, so a round trip per keystroke would buy nothing.
  final String query;

  final bool isLoading;

  /// The scan stopped at [kCategoryCandidatesMax] with more catalog behind it.
  final bool truncated;

  /// How many products the scan looked at, before removing the ones already in
  /// the category. It is what tells "you have no products yet" apart from
  /// "every product is already in here" — two empty pickers that need two
  /// different sentences.
  final int scanned;

  final CatalogFailure? error;

  /// [items] narrowed by [query] — case-insensitive, substring, on the name.
  List<CatalogProduct> get visible {
    if (query.isEmpty) return items;
    final needle = query.toLowerCase();
    return [
      for (final product in items)
        if (product.name.toLowerCase().contains(needle)) product,
    ];
  }

  bool get isSearching => query.isNotEmpty;

  /// The catalog has no products at all — the user has nothing to add yet.
  bool get catalogIsEmpty => !isLoading && error == null && scanned == 0;

  /// There are products, and every one of them is already in this category.
  bool get allAlreadyHere =>
      !isLoading && error == null && scanned > 0 && items.isEmpty;

  bool get hasSelection => selectedIds.isNotEmpty;
  bool isSelected(String id) => selectedIds.contains(id);

  CategoryCandidatesState copyWith({
    List<CatalogProduct>? items,
    Set<String>? selectedIds,
    String? query,
    bool? isLoading,
    bool? truncated,
    int? scanned,
    Object? error = _unset,
  }) =>
      CategoryCandidatesState(
        items: items ?? this.items,
        selectedIds: selectedIds ?? this.selectedIds,
        query: query ?? this.query,
        isLoading: isLoading ?? this.isLoading,
        truncated: truncated ?? this.truncated,
        scanned: scanned ?? this.scanned,
        error: identical(error, _unset) ? this.error : error as CatalogFailure?,
      );

  static const Object _unset = Object();
}

/// Loads and filters the add-products picker's list.
///
/// Reads only. The write is [CategoryProductsNotifier.addProducts], on the
/// notifier that owns the destination list — one place that re-reads the
/// counts a move changes, whether the products arrived from this picker or
/// left through "Move to…".
class CategoryCandidatesNotifier
    extends AutoDisposeFamilyNotifier<CategoryCandidatesState, String> {
  CatalogProductsRepository get _repo =>
      ref.read(catalogProductsRepositoryProvider);

  bool _disposed = false;

  @override
  CategoryCandidatesState build(String arg) {
    ref.onDispose(() => _disposed = true);
    Future.microtask(load);
    return const CategoryCandidatesState();
  }

  /// Scans the catalog, page by page, keeping what is not already in [arg].
  ///
  /// No `categoryId` filter goes on the wire: the server can select ONE
  /// category, and this needs every OTHER one. The exclusion is therefore local,
  /// and [CategoryCandidatesState.scanned] records what it cost.
  Future<void> load() async {
    state = state.copyWith(isLoading: true, error: null);

    final collected = <CatalogProduct>[];
    var scanned = 0;
    String? cursor;
    var truncated = false;

    try {
      while (true) {
        final page = await _repo.list(
          limit: kCategoryCandidatesPageSize,
          cursor: cursor,
          includeArchived: true,
        );
        if (_disposed) return;
        scanned += page.items.length;
        for (final product in page.items) {
          if (product.categoryId != arg) collected.add(product);
        }
        cursor = page.nextCursor;
        if (cursor == null) break;
        if (scanned >= kCategoryCandidatesMax) {
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
      scanned: scanned,
      isLoading: false,
      truncated: truncated,
      // A product that moved into this category from somewhere else while the
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
  /// already ticked but filtered OUT alone. "Select all" while searching means
  /// all of these, not all of them and forget the rest.
  void selectAllVisible() => state = state.copyWith(
        selectedIds: {
          ...state.selectedIds,
          for (final product in state.visible) product.id,
        },
      );

  void clearSelection() => state = state.copyWith(selectedIds: const <String>{});
}

/// The add-products picker's list, for one destination category.
final categoryCandidatesProvider = NotifierProvider.autoDispose
    .family<CategoryCandidatesNotifier, CategoryCandidatesState, String>(
  CategoryCandidatesNotifier.new,
);
