// lib/application/rep/rep_subscription_notifier.dart
//
// One delegated restaurant's subscription, and the one write a rep may make
// to it: starting the free trial (Door 1).
//
// NOT QUEUED OFFLINE, DELIBERATELY (E40). Every other rep write goes through
// the offline action queue so a dish added on bad wifi lands when the signal
// returns. A trial start must not: replayed after a reconnect it could fire
// twice, or fire for a restaurant the rep has since walked out of — and a
// subscription that appears an hour after the visit, with nobody there to
// see it, is worse than the button saying "Needs a connection".
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/rep_repository.dart';
import '../../domain/entities/catalog_subscription.dart';
import '../../domain/entities/subscription_nudge.dart';
import 'rep_catalogs_notifier.dart';
import 'rep_restaurant_notifier.dart';

class RepSubscriptionNotifier
    extends AutoDisposeFamilyAsyncNotifier<CatalogSubscription, String> {
  RepRepository get _repo => ref.read(repRepositoryProvider);

  @override
  Future<CatalogSubscription> build(String arg) => _repo.subscription(arg);

  /// Re-reads without blanking the card on a failed refresh.
  Future<void> refresh() async {
    try {
      state = AsyncData(await _repo.subscription(arg));
    } catch (error, stack) {
      if (state.valueOrNull == null) state = AsyncError(error, stack);
    }
  }

  /// Starts the trial. The server's answer REPLACES the card's state, and the
  /// two other readers of this restaurant's subscription — the list chip
  /// ([repCatalogsProvider]) and the catalog document behind the detail
  /// header ([repCatalogDocumentProvider]) — are invalidated so all three
  /// agree without a pull-to-refresh.
  ///
  /// Throws the repository's [CatalogFailure] on a refusal; the screen shows
  /// the server's sentence. A refusal that means "someone else just started
  /// it" (SUBSCRIPTION_ACTIVE) still re-reads, so the card catches up.
  Future<CatalogSubscription> startTrial() async {
    try {
      final started = await _repo.startTrial(arg);
      state = AsyncData(started);
      _invalidateSiblings();
      return started;
    } catch (_) {
      // Whatever the refusal, the truth may have moved (another rep, the
      // owner paying); re-read rather than leave "Start free trial" up.
      unawaited(refresh());
      _invalidateSiblings();
      rethrow;
    }
  }

  /// Asks the owner to pay (Door 2's nudge). Never a payment write, so the
  /// list chip and the header are NOT invalidated — nothing they show has
  /// moved. What has moved is the cooldown: a send or a 429 carries the
  /// server's `nextAllowedAt`, and the card adopts it in place so the button
  /// shows "again in Nh" without a re-read. A NOT_NEEDED refusal means the
  /// card's status is stale (the owner paid since it loaded), so that one
  /// re-reads.
  ///
  /// Throws the repository's [CatalogFailure] for anything that is not one of
  /// the three answers — offline, a 5xx, a revoked delegation.
  Future<NudgeResult> notifyOwner() async {
    final result = await _repo.notifyOwner(arg);
    final current = state.valueOrNull;
    final DateTime? nextAllowedAt = switch (result) {
      NudgeSent(:final nextAllowedAt) => nextAllowedAt,
      NudgeCooldown(:final nextAllowedAt) => nextAllowedAt,
      NudgeRefused() => null,
    };
    switch (result) {
      case NudgeSent() || NudgeCooldown():
        if (current != null) {
          state = AsyncData(current.withNudgeNextAllowedAt(nextAllowedAt));
        }
      case NudgeRefused(reason: NudgeRefusal.notNeeded):
        unawaited(refresh());
      case NudgeRefused():
        break;
    }
    return result;
  }

  void _invalidateSiblings() {
    ref.invalidate(repCatalogsProvider);
    ref.invalidate(repCatalogDocumentProvider(arg));
  }
}

final repSubscriptionProvider = AsyncNotifierProvider.autoDispose
    .family<RepSubscriptionNotifier, CatalogSubscription, String>(
  RepSubscriptionNotifier.new,
);
