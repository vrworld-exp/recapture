// lib/application/catalog/checkout_notifier.dart
//
// The owner's Pay / Renew / Upgrade — AUTOPAY since Sept 2026: the button
// sets up a Razorpay subscription (a mandate that charges every month or
// year by itself) rather than a one-time order. The one-time order is still
// here as the FALLBACK for a server that has no autopay route yet (a 404 with
// no envelope — a deploy skew), so an app released first never loses Pay.
//
// End to end:
//
//   idle → quoting → showingSdk → activating → done
//                 ↘ unavailable         ↘ confirming (timed out — the server
//                 ↘ failed                 will still reconcile, never "unpaid")
//                                        ↺ "Check again" → activating
//
// THE SDK'S SUCCESS IS NOT THE ANSWER (§7 rule 1). The Razorpay sheet says
// "paid" to the phone; the subscription is ACTIVE only when the SERVER has
// recorded it. The server hears it three ways: this notifier POSTs the signed
// success response to `/catalog/subscription/verify` straight away (the
// server checks the signature and asks Razorpay — usually ACTIVE right
// there), Razorpay's webhook, and the reconciler. After the verify this
// notifier checks at once, then POLLS `subscriptionProvider` — 2 s → 10 s, for up to two minutes —
// and calls it done when the status actually flips. If two minutes pass it
// says "being confirmed" and stops: the backend's reconciler will find the
// payment within its own window, and a screen that said "unpaid" now would be
// lying about money.
//
// The poll shape is PublishFlow's (backoff table, lifecycle pause with an
// immediate catch-up on resume), copied rather than shared: that flow is
// about a run with a progress line, this one about a single flip, and the
// stage's brief was to leave PublishFlow untouched.
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show immutable, visibleForTesting;
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_failure.dart';
import '../../data/repositories/payments_repository.dart';
import '../../domain/entities/catalog_subscription.dart';
import '../../domain/entities/subscription_payment.dart';
import '../../utils/analytics.dart';
import 'catalog_notifier.dart';
import 'checkout_adapter.dart';
import 'subscription_notifier.dart';

/// Where the checkout is.
enum CheckoutPhase {
  idle,

  /// `POST …/order` in flight.
  quoting,

  /// The Razorpay sheet is up. The app may be backgrounded by a UPI app.
  showingSdk,

  /// The SDK said success; waiting for the server to say ACTIVE.
  activating,

  /// The server says ACTIVE. The screen's subscription is already refreshed.
  done,

  /// Polled for the whole budget without seeing the flip. NOT a failure.
  confirming,

  /// The order could not be minted or the SDK reported an error.
  failed,

  /// 503 PAYMENTS_UNAVAILABLE — "try again in a minute" (D7).
  unavailable,
}

@immutable
class CheckoutState {
  const CheckoutState({
    this.phase = CheckoutPhase.idle,
    this.order,
    this.autopay,
    this.failureCode,
    this.secondsToConfirm,
  });

  final CheckoutPhase phase;

  /// The last one-time quote the server handed back (the old-server
  /// fallback only) — the E9 warning reads [CheckoutOrder.daysForfeited].
  final CheckoutOrder? order;

  /// The autopay mandate the sheet opened on. The E9 warning reads its
  /// [AutopayCheckout.daysForfeited]; a deferred one ([isDeferredAutopay])
  /// charges nothing today and is "done" when the mandate is approved.
  final AutopayCheckout? autopay;

  /// The owner turned autopay on over a period they had already paid for:
  /// nothing is charged now, so "done" means "autopay is on", not "paid".
  bool get isDeferredAutopay => autopay?.isDeferred ?? false;

  /// The server's forfeit figure for whatever was quoted last; null before.
  int? get daysForfeited => autopay?.daysForfeited ?? order?.daysForfeited;

  /// The envelope code (or the SDK's code) behind a [CheckoutPhase.failed].
  final String? failureCode;

  /// How long the flip took, once [CheckoutPhase.done].
  final int? secondsToConfirm;

  /// A tap on Pay must do nothing while any of these is true.
  bool get isBusy =>
      phase == CheckoutPhase.quoting ||
      phase == CheckoutPhase.showingSdk ||
      phase == CheckoutPhase.activating;

