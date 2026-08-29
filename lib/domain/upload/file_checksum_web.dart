// lib/domain/upload/file_checksum_web.dart
//
// WEB half of the streaming checksum source: fixed-size `Blob.slice()` reads out
// of the IndexedDB capture store.
//
// The slicing is the point. `Blob.arrayBuffer()` on a 4 MB photo would put the
// whole image in the tab's heap, and a 48-photo bundle hashed that way peaks at
// hundreds of megabytes — the exact failure the native side avoids with
// `File.openRead`. Slicing keeps the peak at one chunk, so the digest costs the
// same on both platforms.
//
// The path is the opaque `idb://…` handle a web capture minted; a handle with no
// stored frame errors the stream (never yields empty), so a missing frame aborts
// the pack instead of producing a manifest with a confidently wrong checksum.
import 'dart:js_interop';
import 'dart:typed_data';

import '../../platform/capture_ports/web_capture_store.dart';

/// Chunk size for the streaming digest. 256 KiB matches the native bundle
/// copier's chunk, so the two platforms make the same number of passes over the
/// same data.
const int kChecksumChunkBytes = 256 * 1024;

Stream<List<int>> openChecksumStream(String path) async* {
  final blob = await WebCaptureStore.instance.readBlob(path);
  if (blob == null) {
    throw StateError('Captured frame is no longer stored: $path');
  }
  final total = blob.size;
  var offset = 0;
  while (offset < total) {
    final end = (offset + kChecksumChunkBytes) > total
        ? total
        : offset + kChecksumChunkBytes;
    final slice = blob.slice(offset, end);
    final buffer = await slice.arrayBuffer().toDart;
    yield buffer.toDart.asUint8List();
    offset = end;
  }
  if (total == 0) {
    // An empty stored blob is still a valid (if useless) input; yield nothing
    // rather than hanging, and let the manifest's byte count expose it.
    yield Uint8List(0);
  }
}
