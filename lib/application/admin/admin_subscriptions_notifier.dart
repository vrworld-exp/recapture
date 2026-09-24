// lib/application/admin/admin_subscriptions_notifier.dart
//
// The admin's subscription surface: the collections list by state (with a
// name search), the cash approval queue, the PAYMENT JOURNAL (every online
// attempt, step by step) with its two fixes ("Check with Razorpay", "Apply to
// catalog"), and one catalog's panel with its actions (verify / reject a cash
// request, start a plan or a trial, comp, extend grace, refund a duplicate,
// record the standees delivered).
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
import '../../domain/entities/admin_payment_attempt.dart';
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

/// A list is one state narrowed by one search. A record, so two equal keys
/// are the same provider and switching back to a segment keeps its pages.
typedef AdminSubscriptionListKey = ({
  AdminSubscriptionFilter filter,
  String query,
});

/// One state's page(s). Keyed by filter and search so switching segments
/// keeps what each one had already loaded.
class AdminSubscriptionListNotifier extends AutoDisposeFamilyAsyncNotifier<
    AdminSubscriptionListState, AdminSubscriptionListKey> {
  PaymentsRepository get _repo => ref.read(paymentsRepositoryProvider);

  @override
  Future<AdminSubscriptionListState> build(AdminSubscriptionListKey arg) async {
    final page = await _repo.subscriptions(filter: arg.filter, query: arg.query);
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
      final page = await _repo.subscriptions(
        filter: arg.filter,
        query: arg.query,
        cursor: current.nextCursor,
      );
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
    AdminSubscriptionListKey>(
  AdminSubscriptionListNotifier.new,
);

// ── The payment journal ─────────────────────────────────────────────────────

class AdminPaymentAttemptsState {
  const AdminPaymentAttemptsState({
    required this.items,
    required this.nextCursor,
    this.loadingMore = false,
  });

  final List<PaymentAttempt> items;
  final String? nextCursor;
  final bool loadingMore;

  bool get hasMore => nextCursor != null;
}

/// One journal filter's page(s). Same paging contract as the collections
/// list: a failed "load more" keeps the page already shown.
class AdminPaymentAttemptsNotifier extends AutoDisposeFamilyAsyncNotifier<
    AdminPaymentAttemptsState, AdminPaymentFilter> {
  PaymentsRepository get _repo => ref.read(paymentsRepositoryProvider);

  @override
  Future<AdminPaymentAttemptsState> build(AdminPaymentFilter arg) async {
    final page = await _repo.paymentAttempts(filter: arg);
    return AdminPaymentAttemptsState(
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
    state = AsyncData(AdminPaymentAttemptsState(
      items: current.items,
      nextCursor: current.nextCursor,
      loadingMore: true,
    ));
    try {
      final page =
          await _repo.paymentAttempts(filter: arg, cursor: current.nextCursor);
      state = AsyncData(AdminPaymentAttemptsState(
        items: [...current.items, ...page.items],
        nextCursor: page.nextCursor,
      ));
    } catch (_) {
      state = AsyncData(AdminPaymentAttemptsState(
        items: current.items,
        nextCursor: current.nextCursor,
      ));
    }
  }
}

final adminPaymentAttemptsProvider = AsyncNotifierProvider.autoDispose.family<
    AdminPaymentAttemptsNotifier,
    AdminPaymentAttemptsState,
    AdminPaymentFilter>(
  AdminPaymentAttemptsNotifier.new,
);

/// One attempt and its two fixes. Each fix answers with the refreshed entry
/// (the server's), which REPLACES the state — nothing is patched locally —
/// and the lists that show it are invalidated.
class AdminPaymentAttemptNotifier
    extends AutoDisposeFamilyAsyncNotifier<PaymentAttempt, String> {
  PaymentsRepository get _repo => ref.read(paymentsRepositoryProvider);

  bool _busy = false;

  /// What Razorpay said at the last "Check", kept for the screen to show.
  ProviderSnapshot? lastProvider;

  @override
  Future<PaymentAttempt> build(String arg) => _repo.paymentAttempt(arg);

  Future<void> refresh() async {
    final next = await AsyncValue.guard(() => _repo.paymentAttempt(arg));
    if (next.hasError && state.hasValue) return;
    state = next;
  }

  void _invalidateLists(String catalogId) {
    ref.invalidate(adminPaymentAttemptsProvider);
    ref.invalidate(adminSubscriptionListProvider);
    if (catalogId.isNotEmpty) {
      ref.invalidate(adminSubscriptionDetailProvider(catalogId));
    }
  }

  Future<T> _act<T>(
    Future<T> Function() action,
    PaymentAttempt Function(T) attemptOf,
  ) async {
    if (_busy) throw const CatalogFailure(code: 'BUSY', message: 'Busy.');
    _busy = true;
    try {
      final result = await action();
      final attempt = attemptOf(result);
      state = AsyncData(attempt);
      _invalidateLists(attempt.catalogId);
      return result;
    } on CatalogFailure catch (failure) {
      // Someone else moved it first — show what is true now.
      if (failure.code == 'ALREADY_RESOLVED' ||
          failure.code == 'NOT_NEEDED' ||
          failure.code == PaymentErrorCodes.alreadyRefunded ||
          failure.code == 'NOT_APPLIED_YET') {
        unawaited(refresh());
        _invalidateLists(state.valueOrNull?.catalogId ?? '');
      }
      rethrow;
    } finally {
      _busy = false;
    }
  }

  /// "Check with Razorpay".
  Future<PaymentSyncResult> sync() => _act(
        () async {
          final result = await _repo.syncPaymentAttempt(arg);
          lastProvider = result.provider;
          Analytics.logEvent('admin_payment_checked', {
            'outcome': result.outcome.name,
          });
          return result;
        },
        (result) => result.attempt,
      );

  /// "Apply to catalog", with the reason.
  Future<PaymentAttempt> forceApply(String note) => _act(
        () async {
          final attempt = await _repo.forceApplyPaymentAttempt(arg, note: note);
          Analytics.logEvent('admin_payment_force_applied', const {});
          return attempt;
        },
        (attempt) => attempt,
      );
}

final adminPaymentAttemptProvider = AsyncNotifierProvider.autoDispose
    .family<AdminPaymentAttemptNotifier, PaymentAttempt, String>(
  AdminPaymentAttemptNotifier.new,
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

  /// Every sibling that shows this catalog: the queue, the state lists (every
  /// search of every segment) and the payment journal.
  void _invalidateSiblings() {
    ref.invalidate(adminManualQueueProvider);
    ref.invalidate(adminSubscriptionListProvider);
    ref.invalidate(adminPaymentAttemptsProvider);
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
          failure.code == PaymentErrorCodes.exceedsIncluded ||
          failure.code == 'TRIAL_ALREADY_USED' ||
          failure.code == 'SUBSCRIPTION_ACTIVE' ||
          failure.code == 'TRIAL_NOT_ELIGIBLE') {
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

  /// Re-tells Mirage the current CUSTOMER PAGE state and payment deadline.
  /// Answers the job id.
  Future<String> resyncPageState() => _act(() => _repo.resyncPageState(arg));

  /// "Start plan" — the admin took the money (cash, UPI, a Razorpay payment
  /// that reached no order): one CREATE_AND_VERIFY call, which is the same
  /// activation a verified cash request gets.
  Future<ManualPaymentRecord> startPlan(
    ManualPaymentRequest request, {
    bool override = false,
  }) =>
      _act(() async {
        final record = await _repo.startPlan(arg, request, override: override);
        Analytics.logEvent('admin_plan_started', {
          'plan_id': request.planId.apiValue,
          'interval': request.interval.apiValue,
          'method': request.method.apiValue,
        });
        return record;
      });

  /// The same free trial a rep can start.
  Future<CatalogSubscription> startTrial() => _act(() => _repo.startTrial(arg));

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
