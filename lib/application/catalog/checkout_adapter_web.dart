// lib/application/catalog/checkout_adapter_web.dart
//
// The browser half of the checkout seam. `razorpay_flutter` is Android/iOS
// only (README C7), so the web build offers no SDK at all: the screen shows
// "Pay from the ReCapture app on your phone" instead of a button that would
// open nothing. Web checkout is deferred, not forgotten.
import 'checkout_adapter.dart';

/// No in-app checkout in a browser.
const bool kCanCheckoutInApp = false;

CheckoutAdapter createPlatformCheckoutAdapter() =>
    const UnsupportedCheckoutAdapter();
