// lib/application/catalog/catalog_categories_notifier.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
