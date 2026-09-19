// lib/application/catalog/payment_history_notifier.dart
//
// The owner's ledger — the last fifty rows, newest first, refunds included so
// the history is honest. autoDispose for the same reason the subscription
// itself is: a kept-alive copy would keep showing the list from before the
// payment that was just made.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/payments_repository.dart';
import '../../domain/entities/subscription_payment.dart';

class PaymentHistoryNotifier
    extends AutoDisposeAsyncNotifier<List<PaymentRecordSummary>> {
  bool _disposed = false;

  @override
  Future<List<PaymentRecordSummary>> build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    return ref.read(paymentsRepositoryProvider).ownerPayments();
  }

  /// Re-reads; keeps the last good list on a failed refresh.
  Future<void> refresh() async {
    final next = await AsyncValue.guard(
      () => ref.read(paymentsRepositoryProvider).ownerPayments(),
    );
    if (_disposed) return;
    if (next.hasError && state.hasValue) return;
    state = next;
  }
}

final paymentHistoryProvider = AsyncNotifierProvider.autoDispose<
    PaymentHistoryNotifier, List<PaymentRecordSummary>>(
  PaymentHistoryNotifier.new,
);
