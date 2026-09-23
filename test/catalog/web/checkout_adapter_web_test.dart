// test/catalog/web/checkout_adapter_web_test.dart
//
// The web checkout adapter, driven in a REAL browser:
//
//     flutter test --platform chrome test/catalog/web
//
// `checkout_adapter_web.dart` is dart:js_interop against Razorpay's
// Checkout.js, and js_interop has no VM. Property names, `.toJS` callbacks and
// `new Razorpay(...)` are only checked when JavaScript actually runs them, so
// this suite is browser-only (`@TestOn`) and skipped by the plain
// `flutter test` CI runs.
//
// A scripted `window.Razorpay` stands in for checkout.js. It records the
// options object the adapter hands it and exposes triggers for the three
// things the real one does — call `handler`, fire `payment.failed`, call
// `modal.ondismiss` — so every outcome mapping in the adapter is exercised
// exactly the way Razorpay's JavaScript would exercise it.
@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/catalog/checkout_adapter.dart'
    hide kCanCheckoutInApp;
import 'package:recapture/application/catalog/checkout_adapter_web.dart';
import 'package:web/web.dart' as web;

// ── The scripted Razorpay ───────────────────────────────────────────────────

const String _fakeRazorpayJs = r'''
window.__rzp = { instances: [], failOpen: false };
window.Razorpay = function (options) {
  this.options = options;
  this.handlers = {};
  this.opened = false;
  window.__rzp.instances.push(this);
  window.__rzp.last = this;
};
window.Razorpay.prototype.on = function (event, cb) { this.handlers[event] = cb; };
window.Razorpay.prototype.open = function () {
  if (window.__rzp.failOpen) throw new Error('scripted open failure');
  this.opened = true;
};
window.__rzpFire = {
  success: function (id) {
    window.__rzp.last.options.handler({
      razorpay_payment_id: id,
      razorpay_order_id: window.__rzp.last.options.order_id,
      razorpay_signature: 'sig'
    });
  },
  fail: function (code, description) {
    window.__rzp.last.handlers['payment.failed']({
      error: { code: code, description: description, reason: 'r', step: 's', source: 'x' }
    });
  },
  dismiss: function () { window.__rzp.last.options.modal.ondismiss(); },
  optionsJson: function () {
    var o = Object.assign({}, window.__rzp.last.options);
    o.handlerType = typeof o.handler; delete o.handler;
    o.ondismissType = typeof (o.modal && o.modal.ondismiss); delete o.modal;
    return JSON.stringify(o);
  },
  opened: function () { return !!(window.__rzp.last && window.__rzp.last.opened); },
  count: function () { return window.__rzp.instances.length; },
  setFailOpen: function (on) { window.__rzp.failOpen = on; },
  hasFailedListener: function () { return typeof window.__rzp.last.handlers['payment.failed'] === 'function'; }
};
''';

@JS('__rzpFire.success')
external void _fireSuccess(String paymentId);
@JS('__rzpFire.fail')
external void _fireFail(String code, String description);
@JS('__rzpFire.dismiss')
external void _fireDismiss();
@JS('__rzpFire.optionsJson')
external String _optionsJson();
@JS('__rzpFire.opened')
external bool _opened();
@JS('__rzpFire.count')
external int _count();
@JS('__rzpFire.setFailOpen')
external void _setFailOpen(bool on);
@JS('__rzpFire.hasFailedListener')
external bool _hasFailedListener();

void _installFakeRazorpay() {
  final script = web.HTMLScriptElement()..text = _fakeRazorpayJs;
  web.document.head!.append(script);
}

