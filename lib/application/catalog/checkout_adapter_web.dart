// lib/application/catalog/checkout_adapter_web.dart
//
// The browser half of the checkout seam: Razorpay's Checkout.js, opened as an
// overlay INSIDE the page (AC-7.2 — no redirect, no hosted checkout page, no
// tab of our own).
//
// `razorpay_flutter` ships for Android and iOS only, so the web build cannot
// share the io half. Razorpay's own answer for browsers is checkout.js — the
// SAME order, the SAME key id, the SAME webhook — driven here through
// dart:js_interop against the `Razorpay` global the script installs on
// `window`. Nothing on the server knows or cares which half opened the sheet.
//
// THE SCRIPT IS FETCHED ON DEMAND, not from index.html. It is a third-party
// download only an owner on the Subscription screen ever needs, and a static
// <script> tag has no way to tell Dart "blocked" — an ad blocker or a locked
// down network would leave a Pay button that silently does nothing. The
// loader is memoised so one tab fetches it once, and a failed load is
// forgotten so the next tap tries again instead of failing forever.
//
// WHAT THE SDK REPORTS, AND WHEN. checkout.js fires `payment.failed` for
// EVERY failed attempt while the overlay is still up — with retry enabled the
// user can pick another method in the same sheet, and a success after a
// failure is still a success. So a failure is only REMEMBERED here, and the
// outcome is decided when the overlay actually closes: success from the
// `handler`, else the last failure, else cancelled. That is the shape the
// native SDK reports in, so the notifier sees the same thing on both targets.
//
// Written against package:web / dart:js_interop, not the deprecated
// dart:html. Only ever compiled for the web target — selected by the
// conditional import in checkout_adapter.dart.
import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:web/web.dart' as web;

import 'checkout_adapter.dart';

/// checkout.js is part of this build (fetched on first use).
const bool kCanCheckoutInApp = true;

/// Razorpay's hosted script. Razorpay versions it under `/v1` and updates it
/// in place; it is not vendored, so the checkout never falls behind their
/// payment-method changes.
const String kRazorpayCheckoutJsUrl =
    'https://checkout.razorpay.com/v1/checkout.js';

/// How long a checkout.js fetch may take before it counts as blocked. An ad
/// blocker or an offline tab fails the fetch at once; a black-holed network
/// never answers at all, and without this the Pay button would spin forever.
const Duration kCheckoutJsLoadTimeout = Duration(seconds: 8);

String _checkoutJsUrl = kRazorpayCheckoutJsUrl;
Duration _checkoutJsLoadTimeout = kCheckoutJsLoadTimeout;

CheckoutAdapter createPlatformCheckoutAdapter() {
  // Warm the script while the owner is still reading the plans, so the tap on
  // Pay is not also the download. A failure here is deliberately dropped:
  // [RazorpayWebCheckoutAdapter.open] loads again and reports it properly.
  _ensureCheckoutJs().ignore();
  return const RazorpayWebCheckoutAdapter();
}

/// One overlay per [open]: a fresh `Razorpay` instance is built, listened to,
/// and forgotten when the overlay answers, so two checkouts in one tab can
/// never cross their callbacks.
class RazorpayWebCheckoutAdapter implements CheckoutAdapter {
  const RazorpayWebCheckoutAdapter();

  @override
  bool get isSupported => true;

