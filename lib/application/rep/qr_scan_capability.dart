// lib/application/rep/qr_scan_capability.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether this build can scan a QR code with the camera.
///
/// ⚠ A CAPABILITY FLAG, READ THROUGH A PROVIDER — NEVER `kIsWeb`.
///
/// Camera scanning does not exist in a browser build, so the Scan affordance
/// has to be conditional. Branching on `kIsWeb` would make it untestable: the
/// untaken half of a compile-time branch is not in the test binary at all, so
/// the mobile rendering could never be asserted from the one `flutter test` run
/// CI does. It would also fail the structural guard in
/// `test/catalog/web_parity_test.dart`, which exists for exactly this. Driving
/// it through a provider means ONE widget test asserts BOTH platforms.
///
/// [canScan] is false today ON BOTH TARGETS, and that is a real answer rather
/// than a placeholder: there is no in-app scanner yet, and adding one means
/// adding a package — which the standing constraints require a stated reason
/// for. The reason is weaker than it looks, because a rep's OS camera already
/// scans the standee and lands on the resolver's "not live yet" page, which
/// carries a one-tap activation link straight into this app.
///
/// Stage 10 supplies the real per-platform flag behind a conditional import
/// (the shape `catalog_link_service.dart` already uses) and settles the
/// deep-link question. This provider is the seam it plugs into; screens are
/// written against it now so nothing has to move then.
class QrScanCapability {
  const QrScanCapability({required this.canScan});

  /// Whether to OFFER the Scan button at all.
  ///
  /// HIDDEN, never disabled, when false. A disabled button on web is a promise
  /// the browser can never keep, and it invites a rep to keep tapping it; the
  /// screen simply leads with manual entry instead, which is present on every
  /// target and is the fallback a damaged or badly-lit sticker needs anyway.
  final bool canScan;

  /// No in-app scanner in this build. See the class doc.
  static const unavailable = QrScanCapability(canScan: false);
}

/// The scan affordance's capability. Overridden in tests to assert both
/// renderings, and by stage 10 to report the real per-platform answer.
final qrScanCapabilityProvider = Provider<QrScanCapability>(
  (ref) => QrScanCapability.unavailable,
);
