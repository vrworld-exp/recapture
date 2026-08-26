// lib/application/catalog/catalog_notifier.dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_repository.dart';
import '../../domain/entities/auth_state.dart';
import '../../domain/entities/business_profile.dart';
import '../../domain/entities/catalog.dart';
import '../auth/auth_notifier.dart';
import 'bulk_selection_notifier.dart';
import 'catalog_categories_notifier.dart';
import 'catalog_products_notifier.dart';

/// Owns the caller's catalog — the single source of truth every catalog surface
/// reads from. State is an `AsyncValue<Catalog?>`:
///   - `AsyncLoading` → first load / explicit reload
///   - `AsyncData(null)` → **the user has no catalog yet** (the first-run state,
///     not an error). The repository translates the server's
///     404 CATALOG_NOT_FOUND into this.
///   - `AsyncData(catalog)` → loaded
///   - `AsyncError` → the load genuinely failed
///
/// Invariants:
///   - The notifier never touches HTTP — everything goes through
///     [CatalogRepository].
///   - Catalog state is SERVER-TRUTH and is not cached to disk. Draft/published
///     revisions, sync status and an in-flight publish can all move from another
///     device (edge case 5), and a stale local copy of "you have unpublished
///     changes" is exactly the kind of wrong the publish flow cannot tolerate.
///     The projects list caches because a stale project row is harmless; this is
///     not that.
///   - State resets on sign-out, so the next user never sees another's catalog.
class CatalogNotifier extends AsyncNotifier<Catalog?> {
  CatalogRepository get _repo => ref.read(catalogRepositoryProvider);

  @override
  Future<Catalog?> build() async {
    ref.listen<AuthState>(authProvider, (_, next) {
      if (next is AuthUnauthenticated) {
        state = const AsyncData<Catalog?>(null);
      }
    });

    return _repo.fetch();
  }

  /// Re-fetches without emitting `AsyncLoading`, so the current catalog stays on
  /// screen instead of flashing a skeleton. Used on screen focus and
  /// pull-to-refresh.
  Future<void> refresh() async {
    try {
      state = AsyncData(await _repo.fetch());
    } catch (error, stack) {
      // Only surface the error if there is nothing to keep showing — a failed
      // background refresh must not blank a catalog the user is looking at.
      if (state.valueOrNull == null) state = AsyncError(error, stack);
    }
  }

  /// Creates the catalog (feature 1). Idempotent server-side, so a retry after a
  /// lost response returns the existing catalog rather than failing.
  ///
  /// Throws [CatalogFailure] on failure — the caller shows the message; state is
  /// left untouched so a failed create does not blank the screen.
  Future<Catalog> create({required String name, String? businessName}) async {
    final created = await _repo.create(name: name, businessName: businessName);
    state = AsyncData(created);
    return created;
  }

  /// Updates catalog metadata (feature 2).
  ///
  /// Named `updateMetadata`, not `update`: `AsyncNotifier` already defines an
  /// `update(cb)` for transforming current state, and shadowing it would be an
  /// invalid override.
  ///
  /// Not optimistic on purpose: the response carries the server-recomputed
  /// `hasUnpublishedChanges`, and guessing that flag locally is how the badge
  /// ends up claiming edits are live when they are not.
  Future<Catalog> updateMetadata({
    String? name,
    String? businessName,
    BusinessContact? contact,
  }) async {
    final updated = await _repo.update(
      name: name,
      businessName: businessName,
      contact: contact,
    );
    state = AsyncData(updated);
    return updated;
  }

  /// Deletes the catalog and everything in it, returning the user to the
  /// first-run state so they can create a new one.
  ///
  /// State goes to `AsyncData(null)` — the SAME value as "never had one" — which
  /// is what makes the catalog shell rebuild into its create prompt with no
  /// special case for "just deleted".
  ///
  /// The sibling notifiers are INVALIDATED rather than left alone: they hold
  /// products and categories of a catalog that no longer exists, and a stale
  /// grid behind the create prompt is how a user ends up believing the delete
  /// only half worked. Bulk selection is cleared for the same reason — a
  /// selection of deleted ids would arm actions against rows that are gone.
  ///
  /// Throws [CatalogFailure] on failure, with state LEFT ALONE: the backend
  /// aborts its delete before touching anything when the public page cannot be
  /// taken down, so the catalog on screen is still the truth.
  Future<CatalogDeletionSummary> delete() async {
    final summary = await _repo.delete();

    state = const AsyncData<Catalog?>(null);

    ref.read(bulkSelectionProvider.notifier).exit();
    ref.invalidate(catalogProductsProvider);
    ref.invalidate(catalogCategoriesProvider);

    return summary;
  }
}

/// The app-wide catalog.
final catalogProvider =
    AsyncNotifierProvider<CatalogNotifier, Catalog?>(CatalogNotifier.new);

/// True once the user has a catalog. `false` while loading — the catalog shell
/// branches on the AsyncValue itself, this is for callers that only need the
/// yes/no (an entry-point badge, a menu item's enabled state).
final hasCatalogProvider = Provider<bool>(
  (ref) => ref.watch(catalogProvider).valueOrNull != null,
);
