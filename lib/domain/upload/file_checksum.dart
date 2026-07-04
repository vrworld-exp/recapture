// lib/domain/upload/file_checksum.dart
//
// Per-file MD5 checksum computation for the upload manifest — the value the backend
// uses to verify end-to-end file integrity AFTER upload. This is DISTINCT from the
// S3 multipart part ETags the upload manager collects (a different value for a
// different purpose): never cross-assign the two.
//
// The digest is computed by STREAMING the file from disk (`File.openRead()` fed
// into the `crypto` MD5 sink) — never `md5.convert(readAsBytes())`, which would
// buffer the whole file and OOM on a large capture on a low-end device.
//
// Encoding is a SINGLE, explicit choice: lowercase hex (`Digest.toString()`). If
// the backend later mandates base64 (S3 `Content-MD5` style), switch it HERE only.
//
// [FileChecksum] is an interface so manifest assembly is unit-testable with a fake
// (no real filesystem); [StreamingMd5Checksum] is the dart:io-backed default.
import 'dart:io';

import 'package:crypto/crypto.dart';

/// The algorithm token emitted alongside the checksum in the manifest.
const String kChecksumAlgorithmMd5 = 'md5';

/// Computes a file's MD5. Injectable/mockable for tests.
abstract interface class FileChecksum {
  /// Lowercase-hex MD5 of the file at [path]. Throws (does NOT return empty/blank)
  /// when the file is missing/unreadable, so the caller never emits a manifest with
  /// an unverifiable file.
  Future<String> md5Hex(String path);
}

/// Streams the file from disk into the MD5 sink (bounded memory). Default impl.
class StreamingMd5Checksum implements FileChecksum {
  const StreamingMd5Checksum();

  @override
  Future<String> md5Hex(String path) => md5HexOfStream(File(path).openRead());
}

/// Pure streaming MD5 over an arbitrary byte stream → lowercase hex. Isolated so it
/// is unit-testable without touching the filesystem. An error on the stream (e.g. a
/// missing file's `openRead`) propagates — never swallowed into a blank digest.
Future<String> md5HexOfStream(Stream<List<int>> bytes) async {
  final digest = await md5.bind(bytes).first;
  return digest.toString(); // lowercase hex
}
