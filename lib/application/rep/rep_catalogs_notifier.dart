// lib/application/rep/rep_catalogs_notifier.dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_failure.dart';
import '../../data/repositories/rep_repository.dart';
import '../../domain/entities/catalog_product.dart';
import '../../domain/entities/rep_activation.dart';
import '../common/pending_poll_loop.dart';
import 'rep_restaurant_notifier.dart';

/// The catalogs this rep may currently act on.
///
/// Re-read on screen open rather than cached: a delegation is revoked
/// server-side and takes effect on the next request, so a stale list would
/// offer a rep a restaurant they can no longer write to.
///
/// autoDispose is what makes that sentence true. Kept alive, this provider
/// builds ONCE per app run and every later open of 'My restaurants' re-renders
/// whatever that first read returned — an empty list from before the rep had a
/// restaurant, or a list from a previous sign-in, with no request made and no
/// spinner to hint that nothing was asked. Disposing it with the screen means
/// the next open runs [build] again, which is the API call.
class RepCatalogsNotifier
    extends AutoDisposeAsyncNotifier<List<RepCatalogSummary>> {
  /// Set once the provider is gone: [refresh] writes `state` after an awaited
  /// read, and with autoDispose the rep can leave the screen mid-flight —
  /// writing then throws, which would surface as an unhandled async error
  /// rather than as the nothing it should be.
  bool _disposed = false;

  @override
  Future<List<RepCatalogSummary>> build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    return ref.read(repRepositoryProvider).catalogs();
  }

  /// Re-reads now, for pull-to-refresh and the retry on the error state.
  Future<void> refresh() async {
    final next = await AsyncValue.guard(
      () => ref.read(repRepositoryProvider).catalogs(),
    );
    if (_disposed) return;
    state = next;
  }
}

final repCatalogsProvider = AsyncNotifierProvider.autoDispose<
    RepCatalogsNotifier, List<RepCatalogSummary>>(
  RepCatalogsNotifier.new,
);

