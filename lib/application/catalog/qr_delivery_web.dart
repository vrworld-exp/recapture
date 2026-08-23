// lib/application/catalog/qr_delivery_web.dart
//
// Web QR delivery: a real browser download of the bytes.
//
// A share sheet does not exist here, and the anchor-at-a-URL trick the preview
// gallery uses does not apply either — that works because S3 serves a presigned
// link with `Content-Disposition`, whereas the QR endpoint is ours and needs
// the Bearer token. So the bytes (already fetched by the repository) become a
// Blob, and the anchor points at an object URL for it.
//
// The object URL is revoked immediately after the click. It is a live reference
// to a Blob the browser is holding in memory, and leaking one per Download
// press keeps every QR the user has ever saved resident for the life of the
// tab.
//
// Written against package:web, not the deprecated dart:html. Only ever compiled
// for the web target — selected by the conditional import in
// catalog_qr_service.dart.
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'qr_download_file.dart';

Future<void> deliverQr(QrDownloadFile file) async {
  final blob = web.Blob(
    [file.bytes.toJS].toJS,
    web.BlobPropertyBag(type: file.mimeType),
  );
  final url = web.URL.createObjectURL(blob);

  final anchor = web.HTMLAnchorElement()
    ..href = url
    // Same-origin blob: URL, so the browser honours this filename — unlike the
    // cross-origin CDN downloads elsewhere in the app, where it is only a hint.
    ..download = file.fileName
    ..style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();

  web.URL.revokeObjectURL(url);
}
