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
// WRITTEN AGAINST `package:web`, like every other web seam in this tree
// (`model_export_delivery_web.dart` is the same anchor trick, line for line).
// It used to be `dart:html`, and its service selected it with
// `if (dart.library.html)` — the only seam here that did. That matters beyond
// tidiness: `dart:html` does not exist under `dart2wasm`, so on a Wasm web
// build `dart.library.html` is FALSE, the conditional import silently fell
// through to the stub, and "download this photo" became an UnsupportedError on
// web while every neighbouring download kept working. A seam that picks the
// wrong half is invisible until someone runs the build that exposes it.
//
// Only ever compiled for the web target, selected by the conditional import in
// preview_download_service.dart.
import 'package:web/web.dart' as web;

import '../../domain/entities/preview_manifest.dart';

Future<void> deliverPreviewDownload(PreviewPhoto photo) async {
  // A browsed photo carries no url (the gallery lists them credential-free);
  // the caller mints one via freshPhotoFor first. Reaching here without one is
  // a programming error, so fail loudly rather than navigate nowhere.
  final url = photo.url;
  if (url == null) {
    throw StateError('Photo has no download url — resolve one before delivery.');
  }

  final anchor = web.HTMLAnchorElement()
    ..href = url
    // Cross-origin browsers ignore this filename in favour of S3's
    // Content-Disposition, but it also signals "download, don't navigate".
    ..download = photo.fileName
    ..style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
}