  @override
  Future<CheckoutOutcome> open({
    required String keyId,
    String? orderId,
    String? subscriptionId,
    required int amountPaise,
    required String description,
  }) async {
    try {
      await _ensureCheckoutJs();
    } catch (_) {
      // Blocked, offline, or the script evaluated without defining the global.
      // The order stays open on the server; the next tap tries the load again.
      return const CheckoutOutcome.failed(
        code: 'SDK_UNAVAILABLE',
        message: 'The payment window could not be loaded.',
      );
    }

    final completer = Completer<CheckoutOutcome>();
    CheckoutOutcome? lastFailure;

    void finish(CheckoutOutcome outcome) {
      if (!completer.isCompleted) completer.complete(outcome);
    }

    // Ids and amounts only. No `prefill` — the PII rule (§7 rule 8). The
    // option names, retry policy and theme mirror checkout_adapter_io.dart.
    final options = _CheckoutOptions()
      ..key = keyId
      ..currency = 'INR'
      ..name = 'Mirage Menu'
      ..description = description
      ..retry = (_RetryOptions()
        ..enabled = true
        ..maxCount = 3)
      ..theme = (_ThemeOptions()..color = kCheckoutThemeColor)
      ..handler = ((_SuccessResponse response) {
        final paymentId = response.paymentId;
        finish(paymentId == null || paymentId.isEmpty
            ? const CheckoutOutcome.failed(
                code: 'NO_PAYMENT_ID',
                message: 'The payment sheet closed without a payment id.',
              )
            : CheckoutOutcome.success(
                paymentId,
                orderId: response.orderId,
                subscriptionId: response.subscriptionId,
                signature: response.signature,
              ));
      }).toJS
      ..modal = (_ModalOptions()
        ..ondismiss = (() {
          // The overlay is gone. A success already finished this; otherwise
          // the last failed attempt is the answer, and no attempt at all is
          // the user closing the sheet.
          finish(lastFailure ?? const CheckoutOutcome.cancelled());
        }).toJS);

    // An autopay mandate is opened by `subscription_id` with NO amount (the
    // Razorpay plan carries the price); a one-time order by `order_id` and
    // its amount. Same split as checkout_adapter_io.dart.
    if (subscriptionId != null) {
      options.subscriptionId = subscriptionId;
    } else {
      options
        ..orderId = orderId ?? ''
        ..amount = amountPaise;
    }

    try {
      final checkout = _RazorpayCheckout(options);
      checkout.on('payment.failed', ((_FailureResponse response) {
        final error = response.error;
        lastFailure = CheckoutOutcome.failed(
          code: error?.code ?? 'UNKNOWN_ERROR',
          message: error?.description ?? 'The payment could not be completed.',
        );
      }).toJS);
      checkout.open();
    } catch (error) {
      // Rejected options, or a Razorpay-side throw before anything drew.
      finish(CheckoutOutcome.failed(
        code: 'SDK_OPEN_FAILED',
        message: 'The payment window could not be opened: $error',
      ));
    }

    return completer.future;
  }
}

// ── Loading checkout.js ─────────────────────────────────────────────────────

/// The in-flight (or finished) load, shared by every caller in this tab.
Future<void>? _checkoutJsLoad;

/// Resolves once `window.Razorpay` exists. Idempotent; a rejected load is
/// dropped from the memo so the next call injects the script again.
Future<void> _ensureCheckoutJs() {
  if (_isCheckoutJsLoaded) return Future<void>.value();
  return _checkoutJsLoad ??=
      _injectCheckoutJs().catchError((Object error, StackTrace stack) {
    _checkoutJsLoad = null;
    Error.throwWithStackTrace(error, stack);
  });
}

/// Test seam: the loader itself, so a browser test (`flutter test --platform
/// chrome`) can prove checkout.js really arrives and defines the global.
@visibleForTesting
Future<void> debugEnsureCheckoutJs() => _ensureCheckoutJs();

/// Test seam: point the loader at another script (a URL that fails, or one
/// that loads without defining the global) and shorten the timeout. Null
/// restores the real value.
@visibleForTesting
void debugOverrideCheckoutJs({String? url, Duration? timeout}) {
  _checkoutJsUrl = url ?? kRazorpayCheckoutJsUrl;
  _checkoutJsLoadTimeout = timeout ?? kCheckoutJsLoadTimeout;
}

