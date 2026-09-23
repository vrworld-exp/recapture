// lib/application/catalog/checkout_adapter_io.dart
//
// The native half of the checkout seam: `razorpay_flutter`, opened INSIDE the
// app (AC-7.2 — no browser tab, no WebView of our own, no url_launcher).
//
// `dart:io` is allowed here and nowhere else in this feature. The flag says
// the SDK is COMPILED IN; whether it can actually open is decided per OS at
// runtime by [createPlatformCheckoutAdapter], because the plugin ships for
// Android and iOS only and a desktop debug build has `dart:io` and no plugin
// — it must answer "unsupported" rather than hang on a channel nobody serves.
import 'dart:async';
import 'dart:io' show Platform;

import 'package:razorpay_flutter/razorpay_flutter.dart';

import 'checkout_adapter.dart';

/// The SDK is part of this build.
const bool kCanCheckoutInApp = true;

CheckoutAdapter createPlatformCheckoutAdapter() =>
    Platform.isAndroid || Platform.isIOS
        ? const RazorpayCheckoutAdapter()
        : const UnsupportedCheckoutAdapter();

/// One sheet per [open]: a fresh [Razorpay] instance is created, listened to,
/// and cleared when the sheet answers, so two checkouts in one session can
/// never cross their callbacks.
class RazorpayCheckoutAdapter implements CheckoutAdapter {
  const RazorpayCheckoutAdapter();

  @override
  bool get isSupported => true;

  @override
  Future<CheckoutOutcome> open({
    required String keyId,
    required String orderId,
    required int amountPaise,
    required String description,
  }) async {
    final razorpay = Razorpay();
    final completer = Completer<CheckoutOutcome>();

    void finish(CheckoutOutcome outcome) {
      if (!completer.isCompleted) completer.complete(outcome);
    }

    razorpay.on(Razorpay.EVENT_PAYMENT_SUCCESS, (PaymentSuccessResponse r) {
      final paymentId = r.paymentId;
      finish(paymentId == null || paymentId.isEmpty
          ? const CheckoutOutcome.failed(
              code: 'NO_PAYMENT_ID',
              message: 'The payment sheet closed without a payment id.',
            )
          : CheckoutOutcome.success(
              paymentId,
              orderId: r.orderId,
              signature: r.signature,
            ));
    });
    razorpay.on(Razorpay.EVENT_PAYMENT_ERROR, (PaymentFailureResponse r) {
      finish(r.code == Razorpay.PAYMENT_CANCELLED
          ? const CheckoutOutcome.cancelled()
          : CheckoutOutcome.failed(
              code: '${r.code ?? Razorpay.UNKNOWN_ERROR}',
              message: r.message ?? 'The payment could not be completed.',
            ));
    });
    // An external wallet hand-off leaves the app; the SDK will not report a
    // result for it. Treated as "we do not know" — the server reconciles.
    razorpay.on(Razorpay.EVENT_EXTERNAL_WALLET, (ExternalWalletResponse _) {
      finish(const CheckoutOutcome.failed(
        code: 'EXTERNAL_WALLET',
        message: 'The payment continued outside the app.',
      ));
    });

    try {
      // Ids and amounts only. No `prefill` — the PII rule.
      razorpay.open({
        'key': keyId,
        'order_id': orderId,
        'amount': amountPaise,
        'currency': 'INR',
        'name': 'Mirage Menu',
        'description': description,
        'retry': {'enabled': true, 'max_count': 3},
        'theme': {'color': kCheckoutThemeColor},
      });
      return await completer.future;
    } finally {
      razorpay.clear();
    }
  }
}
