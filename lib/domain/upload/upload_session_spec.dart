// lib/domain/upload/upload_session_spec.dart
//
// Pure Dart — NO Flutter / IO. The INPUT the upload engine consumes: the set of
// files (with their S3 object keys + sizes) that make up one capture session's
// upload. Decoupled from the bundle packer's on-disk layout so the engine is
// testable without a real filesystem — a caller (the pack→upload wiring) builds
// this from a CaptureBundle's files.
class UploadFileSpec {
  const UploadFileSpec({
    required this.path,
    required this.key,
    required this.size,
  });

  /// Device-absolute path of the file to upload (read-only; streamed from disk).
  final String path;

  /// The S3 object key this file uploads to (echoed through initiate/complete).
  final String key;

  /// The file's size in bytes (drives chunking + total-bytes progress).
  final int size;
}

/// One session's upload payload: an id + its files, in a stable order.
class UploadSessionSpec {
  const UploadSessionSpec({required this.sessionId, required this.files});

  final String sessionId;
  final List<UploadFileSpec> files;

  /// Sum of every file's size — the progress contract's `totalBytes`.
  int get totalBytes => files.fold(0, (sum, f) => sum + (f.size < 0 ? 0 : f.size));

  int get totalFiles => files.length;
}