  CheckoutState copyWith({
    CheckoutPhase? phase,
    Object? order = _unset,
    Object? autopay = _unset,
    Object? failureCode = _unset,
    Object? secondsToConfirm = _unset,
  }) =>
      CheckoutState(
        phase: phase ?? this.phase,
        order: identical(order, _unset) ? this.order : order as CheckoutOrder?,
        autopay: identical(autopay, _unset)
            ? this.autopay
            : autopay as AutopayCheckout?,
        failureCode: identical(failureCode, _unset)
            ? this.failureCode
            : failureCode as String?,
        secondsToConfirm: identical(secondsToConfirm, _unset)
            ? this.secondsToConfirm
            : secondsToConfirm as int?,
      );
}

const Object _unset = Object();

/// How long to wait before each activation poll. Front-loaded — a UPI success
/// usually reaches the webhook within seconds — then flat at ten.
const List<Duration> kCheckoutPollBackoff = [
  Duration(seconds: 2),
  Duration(seconds: 3),
  Duration(seconds: 5),
  Duration(seconds: 8),
  Duration(seconds: 10),
];

/// Total time spent waiting for the flip before saying "being confirmed".
const Duration kCheckoutPollBudget = Duration(minutes: 2);

/// Test seams: the waits, overridden to zero so a test does not sit through
/// two real minutes; and the clock.
final checkoutPollBackoffProvider =
    Provider<List<Duration>>((_) => kCheckoutPollBackoff);
final checkoutPollBudgetProvider =
    Provider<Duration>((_) => kCheckoutPollBudget);

class CheckoutNotifier extends AutoDisposeNotifier<CheckoutState> {
  Timer? _poll;
  int _pollAttempt = 0;
  DateTime? _pollStartedAt;
  bool _disposed = false;
  bool _paused = false;
  AppLifecycleListener? _lifecycle;

  /// What the subscription looked like BEFORE the payment — the flip is
  /// judged against it, so an owner renewing an already-ACTIVE plan is not
  /// told "done" by the status they already had.
  CatalogSubscription? _baseline;

  @override
  CheckoutState build() {
    _disposed = false;
    _lifecycle = AppLifecycleListener(
      onHide: _pause,
      onPause: _pause,
      onShow: _resume,
      onRestart: _resume,
    );
    ref.onDispose(() {
      _disposed = true;
      _cancelPoll();
      _lifecycle?.dispose();
      _lifecycle = null;
    });
    return const CheckoutState();
  }

  PaymentsRepository get _repo => ref.read(paymentsRepositoryProvider);
  CheckoutAdapter get _adapter => ref.read(checkoutAdapterProvider);

