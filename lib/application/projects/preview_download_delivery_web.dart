// lib/application/projects/preview_download_delivery_web.dart
//
// Web preview download: trigger a real browser download by pointing a transient
// anchor at the presigned url. The export url is served by S3 with
// `Content-Disposition: attachment; filename="…"` (see the api's
// presignObjectGetUrl), so the browser saves it with the correct filename and
// content-type WITHOUT any XHR/blob byte fetch.
//
// Why not fetch the bytes into a Blob? The raw-captures bucket has no CORS
// policy, so a cross-origin fetch()/XHR of the object would be blocked by the
// browser. A plain navigation to a Content-Disposition url is not subject to
// CORS, so this path works with zero infra changes. (The old dart:io + temp
// file + share_plus path threw at runtime on web — path_provider/File are
// unsupported — which is why download was silently broken on the web build.)
//
// The presigned url is a bearer credential — it is never logged.
//
// This file is ONLY ever compiled for the web target (selected by the
// conditional import in preview_download_service.dart), so the web-library and
// deprecation lints are expected here.
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

import '../../domain/entities/preview_manifest.dart';

Future<void> deliverPreviewDownload(PreviewPhoto photo) async {
  final anchor = html.AnchorElement(href: photo.url)
    // Cross-origin browsers ignore this filename in favour of S3's
    // Content-Disposition, but it also signals "download, don't navigate".
    ..download = photo.fileName
    ..style.display = 'none';
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
}
