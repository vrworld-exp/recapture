// test/catalog/web/checkout_js_blocked_test.dart
//
// checkout.js blocked (an ad blocker, an offline tab, a captive portal):
//
//     flutter test --platform chrome test/catalog/web
//
// The adapter must ANSWER — a retryable SDK_UNAVAILABLE, never a Pay button
// that spins forever — and the next tap must inject the script again rather
// than remember the failure. In its own file so the page starts with no
// `window.Razorpay` (the sibling suite installs a fake one).
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/catalog/checkout_adapter.dart'
    hide kCanCheckoutInApp;
import 'package:recapture/application/catalog/checkout_adapter_web.dart';
import 'package:web/web.dart' as web;

JSAny? get _razorpayGlobal => globalContext.getProperty('Razorpay'.toJS);

/// Nothing listens on the discard port: the fetch is refused at once, the
/// way a blocker's ERR_BLOCKED_BY_CLIENT is.
const String _refusedUrl = 'http://127.0.0.1:9/checkout.js';

/// Loads fine but is not checkout.js — a captive portal's page, say.
const String _wrongScriptUrl = 'data:text/javascript,void%200';

/// A stand-in checkout.js that defines the global.
const String _workingUrl =
    'data:text/javascript,window.Razorpay%3Dfunction(o)%7Bthis.o%3Do%7D%3B'
    'window.Razorpay.prototype.on%3Dfunction()%7B%7D%3B'
    'window.Razorpay.prototype.open%3Dfunction()%7B%7D%3B';

int _scriptTags(String url) =>
    web.document.querySelectorAll('script[src="$url"]').length;

Future<CheckoutOutcome> _open() => const RazorpayWebCheckoutAdapter()
    .open(keyId: 'k', orderId: 'order_x', amountPaise: 300, description: 'd')
    .timeout(const Duration(seconds: 10));

void main() {
  tearDown(debugOverrideCheckoutJs);

  test('a refused fetch answers SDK_UNAVAILABLE — no hang, no leftover tag',
      () async {
    expect(_razorpayGlobal, isNull);
    debugOverrideCheckoutJs(url: _refusedUrl);

    final result = await _open();

    expect(result, isA<CheckoutFailed>());
    expect((result as CheckoutFailed).code, 'SDK_UNAVAILABLE');
    expect(_scriptTags(_refusedUrl), 0);
  });

  test('a script that does not define window.Razorpay is also unavailable',
      () async {
    debugOverrideCheckoutJs(url: _wrongScriptUrl);

    final result = await _open();

    expect((result as CheckoutFailed).code, 'SDK_UNAVAILABLE');
    expect(_scriptTags(_wrongScriptUrl), 0);
  });

  test('a fetch that never answers times out instead of spinning', () async {
    // A stalled fetch cannot be staged reliably here, so a zero timeout
    // fires before the refused fetch reports: the timer path answers first.
    debugOverrideCheckoutJs(url: _refusedUrl, timeout: Duration.zero);

    final result = await _open();

    expect((result as CheckoutFailed).code, 'SDK_UNAVAILABLE');
    expect(_scriptTags(_refusedUrl), 0);
  });

  test('the next tap injects the script again and succeeds', () async {
    debugOverrideCheckoutJs(url: _refusedUrl);
    expect(await _open(), isA<CheckoutFailed>());
    expect(_razorpayGlobal, isNull);

    // The blocker is switched off; the failure was not memoised.
    debugOverrideCheckoutJs(url: _workingUrl);
    await debugEnsureCheckoutJs().timeout(const Duration(seconds: 10));

    expect(_razorpayGlobal, isNotNull);
    expect(_scriptTags(_workingUrl), 1);
  });
}
