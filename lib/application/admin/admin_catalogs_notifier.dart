// lib/application/admin/admin_catalogs_notifier.dart
//
// The ADMIN's "All catalogs" grid: every live catalog, name order, a page at a
// time, narrowed by an optional search.
//
// Same paging contract as the admin subscriptions list: a failed "load more"
// keeps the page already shown (the control simply reappears), and a failed
// refresh over a loaded grid keeps the grid rather than blanking it.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/admin_catalogs_repository.dart';
import '../../domain/entities/admin_catalog_card.dart';

class AdminCatalogsState {
  const AdminCatalogsState({
    required this.items,
    required this.nextCursor,
    this.loadingMore = false,
  });

  final List<AdminCatalogCard> items;
  final String? nextCursor;
  final bool loadingMore;

  bool get hasMore => nextCursor != null;
}

/// One search's pages. The family key is the TRIMMED query ('' = everything),
/// so "cafe" and "cafe " are one provider.
class AdminCatalogsNotifier
    extends AutoDisposeFamilyAsyncNotifier<AdminCatalogsState, String> {
  AdminCatalogsRepository get _repo =>
      ref.read(adminCatalogsRepositoryProvider);

  @override
  Future<AdminCatalogsState> build(String arg) async {
    final page = await _repo.list(query: arg);
    return AdminCatalogsState(items: page.items, nextCursor: page.nextCursor);
  }

  Future<void> refresh() async {
    final next = await AsyncValue.guard(() => build(arg));
    if (next.hasError && state.hasValue) return;
    state = next;
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || !current.hasMore || current.loadingMore) return;
    state = AsyncData(AdminCatalogsState(
      items: current.items,
      nextCursor: current.nextCursor,
      loadingMore: true,
    ));
    try {
      final page = await _repo.list(query: arg, cursor: current.nextCursor);
      // De-duplicated by id: a rename between pages can move a catalog past
      // the cursor, and a card shown twice would open the same page twice.
      final seen = {for (final c in current.items) c.id};
      state = AsyncData(AdminCatalogsState(
        items: [
          ...current.items,
          ...page.items.where((c) => seen.add(c.id)),
        ],
        nextCursor: page.nextCursor,
      ));
    } catch (_) {
      state = AsyncData(AdminCatalogsState(
        items: current.items,
        nextCursor: current.nextCursor,
      ));
    }
  }
}

final adminCatalogsProvider = AsyncNotifierProvider.autoDispose
    .family<AdminCatalogsNotifier, AdminCatalogsState, String>(
  AdminCatalogsNotifier.new,
);
