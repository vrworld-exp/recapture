// lib/application/rep/rep_catalogs_notifier.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/rep_repository.dart';
import '../../domain/entities/catalog_product.dart';
import '../../domain/entities/rep_activation.dart';
import '../common/pending_poll_loop.dart';

/// The catalogs this rep may currently act on.
///
/// Re-read on screen open rather than cached: a delegation is revoked
/// server-side and takes effect on the next request, so a stale list would
/// offer a rep a restaurant they can no longer write to.
class RepCatalogsNotifier extends AsyncNotifier<List<RepCatalogSummary>> {
  @override
  Future<List<RepCatalogSummary>> build() =>
      ref.read(repRepositoryProvider).catalogs();

  Future<void> refresh() async {
    state = await AsyncValue.guard(
      () => ref.read(repRepositoryProvider).catalogs(),
    );
  }
}

final repCatalogsProvider =
    AsyncNotifierProvider<RepCatalogsNotifier, List<RepCatalogSummary>>(
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
  Future<bool> _tick() async {
    try {
      final products = await ref.read(repRepositoryProvider).products(arg);
      state = AsyncData(products);
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
}

final repCatalogProductsProvider = AsyncNotifierProvider.family<
    RepCatalogProductsNotifier, List<CatalogProduct>, String>(
  RepCatalogProductsNotifier.new,
);
