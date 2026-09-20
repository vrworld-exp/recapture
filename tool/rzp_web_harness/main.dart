// tool/rzp_web_harness/main.dart
//
// A browser harness for the web checkout adapter, for when
// `flutter test --platform chrome` cannot run (it is broken on Windows in
// Flutter 3.41: the tool's CanvasKit handler compares a backslash path
// against 'canvaskit/' and 404s). Same scenarios as
// test/catalog/web/checkout_adapter_web_test.dart, driven by hand:
//
//     flutter build web -t tool/rzp_web_harness/main.dart -o build/rzp_harness
//     (serve build/rzp_harness, open it, read the console / the page body)
//
// ignore_for_file: invalid_use_of_visible_for_testing_member
//
// Every line is `PASS <name>` or `FAIL <name>: <why>`, and the last line is
// `HARNESS DONE <passed>/<total>`.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/widgets.dart';
import 'package:recapture/application/catalog/checkout_adapter.dart'
    hide kCanCheckoutInApp;
import 'package:recapture/application/catalog/checkout_adapter_web.dart';
import 'package:web/web.dart' as web;

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
  failRaw: function () { window.__rzp.last.handlers['payment.failed']({}); },
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
@JS('__rzpFire.failRaw')
external void _fireFailRaw();
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

int _passed = 0;
int _total = 0;

void _report(String line) {
  web.console.log(line.toJS);
  final p = web.document.createElement('pre')..textContent = line;
  web.document.body?.append(p);
}

void _check(String name, bool ok, [String why = '']) {
  _total++;
  if (ok) {
    _passed++;
    _report('PASS $name');
  } else {
    _report('FAIL $name: $why');
  }
}

