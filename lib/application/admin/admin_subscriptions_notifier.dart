// lib/application/admin/admin_subscriptions_notifier.dart
//
// The admin's subscription surface: the collections list by state, the cash
// approval queue, and one catalog's panel with its six actions (verify /
// reject a cash request, comp, extend grace, refund a duplicate, record the
// standees delivered).
//
// EVERY ACTION RE-READS. The server is the only author of the ledger and the
// status; after a decision the panel is reloaded rather than patched, and the
// list and queue that also show this catalog are invalidated so an admin who
// goes back sees the row gone. A 409 (someone decided first) is surfaced as
// its sentence AND triggers the same re-read — the list refreshes either way.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_failure.dart';
import '../../data/repositories/payments_repository.dart';
import '../../domain/entities/catalog_subscription.dart';
import '../../domain/entities/subscription_payment.dart';
import '../../utils/analytics.dart';

// ── The queue ───────────────────────────────────────────────────────────────

/// Cash requests awaiting verification, newest first.
final adminManualQueueProvider =
    FutureProvider.autoDispose<List<ManualPaymentRecord>>(
  (ref) => ref.watch(paymentsRepositoryProvider).manualPaymentQueue(),
);

// ── The collections list ────────────────────────────────────────────────────

class AdminSubscriptionListState {
  const AdminSubscriptionListState({
    required this.items,
    required this.nextCursor,
    this.loadingMore = false,
  });

  final List<AdminSubscriptionListItem> items;
  final String? nextCursor;
  final bool loadingMore;

  bool get hasMore => nextCursor != null;
}

/// One state's page(s). Keyed by filter so switching segments keeps what
/// each one had already loaded.
class AdminSubscriptionListNotifier extends AutoDisposeFamilyAsyncNotifier<
    AdminSubscriptionListState, AdminSubscriptionFilter> {
  PaymentsRepository get _repo => ref.read(paymentsRepositoryProvider);

  @override
  Future<AdminSubscriptionListState> build(AdminSubscriptionFilter arg) async {
    final page = await _repo.subscriptions(filter: arg);
    return AdminSubscriptionListState(
      items: page.items,
      nextCursor: page.nextCursor,
    );
  }

  Future<void> refresh() async {
    final next = await AsyncValue.guard(() => build(arg));
    if (next.hasError && state.hasValue) return;
    state = next;
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || !current.hasMore || current.loadingMore) return;
    state = AsyncData(AdminSubscriptionListState(
      items: current.items,
      nextCursor: current.nextCursor,
      loadingMore: true,
    ));
    try {
      final page =
          await _repo.subscriptions(filter: arg, cursor: current.nextCursor);
      state = AsyncData(AdminSubscriptionListState(
        items: [...current.items, ...page.items],
        nextCursor: page.nextCursor,
      ));
    } catch (_) {
      // Keep the page we have; the "load more" control simply reappears.
      state = AsyncData(AdminSubscriptionListState(
        items: current.items,
        nextCursor: current.nextCursor,
      ));
    }
  }
}

final adminSubscriptionListProvider = AsyncNotifierProvider.autoDispose.family<
    AdminSubscriptionListNotifier,
    AdminSubscriptionListState,
    AdminSubscriptionFilter>(
  AdminSubscriptionListNotifier.new,
);

// ── One catalog's panel ─────────────────────────────────────────────────────

class AdminSubscriptionDetailNotifier
    extends AutoDisposeFamilyAsyncNotifier<AdminSubscriptionDetail, String> {
  PaymentsRepository get _repo => ref.read(paymentsRepositoryProvider);

  /// An action in flight. One at a time: two overlapping decisions would race
  /// to say which one the confirmation was about.
  bool _busy = false;
  bool get isBusy => _busy;

  @override
  Future<AdminSubscriptionDetail> build(String arg) =>
      _repo.subscriptionDetail(arg);

  Future<void> refresh() async {
    final next = await AsyncValue.guard(() => _repo.subscriptionDetail(arg));
    if (next.hasError && state.hasValue) return;
    state = next;
  }

  /// Every sibling that shows this catalog: the queue and the five lists.
  void _invalidateSiblings() {
    ref.invalidate(adminManualQueueProvider);
    for (final filter in AdminSubscriptionFilter.values) {
      ref.invalidate(adminSubscriptionListProvider(filter));
    }
  }

  /// Runs [action], then re-reads whatever happened — success or a 409 both
  /// mean the truth moved. Rethrows so the screen shows the sentence.
  Future<T> _act<T>(Future<T> Function() action) async {
    if (_busy) throw const CatalogFailure(code: 'BUSY', message: 'Busy.');
    _busy = true;
    try {
      final result = await action();
      await refresh();
      _invalidateSiblings();
      return result;
    } on CatalogFailure catch (failure) {
      if (failure.code == PaymentErrorCodes.alreadyDecided ||
          failure.code == PaymentErrorCodes.alreadyRefunded ||
          failure.code == PaymentErrorCodes.catalogDeleted ||
          failure.code == PaymentErrorCodes.notInGrace ||
          failure.code == PaymentErrorCodes.exceedsIncluded) {
        unawaited(refresh());
        _invalidateSiblings();
      }
      rethrow;
    } finally {
      _busy = false;
    }
  }

  Future<ManualPaymentRecord> decide({
    required String paymentRecordId,
    required ManualPaymentDecision decision,
    String? note,
    bool override = false,
  }) =>
      _act(() async {
        final record = await _repo.decideManualPayment(
          arg,
          paymentRecordId: paymentRecordId,
          decision: decision,
          note: note,
          override: override,
        );
        Analytics.logEvent('admin_manual_payment_decided', {
          'decision': decision == ManualPaymentDecision.verify
              ? 'VERIFIED'
              : 'REJECTED',
        });
        return record;
      });

  Future<CatalogSubscription> comp({
    required DateTime until,
    required String note,
  }) =>
      _act(() => _repo.comp(arg, until: until, note: note));

  Future<CatalogSubscription> extendGrace({
    required int days,
    required String note,
  }) =>
      _act(() => _repo.extendGrace(arg, days: days, note: note));

  /// Re-tells Mirage the current 3D entitlement (E18). Answers the job id.
  Future<String> resyncArEntitlement() =>
      _act(() => _repo.resyncArEntitlement(arg));

  /// The standees-delivered counter (README C8). An absolute number.
  Future<CatalogSubscription> setStandeesIssued({
    required int issued,
    String? note,
  }) =>
      _act(() => _repo.setStandeesIssued(arg, issued: issued, note: note));

  Future<PaymentRecordSummary> refund({
    required String refundsPaymentId,
    required String note,
    bool override = false,
  }) =>
      _act(() async {
        final record = await _repo.refund(
          arg,
          refundsPaymentId: refundsPaymentId,
          note: note,
          override: override,
        );
        Analytics.logEvent('admin_refund_issued', const {});
        return record;
      });
}

final adminSubscriptionDetailProvider = AsyncNotifierProvider.autoDispose
    .family<AdminSubscriptionDetailNotifier, AdminSubscriptionDetail, String>(
  AdminSubscriptionDetailNotifier.new,
);