  /// The whole flow, from a tap. Ignored while busy (a double-tap is one
  /// order — and the server would hand the same one back anyway).
  Future<void> pay({
    required PlanId planId,
    required BillingInterval interval,
  }) async {
    if (state.isBusy) return;
    _baseline = ref.read(subscriptionProvider).valueOrNull;
    state = state.copyWith(
      phase: CheckoutPhase.quoting,
      failureCode: null,
      secondsToConfirm: null,
    );

    AutopayCheckout? autopay;
    CheckoutOrder? order;
    try {
      autopay = await _repo.startAutopay(planId: planId, interval: interval);
    } on CatalogFailure catch (failure) {
      if (_disposed) return;
      if (!_isRouteMissing(failure)) return _failQuote(failure);
      // An older server with no autopay route: the one-time order it has.
      try {
        order = await _repo.createOrder(planId: planId, interval: interval);
      } on CatalogFailure catch (fallbackFailure) {
        if (_disposed) return;
        return _failQuote(fallbackFailure);
      }
    }
    if (_disposed) return;

    final keyId = autopay?.keyId ?? order!.keyId;
    final amountPaise = autopay?.amountPaise ?? order!.amountPaise;
    Analytics.logEvent('checkout_opened', {
      'plan_id': (autopay?.planId ?? order!.planId).apiValue,
      'interval': (autopay?.interval ?? order!.interval).apiValue,
      'amount_paise': amountPaise,
      'surface': 'owner',
      'autopay': autopay != null,
    });
    state = state.copyWith(
      phase: CheckoutPhase.showingSdk,
      order: order,
      autopay: autopay,
    );

    final outcome = await _adapter.open(
      keyId: keyId,
      orderId: order?.providerOrderId,
      subscriptionId: autopay?.providerSubscriptionId,
      amountPaise: amountPaise,
      description: autopay?.description ?? order!.description,
    );
    if (_disposed) return;
    // A UPI app may have taken the user out and the webhook may have landed
    // while they were away — a poll on resume can already have said done.
    if (state.phase == CheckoutPhase.done) return;

    // The SDK may omit razorpay_subscription_id; we know which mandate we
    // opened, and the server checks the signature against it either way.
    final result = outcome is CheckoutSuccess &&
            autopay != null &&
            (outcome.subscriptionId?.isEmpty ?? true)
        ? CheckoutSuccess(
            outcome.paymentId,
            orderId: outcome.orderId,
            subscriptionId: autopay.providerSubscriptionId,
            signature: outcome.signature,
          )
        : outcome;

    switch (result) {
      case CheckoutSuccess() when result.canVerify:
        Analytics.logEvent('checkout_result', {'result': 'success'});
        state = state.copyWith(phase: CheckoutPhase.activating);
        await _verify(result);
        if (_disposed || state.phase != CheckoutPhase.activating) return;
        _startActivationPoll(checkNow: true);
      case CheckoutSuccess():
        Analytics.logEvent('checkout_result', {'result': 'success'});
        _startActivationPoll();
      case CheckoutCancelled():
        // Back to idle with the same open order: the server returns it on
        // the next tap, so nothing here needs remembering.
        Analytics.logEvent('checkout_result', {'result': 'cancelled'});
        state = state.copyWith(phase: CheckoutPhase.idle);
      case CheckoutFailed(:final code):
        Analytics.logEvent('checkout_result', {'result': 'failed'});
        state = state.copyWith(phase: CheckoutPhase.failed, failureCode: code);
      case CheckoutUnsupported():
        Analytics.logEvent('checkout_result', {'result': 'unsupported'});
        state = state.copyWith(
          phase: CheckoutPhase.failed,
          failureCode: 'UNSUPPORTED',
        );
    }
  }

  /// "Check again" on a "being confirmed": one more activation pass with a
  /// fresh budget. The read it starts with is what makes the server settle a
  /// paid order the webhook never delivered. Only from [CheckoutPhase.confirming]
  /// — the phase flips to activating synchronously, so a double tap is one pass.
  Future<void> checkAgain() async {
    if (state.phase != CheckoutPhase.confirming) return;
    Analytics.logEvent('checkout_check_again', {'surface': 'owner'});
    state = state.copyWith(phase: CheckoutPhase.activating);
    _pollAttempt = 0;
    _pollStartedAt = DateTime.now();
    await _checkOnce();
  }

  /// Puts a "being confirmed" or a failure away so the button is a button again.
  void dismiss() {
    if (state.isBusy) return;
    state = state.copyWith(phase: CheckoutPhase.idle, failureCode: null);
  }

  /// Hands the signed response to the server. Best-effort: a failure here
  /// (offline, 5xx, a signature the server rejects) is NOT "unpaid" — the
  /// webhook and the reconciler still stand behind it, and the poll that
  /// follows reads whatever the server decided.
  Future<void> _verify(CheckoutSuccess success) async {
    try {
      final subscriptionId = success.subscriptionId;
      if (subscriptionId != null && subscriptionId.isNotEmpty) {
        await _repo.verifyAutopay(
          subscriptionId: subscriptionId,
          paymentId: success.paymentId,
          signature: success.signature!,
        );
      } else {
        await _repo.verifyPayment(
          orderId: success.orderId!,
          paymentId: success.paymentId,
          signature: success.signature!,
        );
      }
    } on CatalogFailure catch (failure) {
      Analytics.logEvent('checkout_verify_failed', {'code': failure.code});
    }
  }

  // ── The activation poll ───────────────────────────────────────────────────

  /// [checkNow]: read at once instead of after the first backoff — the verify
  /// that preceded it has usually already made the row ACTIVE.
  void _startActivationPoll({bool checkNow = false}) {
    state = state.copyWith(phase: CheckoutPhase.activating);
    _pollAttempt = 0;
    _pollStartedAt = DateTime.now();
    if (checkNow) {
      unawaited(_checkOnce());
    } else {
      _scheduleNextPoll();
    }
  }