/// One delegated catalog's dishes, watched while any 3D model is generating.
///
/// The rep adds a dish, captures it, and stays on this screen — so the flip
/// from "3D generating…" to "AR ready" has to happen underneath them without a
/// pull-to-refresh. Uses the SHARED cadence (see [PendingPollLoop]); a second
/// backoff for the same backend behaviour would drift from the first.
class RepCatalogProductsNotifier
    extends FamilyAsyncNotifier<List<CatalogProduct>, String> {
  PendingPollLoop? _poll;

  @override
  Future<List<CatalogProduct>> build(String catalogId) async {
    // The loop dies with the screen — without this it would poll on behalf of a
    // route nobody is looking at.
    ref.onDispose(() => _poll?.stop());
    final products = await ref.read(repRepositoryProvider).products(catalogId);
    _schedule(products);
    return products;
  }

  /// Whether a model is currently being watched. For the tests, and for a
  /// screen that wants to say so.
  bool get isPolling => _poll?.isRunning ?? false;

  void _schedule(List<CatalogProduct> products) {
    final pending = products.any((p) => p.isModelPending);
    if (!pending) {
      _poll?.stop();
      return;
    }
    (_poll ??= PendingPollLoop(poll: _tick)).scheduleIfPending(isPending: true);
  }

  /// One poll. Never throws and never blanks the list: a dropped request on
  /// restaurant wifi leaves the dishes on screen and the next tick tries again.
  ///
  /// A TICK THAT LANDS A MODEL ALSO MOVES THE PUBLISH BAR. When generation
  /// finishes, the backend promotes the dish and bumps the catalog's
  /// `draftRevision` — the row becomes 3D and the restaurant now has a draft
  /// change. The bar under this list reads [repCatalogDocumentProvider] for
  /// that flag, and every OTHER thing that invalidates it is a route return.
  /// A rep watching a model finish is navigating nowhere, so without the
  /// invalidate below the dish turns 3D while the bar goes on saying the menu
  /// is fully published.
  Future<bool> _tick() async {
    try {
      final before = {
        for (final product in state.valueOrNull ?? const <CatalogProduct>[])
          if (product.isModelPending) product.id,
      };
      final products = await ref.read(repRepositoryProvider).products(arg);
      state = AsyncData(products);

      // Only when something actually SETTLED — a tick where every pending dish
      // is still pending changed nothing server-side either, and invalidating
      // on each one would re-fetch the catalog document for the whole length of
      // a generation.
      if (products.any((p) => before.contains(p.id) && !p.isModelPending)) {
        ref.invalidate(repCatalogDocumentProvider(arg));
      }

      return products.any((p) => p.isModelPending);
    } catch (_) {
      final current = state.valueOrNull ?? const <CatalogProduct>[];
      return current.any((p) => p.isModelPending);
    }
  }

  /// Re-reads now and restarts the cadence — after adding a dish, so the new
  /// "3D generating…" row appears immediately rather than up to 10s later.
  Future<void> refresh() async {
    _poll?.reset();
    final next = await AsyncValue.guard(
      () => ref.read(repRepositoryProvider).products(arg),
    );
    state = next;
    _schedule(next.valueOrNull ?? const <CatalogProduct>[]);
  }

  /// Moves the dish at [oldIndex] to [newIndex], optimistically, then writes
  /// the new order on the restaurant's behalf.
  ///
  /// THE OWNER'S GRID HAS DONE THIS SINCE FEATURE 10; THE REP LIST COULD NOT.
  /// A rep building a menu at the table could file dishes into sections and
  /// not put one above another — the rows sat in creation order until the
  /// owner signed in and dragged. Same contract as
  /// `CatalogProductsNotifier.reorder`: [newIndex] follows the
  /// `ReorderableListView` convention (counted BEFORE the dragged row is
  /// lifted out), so the list hands its raw indices straight here. Returns the
  /// index the row LANDED on, or null when nothing moved — the caller needs
  /// that number for the undo, which drags the row back from where it is.
  ///
  /// The whole list is sent: the rep surface loads every dish (there is no
  /// paging on `/rep/catalogs/:id/products`), and the server renumbers the
  /// ids it is given 0..n-1. A failure means NOTHING moved — the server
  /// rejects a mismatched id set wholesale — so the rollback is unconditional,
  /// followed by a re-read because the likeliest cause is the owner having
  /// reordered on their own phone first.
  ///
  /// A REORDER IS A DRAFT CHANGE. The server bumps `draftRevision` for it as
  /// it does for an edit, so the publish bar's flag has moved; the document
  /// behind that bar is invalidated here because nothing else on the screen
  /// re-reads it after a drag.
  Future<int?> reorder(int oldIndex, int newIndex) async {
    final previous = state.valueOrNull;
    if (previous == null) return null;
    if (oldIndex < 0 || oldIndex >= previous.length) return null;

    var target = newIndex > oldIndex ? newIndex - 1 : newIndex;
    if (target < 0) target = 0;
    if (target >= previous.length) target = previous.length - 1;
    if (target == oldIndex) return null;

    final reordered = [...previous];
    reordered.insert(target, reordered.removeAt(oldIndex));
    // Positions are renumbered by the server to the array index; mirroring
    // that locally keeps a later in-place update from re-sorting the list.
    final optimistic = [
      for (var i = 0; i < reordered.length; i++)
        reordered[i].copyWith(position: i),
    ];
    state = AsyncData(optimistic);

    try {
      await ref
          .read(repRepositoryProvider)
          .reorderProducts(arg, [for (final item in optimistic) item.id]);
      ref.invalidate(repCatalogDocumentProvider(arg));
      return target;
    } on CatalogFailure {
      state = AsyncData(previous);
      unawaited(refresh());
      rethrow;
    }
  }
}

final repCatalogProductsProvider = AsyncNotifierProvider.family<
    RepCatalogProductsNotifier, List<CatalogProduct>, String>(
  RepCatalogProductsNotifier.new,
);
