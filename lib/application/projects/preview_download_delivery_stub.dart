// lib/application/projects/preview_download_delivery_stub.dart
//
// Compile-time fallback for the platform-split preview download delivery. The
// real implementation is chosen by conditional import in
// preview_download_service.dart: `dart:io` (native — fetch bytes → temp file →
// share sheet) or `dart:html` (web — anchor download of the Content-Disposition
// url). This stub is only reachable on a hypothetical platform that has neither
// library; it fails loudly rather than silently no-op-ing.
import '../../domain/entities/preview_manifest.dart';

Future<void> deliverPreviewDownload(PreviewPhoto photo) =>
    throw UnsupportedError('Preview download is not supported on this platform.');
