// lib/application/catalog/checkout_adapter_stub.dart
//
// The default half of the checkout seam — selected when neither `dart:io` nor
// `dart:js_interop` is available. No SDK, so nothing can open.
import 'checkout_adapter.dart';

/// No in-app checkout on an unknown target.
const bool kCanCheckoutInApp = false;

CheckoutAdapter createPlatformCheckoutAdapter() =>
    const UnsupportedCheckoutAdapter();