  void _scheduleNextPoll() {
    _poll?.cancel();
    if (_disposed || _paused) return;
    final backoff = ref.read(checkoutPollBackoffProvider);
    final delay = backoff[min(_pollAttempt, backoff.length - 1)];
    _pollAttempt++;
    _poll = Timer(delay, () => unawaited(_checkOnce()));
  }

  /// One re-read of the subscription, and the decision that follows it.
  Future<void> _checkOnce() async {
    if (_disposed) return;
    await ref.read(subscriptionProvider.notifier).refresh();
    if (_disposed) return;
    final current = ref.read(subscriptionProvider).valueOrNull;

    if (current != null && _hasFlipped(current)) {
      final seconds = _pollStartedAt == null
          ? 0
          : DateTime.now().difference(_pollStartedAt!).inSeconds;
      Analytics.logEvent(
        'checkout_activation_confirmed',
        {'seconds_to_confirm': seconds},
      );
      _cancelPoll();
      state = state.copyWith(
        phase: CheckoutPhase.done,
        secondsToConfirm: seconds,
      );
      // The app-wide catalog carries the compact summary the catalog header
      // and the Profile row read — bring it along, or they say "No plan" to
      // an owner who just paid until something else happens to refresh it.
      if (ref.exists(catalogProvider)) {
        unawaited(ref.read(catalogProvider.notifier).refresh());
      }
      return;
    }

    if (state.phase != CheckoutPhase.activating) return;
    final budget = ref.read(checkoutPollBudgetProvider);
    final elapsed = _pollStartedAt == null
        ? Duration.zero
        : DateTime.now().difference(_pollStartedAt!);
    if (elapsed >= budget) {
      // NOT "unpaid" (B1). The server reconciles; the screen stays usable.
      _cancelPoll();
      state = state.copyWith(phase: CheckoutPhase.confirming);
      return;
    }
    _scheduleNextPoll();
  }

  /// ACTIVE, and not the ACTIVE we started with: a new period end (or a
  /// status that was not ACTIVE before). `periodStart` is not on the DTO, so
  /// `periodEnd` — which a fresh period always moves — is the tell.
  bool _hasFlipped(CatalogSubscription current) {
    // A deferred mandate charges nothing now: it is done when the server says
    // autopay is on for it.
    final autopay = state.autopay;
    if (autopay != null && autopay.isDeferred) {
      final on = current.autopay;
      return on != null &&
          on.isHealthy &&
          on.planId == autopay.planId &&
          on.interval == autopay.interval;
    }
    if (current.status != SubscriptionStatus.active) return false;
    final before = _baseline;
    if (before == null || before.status != SubscriptionStatus.active) {
      return true;
    }
    return current.periodEnd != before.periodEnd;
  }

  /// A 404 with no envelope code: the ROUTE is missing (an older server),
  /// not a missing catalog — which answers with its own code.
  static bool _isRouteMissing(CatalogFailure failure) =>
      failure.statusCode == 404 && failure.code == 'UNKNOWN';

  void _failQuote(CatalogFailure failure) {
    state = state.copyWith(
      phase: failure.code == PaymentErrorCodes.paymentsUnavailable ||
              failure.isOffline
          ? CheckoutPhase.unavailable
          : CheckoutPhase.failed,
      failureCode: failure.code,
    );
  }

  void _cancelPoll() {
    _poll?.cancel();
    _poll = null;
  }

  void _pause() {
    if (_disposed || _paused) return;
    _paused = true;
    _cancelPoll();
  }

  void _resume() {
    if (_disposed || !_paused) return;
    _paused = false;
    // Backgrounded mid-checkout (a UPI app), or mid-poll: re-read BEFORE
    // deciding anything — the flip may already have happened.
    if (state.phase == CheckoutPhase.showingSdk ||
        state.phase == CheckoutPhase.activating) {
      _pollAttempt = 0;
      unawaited(_checkOnce());
    }
  }

  /// Test seam for the lifecycle transitions.
  @visibleForTesting
  void debugLifecycle({required bool hidden}) => hidden ? _pause() : _resume();
}

final checkoutProvider =
    NotifierProvider.autoDispose<CheckoutNotifier, CheckoutState>(
  CheckoutNotifier.new,
);
