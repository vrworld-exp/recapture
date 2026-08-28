// lib/application/catalog/qr_delivery_io.dart
//
// Native QR delivery: write the bytes to a temp file and hand it to the
// platform share sheet, so the user saves it to Files / Photos / Downloads or
// sends it straight to whoever is printing the stickers.
//
// The share sheet IS the product-approved "download" on mobile (the same
// mechanism as the staff preview gallery and the model export): it adds no
// plugin beyond the share_plus already in the tree, and needs no storage
// permission, so it never touches the native permission facade.
//
// The bytes are already in memory — they came from an authenticated GET, not a
// presigned link — so unlike the preview-gallery path there is nothing to fetch
// here.
import 'dart:io';

import 'package:share_plus/share_plus.dart';

import 'qr_download_file.dart';

Future<void> deliverQr(QrDownloadFile file) async {
  final dir = (await Directory.systemTemp.createTemp('recapture_qr')).path;
  // Filename-safe already (the repository sanitises what the server sent), but
  // the join is done here so the temp directory is this function's business and
  // nobody else's.
  final path = '$dir/${file.fileName}';
  await File(path).writeAsBytes(file.bytes, flush: true);

  await SharePlus.instance.share(ShareParams(
    files: [XFile(path, mimeType: file.mimeType)],
    subject: file.fileName,
  ));
}
