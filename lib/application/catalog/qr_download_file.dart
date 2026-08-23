// lib/application/catalog/qr_download_file.dart
//
// One QR file on its way to the user, as handed to the [QrDeliverer] seam.
//
// In its own file, not beside the service: the per-platform delivery variants
// import this type, and the service conditionally imports THEM — putting the
// type in the service would make that a cycle. Same reason
// `model_export_file.dart` exists.
import 'package:flutter/foundation.dart' show Uint8List;

class QrDownloadFile {
  const QrDownloadFile({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
  });

  /// The rendered QR. BYTES rather than a URL because the endpoint that
  /// produced them needs the Bearer token — there is no link a browser could
  /// simply navigate to.
  final Uint8List bytes;

  /// The server's own filename, slugged from the catalog name.
  final String fileName;

  /// `image/png` or `application/pdf`.
  final String mimeType;
}
