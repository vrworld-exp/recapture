// lib/application/upload/bytes_part_byte_source.dart
//
// A [PartByteSource] backed by IN-MEMORY bytes rather than a file on disk.
//
// ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
// [UploadFileSpec.path] is a device-absolute path that [FilePartByteSource]
// streams off disk. A browser-picked file has no such path: `image_picker` on
// web returns an XFile wrapping a `blob:` URL, and `File(xfile.path)` compiles
// and then throws `UnsupportedError` the moment it is read.
//
// ── WHY NO ENGINE CHANGE WAS NEEDED ─────────────────────────────────────────
// [ChunkedUploadManager] already takes an injectable `PartByteSource`
// (defaulting to `const FilePartByteSource()`), so this slots in with ZERO
// changes to the engine, its retry logic, its resume logic or its progress
// contract.
//
// ── NATIVE KEEPS THE FILE SOURCE ────────────────────────────────────────────
// This is used on WEB ONLY. On native, 48 photos going through here would sit
// in RAM at once; `FilePartByteSource` re-reads each part's range off disk and
// is the whole reason a 48-photo set is safe on a phone. See
// [photo_set_upload_flow.dart], which picks between them.
//
// The engine addresses files by their `path` string, so this keeps a map from
// that string to its bytes. On web the "path" is a synthetic handle minted by
// the flow — it is never touched by a filesystem.
import 'dart:typed_data';

import 'multipart_upload_api.dart';

/// [PartByteSource] over an in-memory `handle -> bytes` map.
///
/// Ranges are served as ONE chunk. That is correct for the sizes involved (a
/// part is at most the engine's chunk size, and a photo is capped at 15 MiB),
/// and it keeps the implementation free of any platform API.
class BytesPartByteSource implements PartByteSource {
  BytesPartByteSource(Map<String, Uint8List> byHandle)
      : _byHandle = Map.unmodifiable(byHandle);

  final Map<String, Uint8List> _byHandle;

  @override
  int fileSize(String path) => _byHandle[path]?.length ?? 0;

  @override
  Stream<List<int>> read(String path, int offset, int length) {
    final bytes = _byHandle[path];
    if (bytes == null) {
      // Same contract as FilePartByteSource on a missing file: an empty stream,
      // which the engine surfaces as a short part rather than a crash.
      return const Stream<List<int>>.empty();
    }
    // Clamped so a plan built from a stale size can never throw a RangeError
    // mid-upload — the engine's own length check is what decides the failure.
    final start = offset.clamp(0, bytes.length);
    final end = (offset + length).clamp(start, bytes.length);
    return Stream<List<int>>.value(
      Uint8List.sublistView(bytes, start, end),
    );
  }
}
