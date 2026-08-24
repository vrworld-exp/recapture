// lib/application/catalog/catalog_categories_notifier.dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_failure.dart';
import '../../data/repositories/catalog_repository.dart';
import '../../domain/entities/auth_state.dart';
import '../../domain/entities/catalog_category.dart';
import '../auth/auth_notifier.dart';

/// Owns the catalog's categories — the ONE list every surface that names a
/// category reads from: the grid's category filter chips, the product editor's
/// picker, and the category manager itself.
///
/// One notifier rather than a fetch per screen because the count on each row is
/// a live number: moving a product changes it, and two independently-fetched
/// copies would disagree about how many products a delete is about to move.
///
/// [CatalogCategoryList] carries the uncategorized bucket's size alongside the
/// real categories, because the UI always renders the bucket next to them —
/// it is a null `categoryId`, never a row the server returns.
///
/// Invariants match [CatalogNotifier]: no HTTP here, server-truth only (a
/// category's sync status can move from another device), and state resets on
/// sign-out so the next user never sees another's categories.
class CatalogCategoriesNotifier extends AsyncNotifier<CatalogCategoryList> {
  CatalogRepository get _repo => ref.read(catalogRepositoryProvider);

  @override
  Future<CatalogCategoryList> build() async {
    ref.listen<AuthState>(authProvider, (_, next) {
      if (next is AuthUnauthenticated) {
        state = const AsyncData(CatalogCategoryList.empty);
      }
    });

    return _repo.listCategories();
  }

  /// Re-fetches without emitting `AsyncLoading`, so filter chips do not vanish
  /// and reappear while the list refreshes underneath them.
  Future<void> refresh() async {
    try {
      state = AsyncData(await _repo.listCategories());
    } catch (error, stack) {
      // A failed background refresh must not blank a list the user is reading.
      if (state.valueOrNull == null) state = AsyncError(error, stack);
    }
  }

  // ── Mutations (features 22-25) ────────────────────────────────────────────
  //
  // None of these is optimistic EXCEPT [reorder], and the split is deliberate.
  // Create, rename and delete each return the server's own row, and adopting it
  // costs nothing the user can feel. A drag, on the other hand, has to land
  // under the finger immediately or it reads as a failed gesture — so that one
  // moves first and rolls back visibly if the server disagrees.

  /// Creates a category (feature 22). Appended at the end, which is where the
  /// server puts it too.
  ///
  /// Throws [CatalogFailure] — a duplicate name is the server's verdict
  /// (`DUPLICATE_NAME`) and the caller shows it beside the field.
  Future<CatalogCategory> create(String name) async {
    final created = await _repo.createCategory(name);
    final current = _list;
    state = AsyncData(CatalogCategoryList(
      categories: [...current.categories, created],
      uncategorizedCount: current.uncategorizedCount,
    ));
    return created;
  }

  /// Renames a category (feature 23).
  ///
  /// Allowed on a category that is already live on Mirage: the rename is a draft
  /// edit like any other and goes live at the next publish. Nothing here says
  /// otherwise.
  Future<CatalogCategory> rename(String id, String name) async {
    final updated = await _repo.renameCategory(id, name);
    state = AsyncData(CatalogCategoryList(
      categories: [
        for (final category in _list.categories)
          if (category.id == id) updated else category,
      ],
      uncategorizedCount: _list.uncategorizedCount,
    ));
    return updated;
  }

  /// Deletes a category (feature 24) and returns how many products the SERVER
  /// moved out of it.
  ///
  /// That number is the one to report, and it is not always the one the
  /// confirmation showed: `productCount` counts only live products, while the
  /// delete moves archived ones too. The row goes immediately (the user asked
  /// for it) and the counts are re-read, because the uncategorized bucket's size
  /// is a server aggregate this notifier must not try to recompute.
  Future<int> delete(String id) async {
    final moved = await _repo.deleteCategory(id);
    state = AsyncData(CatalogCategoryList(
      categories: [
        for (final category in _list.categories)
          if (category.id != id) category,
      ],
      uncategorizedCount: _list.uncategorizedCount,
    ));
    unawaited(refresh());
    return moved;
  }

  /// Moves the category at [oldIndex] to [newIndex] (feature 25),
  /// optimistically.
  ///
  /// [newIndex] follows the `ReorderableListView` convention — counted BEFORE
  /// the dragged row is removed — so the list, the drag handle and the keyboard
  /// shortcut all hand their raw indices straight here.
  ///
  /// The server takes the FULL ordered id list and rejects anything else with
  /// `ID_SET_MISMATCH`, so a failure means nothing moved: the rollback is
  /// unconditional, and it is followed by a re-read because the most likely
  /// cause of a mismatch is another device having reordered first. Last write
  /// wins, but only after this one has seen what it is writing over.
  ///
  /// Returns the index the row LANDED on, or null when nothing moved (an
  /// out-of-range drag, or one that ended where it started). The caller needs
  /// that number for the inverse: an undo has to drag the row back from where
  /// it actually is, and this method — not the gesture — owns the conversion
  /// from the `ReorderableListView` convention to a real index.
  Future<int?> reorder(int oldIndex, int newIndex) async {
    final previous = _list;
    final categories = previous.categories;
    if (oldIndex < 0 || oldIndex >= categories.length) return null;

    var target = newIndex > oldIndex ? newIndex - 1 : newIndex;
    if (target < 0) target = 0;
    if (target >= categories.length) target = categories.length - 1;
    if (target == oldIndex) return null;

    final reordered = [...categories];
    reordered.insert(target, reordered.removeAt(oldIndex));
    // Positions are renumbered to the array index server-side; mirroring that
    // locally stops a later in-place update re-sorting the list.
    final optimistic = [
      for (var i = 0; i < reordered.length; i++)
        reordered[i].copyWith(position: i),
    ];
    state = AsyncData(CatalogCategoryList(
      categories: optimistic,
      uncategorizedCount: previous.uncategorizedCount,
    ));

    try {
      await _repo.reorderCategories([for (final c in optimistic) c.id]);
      return target;
    } on CatalogFailure {
      state = AsyncData(previous);
      unawaited(refresh());
      rethrow;
    }
  }

  /// The current list, or an empty one while the first load is in flight.
  CatalogCategoryList get _list =>
      state.valueOrNull ?? CatalogCategoryList.empty;
}

/// The app-wide category list.
final catalogCategoriesProvider =
    AsyncNotifierProvider<CatalogCategoriesNotifier, CatalogCategoryList>(
  CatalogCategoriesNotifier.new,
);

/// Category name by id, for surfaces that show one product's category without
/// caring about the rest of the list. Null id (Uncategorized) and an id the
/// list does not carry both resolve to null — the caller decides what to render,
/// because "no category" and "a category this build has not fetched yet" read
/// differently in a filter chip than they do on a card.
final categoryNameProvider = Provider.family<String?, String?>((ref, id) {
  if (id == null) return null;
  final list = ref.watch(catalogCategoriesProvider).valueOrNull;
  if (list == null) return null;
  for (final category in list.categories) {
    if (category.id == id) return category.name;
  }
  return null;
});
