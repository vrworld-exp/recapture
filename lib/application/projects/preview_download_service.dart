// lib/application/projects/preview_download_service.dart
//
// The per-photo "Download" action for the staff Preview gallery. Delivery is
// platform-split (chosen by conditional import below) because web and native
// need fundamentally different mechanisms:
//   • native → fetch the presigned url's bytes → temp file → share sheet
//     (preview_download_delivery_io.dart).
//   • web    → anchor download of the url, which S3 serves with
//     `Content-Disposition: attachment` (preview_download_delivery_web.dart).
// The previous single implementation used dart:io directly, so it threw at
// runtime on the web build (path_provider/File are unsupported there) — that is
// why download was broken on web.
//
// The whole thing sits behind [PreviewDownloader] so widget tests inject a fake
// and assert "downloaded exactly once" without touching the network, the share
// sheet, or the browser. The presigned url is a bearer credential — never
// logged.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/preview_manifest.dart';
// `dart.library.js_interop`, NOT `dart.library.html` — the condition every
// other seam in this tree uses. `dart:html` is absent under dart2wasm, so the
// old `html` condition resolved to FALSE on a Wasm web build and quietly
// selected the stub, turning "download this photo" into an UnsupportedError on
// web only. js_interop is true on every web compiler.
import 'preview_download_delivery_stub.dart'
    if (dart.library.io) 'preview_download_delivery_io.dart'
    if (dart.library.js_interop) 'preview_download_delivery_web.dart';

/// Seam over "download one photo": production delivers per-platform; tests fake it.
abstract interface class PreviewDownloader {
  Future<void> download(PreviewPhoto photo);
}

/// Production [PreviewDownloader]: delegates to the conditionally-imported,
/// per-platform delivery ([deliverPreviewDownload]).
class PlatformPreviewDownloader implements PreviewDownloader {
  const PlatformPreviewDownloader();

  @override
  Future<void> download(PreviewPhoto photo) => deliverPreviewDownload(photo);
}

/// App-wide preview downloader (staff surface). Overridden with a fake in tests.
final previewDownloaderProvider = Provider<PreviewDownloader>(
  (ref) => const PlatformPreviewDownloader(),
);
