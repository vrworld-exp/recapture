// lib/application/catalog/checkout_adapter.dart
//
// The in-app payment sheet, behind a seam.
//
// Razorpay ships two clients and neither runs everywhere: the native SDK
// (`razorpay_flutter`) exists for Android and iOS only, and Checkout.js only
// in a browser. So each lives in its own half — `checkout_adapter_io.dart`
// and `checkout_adapter_web.dart` — selected by conditional import, the same
// shape as `rep_capabilities*.dart`, for the same two reasons: neither half
// is compiled into the other target's build, and one widget test can drive
// every rendering by overriding the provider. Desktop (the stub, and an io
// build on a desktop OS) has no client at all and answers "unsupported".
//
// WHAT THE ADAPTER DOES NOT DECIDE. It opens a sheet for an order the server
// already minted and reports what the SDK said. It never activates anything:
// `success(paymentId)` means "the SDK reported success", and the notifier
// then POLLS the subscription until the server — told by Razorpay's webhook —
// says ACTIVE (§7 rule 1). A payment is real when the server says so.
import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import 'checkout_adapter_stub.dart'
    if (dart.library.io) 'checkout_adapter_io.dart'
    if (dart.library.js_interop) 'checkout_adapter_web.dart';

export 'checkout_adapter_stub.dart'
    if (dart.library.io) 'checkout_adapter_io.dart'
    if (dart.library.js_interop) 'checkout_adapter_web.dart'
    show kCanCheckoutInApp;

/// The sheet's `theme.color` — Razorpay paints its header and Pay button
/// with it, so it is the CTA colour ([AppColors.mirageRed]), not royalGold.
/// Derived from the token so the hex lives only in app_colors.dart.
final String kCheckoutThemeColor =
    '#${(AppColors.mirageRed.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// What the SDK reported. Sealed so the notifier's switch is exhaustive.
@immutable
sealed class CheckoutOutcome {
  const CheckoutOutcome();

  const factory CheckoutOutcome.success(String paymentId) = CheckoutSuccess;
  const factory CheckoutOutcome.cancelled() = CheckoutCancelled;
  const factory CheckoutOutcome.failed({
    required String code,
    required String message,
  }) = CheckoutFailed;
  const factory CheckoutOutcome.unsupported() = CheckoutUnsupported;
}

/// The SDK says the payment went through. NOT an activation — see the header.
class CheckoutSuccess extends CheckoutOutcome {
  const CheckoutSuccess(this.paymentId);
  final String paymentId;
}

/// The user closed the sheet. The open order stays open on the server.
class CheckoutCancelled extends CheckoutOutcome {
  const CheckoutCancelled();
}

/// The SDK reported a failure. [code] is the SDK's own numeric code as text,
/// [message] its sentence — shown as-is only in debug; the screen has its own.
class CheckoutFailed extends CheckoutOutcome {
  const CheckoutFailed({required this.code, required this.message});
  final String code;
  final String message;
}

/// No SDK on this target (desktop).
class CheckoutUnsupported extends CheckoutOutcome {
  const CheckoutUnsupported();
}

/// Opens the payment sheet for one server-minted order.
abstract interface class CheckoutAdapter {
  /// Whether [open] can do anything here. False → the screen shows the
  /// "pay from your phone or browser" card and never calls [open].
  bool get isSupported;

  /// [description] is "`<Plan>` plan · monthly/yearly". Deliberately no
  /// `prefill` argument: the SDK's `prefill.contact` / `prefill.email` are
  /// never sent (PII rule, §7 rule 8).
  Future<CheckoutOutcome> open({
    required String keyId,
    required String orderId,
    required int amountPaise,
    required String description,
  });
}

/// The adapter for a target with no SDK. Also what tests start from.
class UnsupportedCheckoutAdapter implements CheckoutAdapter {
  const UnsupportedCheckoutAdapter();

  @override
  bool get isSupported => false;

  @override
  Future<CheckoutOutcome> open({
    required String keyId,
    required String orderId,
    required int amountPaise,
    required String description,
  }) async =>
      const CheckoutOutcome.unsupported();
}

/// The platform's adapter. Overridden in tests with a scripted fake.
final checkoutAdapterProvider = Provider<CheckoutAdapter>(
  (ref) => createPlatformCheckoutAdapter(),
);
