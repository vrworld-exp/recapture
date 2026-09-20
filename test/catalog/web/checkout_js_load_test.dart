// test/catalog/web/checkout_js_load_test.dart
//
// The on-demand loader against the REAL checkout.js:
//
//     flutter test --platform chrome test/catalog/web
//
// Needs the network (it fetches https://checkout.razorpay.com/v1/checkout.js).
// In its own file so it gets its own page: the sibling suite installs a fake
// `window.Razorpay`, and this one must start with none.
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/catalog/checkout_adapter_web.dart';

JSAny? get _razorpayGlobal => globalContext.getProperty('Razorpay'.toJS);

void main() {
  test('checkout.js is fetched on demand and defines window.Razorpay',
      () async {
    expect(_razorpayGlobal, isNull,
        reason: 'the page must start without checkout.js');

    await debugEnsureCheckoutJs().timeout(const Duration(seconds: 30));

    final global = _razorpayGlobal;
    expect(global, isNotNull);
    expect(global!.typeofEquals('function'), isTrue,
        reason: 'window.Razorpay must be the constructor checkout.js exports');

    // A second call is a no-op on the memo, not a second download.
    await debugEnsureCheckoutJs().timeout(const Duration(seconds: 1));
  });
}
