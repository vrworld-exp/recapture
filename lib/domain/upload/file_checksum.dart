// lib/domain/upload/file_checksum.dart
//
// Per-file MD5 checksum computation for the upload manifest — the value the backend
// uses to verify end-to-end file integrity AFTER upload. This is DISTINCT from the
// S3 multipart part ETags the upload manager collects (a different value for a
// different purpose): never cross-assign the two.
//
// The digest is always STREAMED, on both platforms, and for the same reason:
// buffering a whole capture would OOM a low-end device (native) or blow the tab's
// heap (web). Native streams `File.openRead()`; web streams `Blob.slice()` chunks
// out of the IndexedDB capture store. Neither ever holds a whole image.
//
// Encoding is a SINGLE, explicit choice: lowercase hex (`Digest.toString()`). If
// the backend later mandates base64 (S3 `Content-MD5` style), switch it HERE only.
//
// [FileChecksum] is an interface so manifest assembly is unit-testable with a fake
// (no real filesystem); the platform default comes from the conditional import.
import 'package:crypto/crypto.dart';

import 'file_checksum_stub.dart'
    if (dart.library.io) 'file_checksum_io.dart'
    if (dart.library.js_interop) 'file_checksum_web.dart';

/// The algorithm token emitted alongside the checksum in the manifest.
const String kChecksumAlgorithmMd5 = 'md5';

/// Computes a file's MD5. Injectable/mockable for tests.
abstract interface class FileChecksum {
  /// Lowercase-hex MD5 of the file at [path]. Throws (does NOT return empty/blank)
  /// when the file is missing/unreadable, so the caller never emits a manifest with
  /// an unverifiable file.
  Future<String> md5Hex(String path);
}

/// The platform default: `dart:io` streaming natively, IndexedDB Blob slices on
/// web. Named for what it guarantees (streaming, bounded memory) rather than for
/// its backing store, because that is the property every call site depends on.
class StreamingMd5Checksum implements FileChecksum {
  const StreamingMd5Checksum();

  @override
  Future<String> md5Hex(String path) =>
      md5HexOfStream(openChecksumStream(path));
}

/// Pure streaming MD5 over an arbitrary byte stream → lowercase hex. Isolated so it
/// is unit-testable without touching the filesystem. An error on the stream (e.g. a
/// missing file's `openRead`) propagates — never swallowed into a blank digest.
Future<String> md5HexOfStream(Stream<List<int>> bytes) async {
  final digest = await md5.bind(bytes).first;
  return digest.toString(); // lowercase hex
}
