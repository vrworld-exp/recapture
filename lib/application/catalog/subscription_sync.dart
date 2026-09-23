// lib/application/catalog/subscription_sync.dart
//
// Keeps "is this account on a plan?" current everywhere it is shown — the
// catalog header, the Profile row, the subscription screen.
//
// Sign-in is already covered: [catalogProvider] watches the session, so a new
// session loads the catalog, and `GET /catalog` settles any paid-but-unrecorded
// Razorpay order before it answers (reconcileService.settleOpenOrdersOnRead).
// What was NOT covered is the app coming back to the foreground — from the UPI
// app that took the payment, or after hours in the background while a payment
// was recorded elsewhere. This re-reads on resume, silently (the current value
// stays on screen), and at most once per [kSubscriptionResumeRefreshGap].
import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_notifier.dart';
import 'catalog_notifier.dart';
import 'subscription_notifier.dart';

const Duration kSubscriptionResumeRefreshGap = Duration(seconds: 30);

/// Eager-init from the app shell (ref.read in [ReCapture.build]), beside
/// backendWarmupProvider.
final subscriptionSyncProvider = Provider<void>((ref) {
  DateTime? lastRefresh;

  void onResume() {
    final session = ref.read(sessionIdentityProvider);
    if (session == null || session == 'restoring') return;
    final now = DateTime.now();
    if (lastRefresh != null &&
        now.difference(lastRefresh!) < kSubscriptionResumeRefreshGap) {
      return;
    }
    lastRefresh = now;
    unawaited(ref.read(catalogProvider.notifier).refresh());
    // Only when the subscription screen is actually open — reading an
    // autoDispose provider from here would create one just to throw it away.
    if (ref.exists(subscriptionProvider)) {
      unawaited(ref.read(subscriptionProvider.notifier).refresh());
    }
  }

  final listener = AppLifecycleListener(onResume: onResume);
  ref.onDispose(listener.dispose);
});
