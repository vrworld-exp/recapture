// lib/domain/upload/upload_part_plan.dart
//
// Pure Dart — NO Flutter / IO / Dio imports. The S3 multipart CHUNKING math + the
// two small pure helpers the upload engine needs (ETag normalization, retry
// backoff). Isolated here so the hard S3 rules are unit-testable without any
// network or filesystem.
//
// S3 MULTIPART RULES (hard, not tunable):
//   • every part except the LAST must be ≥ 5 MiB (5,242,880 bytes),
//   • at most 10,000 parts per upload,
//   • parts are 1-based and completed in ascending part-number order.
// [planFileParts] guarantees the first two; the manager guarantees the third when
// it submits ETags.

/// S3's minimum size for a non-final multipart part: 5 MiB.
const int kS3MinPartSize = 5 * 1024 * 1024;

/// S3's maximum number of parts in a single multipart upload.
const int kS3MaxParts = 10000;

/// A conservative default chunk size for low-end mobile (8 MiB) — above the 5 MiB
/// floor, small enough to bound per-part memory/retry cost.
const int kDefaultChunkSize = 8 * 1024 * 1024;

/// One planned S3 part: its 1-based [partNumber], byte [offset] into the file, and
/// [length]. The final part may be shorter than the chunk size (allowed); every
/// other part is exactly the effective chunk size (≥ [kS3MinPartSize]).
class UploadPartPlan {
  const UploadPartPlan({
    required this.partNumber,
    required this.offset,
    required this.length,
  });

  final int partNumber;
  final int offset;
  final int length;

  int get endOffset => offset + length;

  @override
  bool operator ==(Object other) =>
      other is UploadPartPlan &&
      other.partNumber == partNumber &&
      other.offset == offset &&
      other.length == length;

  @override
  int get hashCode => Object.hash(partNumber, offset, length);

  @override
  String toString() =>
      'UploadPartPlan(#$partNumber, offset: $offset, length: $length)';
}

/// Splits a file of [fileSize] bytes into S3-valid parts.
///
/// The effective chunk size is `max(chunkSize, kS3MinPartSize)`, then scaled UP if
/// the file would otherwise need more than [kS3MaxParts] parts (so the part count
/// never exceeds the cap). Non-final parts are exactly the effective chunk size
/// (≥ 5 MiB); the final part carries the remainder (may be < 5 MiB — allowed).
///
/// [fileSize] `<= 0` returns an EMPTY list — a zero-byte/absent file cannot be a
/// multipart upload; the caller decides skip-vs-fail (S3 multipart needs ≥ 1 part
/// with content). A file smaller than the floor yields a SINGLE part of its size.
List<UploadPartPlan> planFileParts(
  int fileSize, {
  int chunkSize = kDefaultChunkSize,
  int minPartSize = kS3MinPartSize,
  int maxParts = kS3MaxParts,
}) {
  if (fileSize <= 0) return const [];

  var effectiveChunk = chunkSize < minPartSize ? minPartSize : chunkSize;
  // Scale up so ceil(fileSize / effectiveChunk) <= maxParts.
  final minChunkForCap = (fileSize + maxParts - 1) ~/ maxParts;
  if (minChunkForCap > effectiveChunk) effectiveChunk = minChunkForCap;

  final parts = <UploadPartPlan>[];
  var offset = 0;
  var partNumber = 1;
  while (offset < fileSize) {
    final remaining = fileSize - offset;
    final length = remaining < effectiveChunk ? remaining : effectiveChunk;
    parts.add(UploadPartPlan(
      partNumber: partNumber,
      offset: offset,
      length: length,
    ));
    offset += length;
    partNumber++;
  }
  return parts;
}

/// Normalizes an S3 `ETag` response header to the bare hex value: strips the
/// surrounding double quotes S3 wraps it in (and any stray whitespace/backslashes),
/// so the value sent on complete is consistent regardless of quoting. Returns the
/// input unchanged (trimmed) when there is nothing to strip.
String normalizeETag(String raw) => raw.replaceAll('"', '').replaceAll(r'\', '').trim();

/// Bounded exponential backoff delay for retry [attempt] (1-based): `base * 2^(n-1)`
/// capped at [maxDelay]. Never negative; `attempt <= 1` → [base].
Duration backoffDelay(
  int attempt, {
  Duration base = const Duration(milliseconds: 500),
  Duration maxDelay = const Duration(seconds: 30),
}) {
  if (attempt <= 1) return base;
  // Cap the shift so 2^(n-1) can't overflow for pathological attempt counts.
  final shift = (attempt - 1).clamp(0, 30);
  final ms = base.inMilliseconds * (1 << shift);
  return ms >= maxDelay.inMilliseconds ? maxDelay : Duration(milliseconds: ms);
}

/// Bounded retry policy for a single part upload.
class UploadRetryPolicy {
  const UploadRetryPolicy({
    this.maxAttempts = 4,
    this.baseDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 30),
  });

  /// Total attempts per part (initial try + retries). `>= 1`.
  final int maxAttempts;
  final Duration baseDelay;
  final Duration maxDelay;

  Duration delayForAttempt(int attempt) =>
      backoffDelay(attempt, base: baseDelay, maxDelay: maxDelay);
}
