// lib/application/catalog/catalog_qr_service.dart
//
// "Save this QR code", split by platform.
//
// ONE repository method fetches the bytes; TWO presentation paths do something
// with them — the share sheet on mobile, a blob download in the browser. This
// is the one place in the catalog surface where `kIsWeb` (via a conditional
// import, which is the compile-time form of it) is the right tool: it is a
// genuine CAPABILITY difference, not a layout one. There is no share sheet in a
// browser and no `<a download>` on a phone.
//
// Behind a seam so widget tests can assert "saved exactly once, with THESE
// bytes" without touching the share sheet or the DOM.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'qr_delivery_stub.dart'
    if (dart.library.io) 'qr_delivery_io.dart'
    if (dart.library.js_interop) 'qr_delivery_web.dart';
import 'qr_download_file.dart';

export 'qr_download_file.dart';

/// Seam over "put this QR file in the user's hands".
abstract interface class QrDeliverer {
  Future<void> deliver(QrDownloadFile file);
}

/// Production [QrDeliverer]: delegates to the conditionally-imported,
/// per-platform delivery ([deliverQr]).
class PlatformQrDeliverer implements QrDeliverer {
  const PlatformQrDeliverer();

  @override
  Future<void> deliver(QrDownloadFile file) => deliverQr(file);
}

/// App-wide QR deliverer. Overridden with a fake in tests.
final qrDelivererProvider = Provider<QrDeliverer>(
  (ref) => const PlatformQrDeliverer(),
);