/// Opens the sheet and waits until the fake says `open()` was called, which
/// happens after the adapter's (already-resolved) loader await.
Future<Future<CheckoutOutcome>> _openSheet(
  RazorpayWebCheckoutAdapter adapter, {
  String keyId = 'rzp_test_key',
  String orderId = 'order_ABC123',
  int amountPaise = 119900,
  String description = 'Growth plan · monthly',
}) async {
  final outcome = adapter.open(
    keyId: keyId,
    orderId: orderId,
    amountPaise: amountPaise,
    description: description,
  );
  // Let the loader's Future.value() and the constructor run.
  for (var i = 0; i < 20 && !_opened(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  return outcome;
}

void main() {
  setUpAll(_installFakeRazorpay);

  const adapter = RazorpayWebCheckoutAdapter();

  test('the web half says it can check out', () {
    expect(kCanCheckoutInApp, isTrue);
    expect(adapter.isSupported, isTrue);
    expect(createPlatformCheckoutAdapter(), isA<RazorpayWebCheckoutAdapter>());
  });

  test('new Razorpay(...) receives the order, the key and nothing personal',
      () async {
    final outcome = await _openSheet(adapter);
    expect(_opened(), isTrue, reason: 'rzp.open() must have been called');
    expect(_hasFailedListener(), isTrue,
        reason: 'payment.failed must be subscribed');

    final options = _optionsJson();
    for (final fragment in const [
      '"key":"rzp_test_key"',
      '"order_id":"order_ABC123"',
      '"amount":119900',
      '"currency":"INR"',
      '"name":"Mirage Menu"',
      '"description":"Growth plan · monthly"',
      '"retry":{"enabled":true,"max_count":3}',
      '"theme":{"color":"#E10600"}',
      '"handlerType":"function"',
      '"ondismissType":"function"',
    ]) {
      expect(options, contains(fragment), reason: 'options were: $options');
    }
    // The PII rule: no prefill of contact/email, ever.
    expect(options, isNot(contains('prefill')));

    _fireDismiss();
    expect(await outcome, isA<CheckoutCancelled>());
  });

  test('handler with a payment id → success', () async {
    final outcome = await _openSheet(adapter);
    _fireSuccess('pay_29QQoUBi66xm2f');
    final result = await outcome;
    expect(result, isA<CheckoutSuccess>());
    expect((result as CheckoutSuccess).paymentId, 'pay_29QQoUBi66xm2f');
  });

  test('handler without a payment id → failed NO_PAYMENT_ID', () async {
    final outcome = await _openSheet(adapter);
    _fireSuccess('');
    final result = await outcome;
    expect(result, isA<CheckoutFailed>());
    expect((result as CheckoutFailed).code, 'NO_PAYMENT_ID');
  });

  test('closing the overlay with no attempt → cancelled', () async {
    final outcome = await _openSheet(adapter);
    _fireDismiss();
    expect(await outcome, isA<CheckoutCancelled>());
  });

  test('a failed attempt is reported only when the overlay closes', () async {
    final outcome = await _openSheet(adapter);
    _fireFail('BAD_REQUEST_ERROR', 'Card declined');

    // Still open: the user may retry. Nothing has been decided yet.
    var decided = false;
    unawaited(outcome.then((_) => decided = true));
    await Future<void>.delayed(Duration.zero);
    expect(decided, isFalse);

    _fireDismiss();
    final result = await outcome;
    expect(result, isA<CheckoutFailed>());
    expect((result as CheckoutFailed).code, 'BAD_REQUEST_ERROR');
    expect(result.message, 'Card declined');
  });

  test('the LAST failed attempt wins when several happen', () async {
    final outcome = await _openSheet(adapter);
    _fireFail('BAD_REQUEST_ERROR', 'Card declined');
    _fireFail('GATEWAY_ERROR', 'Bank timed out');
    _fireDismiss();
    final result = await outcome as CheckoutFailed;
    expect(result.code, 'GATEWAY_ERROR');
    expect(result.message, 'Bank timed out');
  });

  test('a success after a failed attempt is still a success (retry)',
      () async {
    final outcome = await _openSheet(adapter);
    _fireFail('BAD_REQUEST_ERROR', 'Card declined');
    _fireSuccess('pay_retry_ok');
    final result = await outcome;
    expect(result, isA<CheckoutSuccess>());
    expect((result as CheckoutSuccess).paymentId, 'pay_retry_ok');

    // Razorpay may still call ondismiss as the overlay goes away — the
    // decision must not flip.
    _fireDismiss();
    expect(await outcome, same(result));
  });

  test('a failure payload with no error object → UNKNOWN_ERROR', () async {
    final outcome = await _openSheet(adapter);
    // Bypass the helper: fire with an empty object, as a defensive check.
    _fireRawFailure();
    _fireDismiss();
    final result = await outcome as CheckoutFailed;
    expect(result.code, 'UNKNOWN_ERROR');
  });

  test('rzp.open() throwing → failed SDK_OPEN_FAILED, no hang', () async {
    _setFailOpen(true);
    try {
      final result = await adapter
          .open(
            keyId: 'k',
            orderId: 'o',
            amountPaise: 1,
            description: 'd',
          )
          .timeout(const Duration(seconds: 5));
      expect(result, isA<CheckoutFailed>());
      expect((result as CheckoutFailed).code, 'SDK_OPEN_FAILED');
    } finally {
      _setFailOpen(false);
    }
  });

  test('every open() builds a fresh Razorpay instance', () async {
    final before = _count();
    final a = await _openSheet(adapter);
    _fireDismiss();
    await a;
    final b = await _openSheet(adapter);
    _fireDismiss();
    await b;
    expect(_count(), before + 2);
  });
}

@JS('__rzp.last.handlers')
external JSObject get _lastHandlers;

/// Fires `payment.failed` with `{}` — no `error` — straight from Dart.
void _fireRawFailure() {
  final handler = _lastHandlers.getProperty<JSFunction>('payment.failed'.toJS);
  handler.callAsFunction(null, JSObject());
}
