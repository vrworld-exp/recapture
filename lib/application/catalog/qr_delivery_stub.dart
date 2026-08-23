// lib/application/catalog/qr_delivery_stub.dart
//
// Compile-time fallback for the platform-split QR delivery. The real
// implementation is chosen by conditional import in catalog_qr_service.dart:
// `dart:io` (native — temp file, then the share sheet) or `dart:js_interop`
// (web — a blob download). Only reachable on a hypothetical platform with
// neither library; it fails loudly rather than silently doing nothing, because
// a Download button that no-ops is worse than one that errors.
import 'qr_download_file.dart';

Future<void> deliverQr(QrDownloadFile file) =>
    throw UnsupportedError('Saving the QR code is not supported on this platform.');
