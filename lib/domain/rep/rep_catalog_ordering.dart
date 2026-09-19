// lib/domain/rep/rep_catalog_ordering.dart
//
// The order 'My restaurants' shows a rep's catalogs in: the ones that need
// a visit or a nudge first.
//
// The server hands the list back in delegation order (newest grant first),
// which is the order a rep signed restaurants up in — not the order they
// need to work them in today. An overdue restaurant three weeks down the
// list is the one whose 3D menu pauses on Friday, so it goes to the top;
// within a status, the one with the fewest days left comes first.
//
// Pure and stable: equal rows keep the server's relative order, so a list
// of ten ACTIVE restaurants does not reshuffle on every refresh.
import '../entities/catalog_subscription.dart';
import '../entities/rep_activation.dart';

/// Lower is more urgent. `NONE` (no row) sits with PAUSED and above TRIAL:
/// a restaurant with no plan at all is exactly who a rep should be calling.
int repAttentionRank(SubscriptionStatus status) => switch (status) {
      SubscriptionStatus.grace => 0,
      SubscriptionStatus.paused => 1,
      SubscriptionStatus.none => 2,
      SubscriptionStatus.trial => 3,
      SubscriptionStatus.active => 4,
      SubscriptionStatus.comped => 5,
      SubscriptionStatus.cancelled => 6,
      SubscriptionStatus.unknown => 7,
    };

/// A copy of [items] sorted for attention: by status rank, then by
/// `daysLeft` ascending with "nothing counting down" (null) last.
List<RepCatalogSummary> orderRepCatalogsForAttention(
  List<RepCatalogSummary> items,
) {
  final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])];
  indexed.sort((a, b) {
    final sa = a.$2.subscription;
    final sb = b.$2.subscription;
    final byRank = repAttentionRank(sa?.status ?? SubscriptionStatus.none)
        .compareTo(repAttentionRank(sb?.status ?? SubscriptionStatus.none));
    if (byRank != 0) return byRank;
    final da = sa?.daysLeft;
    final db = sb?.daysLeft;
    if (da != db) {
      if (da == null) return 1;
      if (db == null) return -1;
      final byDays = da.compareTo(db);
      if (byDays != 0) return byDays;
    }
    // Stable: fall back to the server's order.
    return a.$1.compareTo(b.$1);
  });
  return [for (final entry in indexed) entry.$2];
}
