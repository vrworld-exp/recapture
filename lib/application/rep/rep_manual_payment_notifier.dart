// lib/application/rep/rep_manual_payment_notifier.dart
//
// One delegated restaurant's cash request (Door 3, the rep's half): the one
// still awaiting an admin, if any, and the submit that creates it.
//
// NOT QUEUED OFFLINE, like the trial (E40): a cash request replayed after a
// reconnect could record money twice, or for a restaurant the rep has since
// left. The sheet refuses to submit offline instead.
//
// What this notifier can NEVER do is activate anything — the server writes a
// PENDING ledger row and nothing else (AC-6.1); an admin verifies.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/payments_repository.dart';
import '../../domain/entities/subscription_payment.dart';
import '../../utils/analytics.dart';

class RepManualPaymentNotifier
    extends AutoDisposeFamilyAsyncNotifier<ManualPaymentRecord?, String> {
  PaymentsRepository get _repo => ref.read(paymentsRepositoryProvider);

  @override
  Future<ManualPaymentRecord?> build(String arg) =>
      _repo.pendingManualPayment(arg);

  Future<void> refresh() async {
    try {
      state = AsyncData(await _repo.pendingManualPayment(arg));
    } catch (error, stack) {
      if (state.valueOrNull == null && !state.hasValue) {
        state = AsyncError(error, stack);
      }
    }
  }

  /// Submits the form. The server's record REPLACES the card's state — a
  /// request that already existed comes back with `existing: true`, and the
  /// card shows it rather than the form. Throws the repository's
  /// [CatalogFailure] on a refusal; the sheet shows our sentence.
  Future<ManualPaymentSubmission> submit(ManualPaymentRequest request) async {
    final submission = await _repo.submitManualPayment(arg, request);
    state = AsyncData(submission.record);
    Analytics.logEvent('rep_manual_payment_submitted', {
      'catalog_id': arg,
      'method': request.method.apiValue,
    });
    return submission;
  }
}

final repManualPaymentProvider = AsyncNotifierProvider.autoDispose
    .family<RepManualPaymentNotifier, ManualPaymentRecord?, String>(
  RepManualPaymentNotifier.new,
);