Future<Future<CheckoutOutcome>> _openSheet(CheckoutAdapter adapter) async {
  final outcome = adapter.open(
    keyId: 'rzp_test_key',
    orderId: 'order_ABC123',
    amountPaise: 119900,
    description: 'Growth plan · monthly',
  );
  for (var i = 0; i < 20 && !_opened(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  return outcome;
}

Future<void> _run() async {
  // ── 1. The scripted Razorpay for the outcome mapping ───────────────────
  // The fake goes FIRST: the real checkout.js installs window.Razorpay as a
  // property that cannot be reassigned, so once it is on the page nothing
  // can stand in for it.
  _check('page starts without window.Razorpay',
      globalContext.getProperty<JSAny?>('Razorpay'.toJS) == null);
  web.document.head!.append(web.HTMLScriptElement()..text = _fakeRazorpayJs);

  final adapter = createPlatformCheckoutAdapter();
  _check('web half is RazorpayWebCheckoutAdapter and supported',
      adapter is RazorpayWebCheckoutAdapter && adapter.isSupported);
  _check('kCanCheckoutInApp is true on web', kCanCheckoutInApp);

  // options
  {
    final outcome = await _openSheet(adapter);
    _check('rzp.open() called', _opened());
    _check('payment.failed subscribed', _hasFailedListener());
    final options = _optionsJson();
    for (final fragment in const [
      '"key":"rzp_test_key"',
      '"order_id":"order_ABC123"',
      '"amount":119900',
      '"currency":"INR"',
      '"name":"Mirage Menu"',
      '"description":"Growth plan · monthly"',
      '"retry":{"enabled":true,"max_count":3}',
      '"theme":{"color":"#C9A24D"}',
      '"handlerType":"function"',
      '"ondismissType":"function"',
    ]) {
      _check('options contain $fragment', options.contains(fragment), options);
    }
    _check('options contain no prefill (PII rule)',
        !options.contains('prefill'), options);
    _fireDismiss();
    _check('dismiss with no attempt → cancelled',
        await outcome is CheckoutCancelled);
  }

  // success
  {
    final outcome = await _openSheet(adapter);
    _fireSuccess('pay_29QQoUBi66xm2f');
    final r = await outcome;
    _check('handler with id → success(paymentId)',
        r is CheckoutSuccess && r.paymentId == 'pay_29QQoUBi66xm2f', '$r');
  }

  // empty id
  {
    final outcome = await _openSheet(adapter);
    _fireSuccess('');
    final r = await outcome;
    _check('handler with empty id → failed NO_PAYMENT_ID',
        r is CheckoutFailed && r.code == 'NO_PAYMENT_ID', '$r');
  }

  // failure only decided on close
  {
    final outcome = await _openSheet(adapter);
    _fireFail('BAD_REQUEST_ERROR', 'Card declined');
    var decided = false;
    unawaited(outcome.then((_) => decided = true));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    _check('a failed attempt does NOT decide while overlay is open', !decided);
    _fireDismiss();
    final r = await outcome;
    _check(
        'failed attempt then dismiss → failed(code, message)',
        r is CheckoutFailed &&
            r.code == 'BAD_REQUEST_ERROR' &&
            r.message == 'Card declined',
        '$r');
  }

  // last failure wins
  {
    final outcome = await _openSheet(adapter);
    _fireFail('BAD_REQUEST_ERROR', 'Card declined');
    _fireFail('GATEWAY_ERROR', 'Bank timed out');
    _fireDismiss();
    final r = await outcome;
    _check('the LAST failed attempt wins',
        r is CheckoutFailed && r.code == 'GATEWAY_ERROR', '$r');
  }

  // retry success
  {
    final outcome = await _openSheet(adapter);
    _fireFail('BAD_REQUEST_ERROR', 'Card declined');
    _fireSuccess('pay_retry_ok');
    final r = await outcome;
    _check('success after a failed attempt → success (retry)',
        r is CheckoutSuccess && r.paymentId == 'pay_retry_ok', '$r');
    _fireDismiss();
    _check('late ondismiss does not flip a decided outcome',
        identical(await outcome, r));
  }

  // raw failure payload
  {
    final outcome = await _openSheet(adapter);
    _fireFailRaw();
    _fireDismiss();
    final r = await outcome;
    _check('failure payload without error → UNKNOWN_ERROR',
        r is CheckoutFailed && r.code == 'UNKNOWN_ERROR', '$r');
  }

  // open throws
  {
    _setFailOpen(true);
    try {
      final r = await adapter
          .open(keyId: 'k', orderId: 'o', amountPaise: 1, description: 'd')
          .timeout(const Duration(seconds: 5));
      _check('rzp.open() throwing → failed SDK_OPEN_FAILED (no hang)',
          r is CheckoutFailed && r.code == 'SDK_OPEN_FAILED', '$r');
    } catch (e) {
      _check('rzp.open() throwing → failed SDK_OPEN_FAILED (no hang)', false,
          '$e');
    } finally {
      _setFailOpen(false);
    }
  }

  // fresh instance per open
  {
    final n = _count();
    final a = await _openSheet(adapter);
    _fireDismiss();
    await a;
    final b = await _openSheet(adapter);
    _fireDismiss();
    await b;
    _check('every open() builds a fresh Razorpay instance', _count() == n + 2);
  }

  // ── 2. The REAL checkout.js, through the adapter's own loader ──────────
  globalContext.delete('Razorpay'.toJS);
  _check('fake removed before loading the real script',
      globalContext.getProperty<JSAny?>('Razorpay'.toJS) == null);
  try {
    await debugEnsureCheckoutJs().timeout(const Duration(seconds: 30));
    final global = globalContext.getProperty<JSAny?>('Razorpay'.toJS);
    _check('real checkout.js fetched and window.Razorpay defined',
        global != null && global.typeofEquals('function'));
    final sw = Stopwatch()..start();
    await debugEnsureCheckoutJs();
    _check('second ensure is a memo hit (<50ms)', sw.elapsedMilliseconds < 50,
        '${sw.elapsedMilliseconds}ms');

    // Open the REAL sheet for our options. The key is not a real one, so
    // Razorpay will show its own error inside the overlay — but the overlay
    // itself appearing proves the real SDK accepted the options object the
    // adapter builds (new Razorpay(options).open()).
    unawaited(adapter.open(
      keyId: 'rzp_test_harness_key',
      orderId: 'order_harness',
      amountPaise: 119900,
      description: 'Growth plan · monthly',
    ));
    var frameSrc = '';
    for (var i = 0; i < 100 && frameSrc.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final frames = web.document.querySelectorAll('iframe');
      for (var f = 0; f < frames.length; f++) {
        final src = (frames.item(f) as web.HTMLIFrameElement).src;
        if (src.contains('razorpay')) frameSrc = src;
      }
    }
    _check('real Razorpay checkout overlay rendered for our options',
        frameSrc.isNotEmpty, 'no razorpay iframe within 10s');
    _report('real overlay iframe: ${frameSrc.split('?').first}');
  } catch (e) {
    _check('real checkout.js fetched and window.Razorpay defined', false, '$e');
  }

  _report('HARNESS DONE $_passed/$_total');
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(_run());
}