Future<void> _injectCheckoutJs() {
  final completer = Completer<void>();
  final parent = web.document.head ?? web.document.body;
  if (parent == null) {
    completer.completeError(
      StateError('No document to attach checkout.js to.'),
    );
    return completer.future;
  }

  final script = web.HTMLScriptElement()
    ..src = _checkoutJsUrl
    ..async = true;
  Timer? timeout;

  // First answer wins: a load that lands after the timeout is ignored (the
  // tag is gone), and the next tap re-injects.
  void fail(String reason) {
    timeout?.cancel();
    script.remove();
    if (!completer.isCompleted) completer.completeError(StateError(reason));
  }

  script.addEventListener(
    'load',
    ((web.Event _) {
      if (completer.isCompleted) return;
      if (_isCheckoutJsLoaded) {
        timeout?.cancel();
        completer.complete();
      } else {
        // Served something that was not checkout.js (a captive portal, say).
        fail('checkout.js loaded but did not define window.Razorpay.');
      }
    }).toJS,
  );
  script.addEventListener(
    'error',
    ((web.Event _) => fail('checkout.js could not be fetched.')).toJS,
  );
  timeout = Timer(
    _checkoutJsLoadTimeout,
    () => fail('checkout.js did not load in time.'),
  );
  parent.append(script);
  return completer.future;
}

// ── JS interop ──────────────────────────────────────────────────────────────
//
// Typed views over the objects checkout.js hands out and takes in. Razorpay's
// snake_case keys are renamed at the member so the Dart side stays lint-clean.

/// `window.Razorpay` — defined once checkout.js has evaluated, undefined
/// (→ null) before.
@JS('Razorpay')
external JSAny? get _razorpayGlobal;

bool get _isCheckoutJsLoaded => _razorpayGlobal != null;

/// `new Razorpay(options)` and the two members this adapter drives.
@JS('Razorpay')
extension type _RazorpayCheckout._(JSObject _) implements JSObject {
  external _RazorpayCheckout(_CheckoutOptions options);
  external void open();
  external void on(String event, JSFunction handler);
}

/// The options object literal.
extension type _CheckoutOptions._(JSObject _) implements JSObject {
  _CheckoutOptions() : this._(JSObject());
  external set key(String value);
  @JS('order_id')
  external set orderId(String value);
  @JS('subscription_id')
  external set subscriptionId(String value);
  external set amount(int value);
  external set currency(String value);
  external set name(String value);
  external set description(String value);
  external set handler(JSFunction value);
  external set modal(_ModalOptions value);
  external set retry(_RetryOptions value);
  external set theme(_ThemeOptions value);
}

extension type _ModalOptions._(JSObject _) implements JSObject {
  _ModalOptions() : this._(JSObject());
  external set ondismiss(JSFunction value);
}

extension type _RetryOptions._(JSObject _) implements JSObject {
  _RetryOptions() : this._(JSObject());
  external set enabled(bool value);
  @JS('max_count')
  external set maxCount(int value);
}

extension type _ThemeOptions._(JSObject _) implements JSObject {
  _ThemeOptions() : this._(JSObject());
  external set color(String value);
}

/// What `handler` receives: `{ razorpay_payment_id, razorpay_order_id,
/// razorpay_signature }` for an order, or `razorpay_subscription_id` in
/// place of the order id for an autopay mandate. All are handed to the
/// server as-is; the signature is the SERVER's to verify, never the client's.
extension type _SuccessResponse._(JSObject _) implements JSObject {
  @JS('razorpay_payment_id')
  external String? get paymentId;
  @JS('razorpay_order_id')
  external String? get orderId;
  @JS('razorpay_subscription_id')
  external String? get subscriptionId;
  @JS('razorpay_signature')
  external String? get signature;
}

/// What `payment.failed` receives: `{ error: { code, description, source,
/// step, reason, metadata } }`.
extension type _FailureResponse._(JSObject _) implements JSObject {
  external _FailureError? get error;
}

extension type _FailureError._(JSObject _) implements JSObject {
  external String? get code;
  external String? get description;
}
