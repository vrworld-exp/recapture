// lib/application/catalog/subscription_notifier.dart
//
// The owner's subscription, as the Subscription screen reads it.
//
// autoDispose: the countdown and the usage are SERVER numbers (D6, C1), and a
// kept-alive copy would show yesterday's "12 days left" until sign-out. Every
// open of the screen is a read; [refresh] is pull-to-refresh and the retry.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_repository.dart';
import '../../domain/entities/catalog_subscription.dart';

class SubscriptionNotifier
    extends AutoDisposeAsyncNotifier<CatalogSubscription> {
  bool _disposed = false;

  @override
  Future<CatalogSubscription> build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    return ref.read(catalogRepositoryProvider).subscription();
  }

  /// Re-reads now. Keeps the last good value on screen if the re-read fails —
  /// a status line that blanks on a flaky connection reads as "no plan".
  Future<void> refresh() async {
    final next = await AsyncValue.guard(
      () => ref.read(catalogRepositoryProvider).subscription(),
    );
    if (_disposed) return;
    if (next.hasError && state.hasValue) return;
    state = next;
  }
}

final subscriptionProvider = AsyncNotifierProvider.autoDispose<
    SubscriptionNotifier, CatalogSubscription>(
  SubscriptionNotifier.new,
);
