// lib/domain/entities/upload_progress.dart
//
// Pure Dart — NO Flutter/IO imports. The progress CONTRACT the Uploading screen
// (Screen 9) observes. The screen is a pure observer: it renders THIS snapshot and
// computes nothing about the transfer. The real upload pipeline (a separate phase
// task) produces these snapshots; until it exists a no-op source emits the safe
// initial state (see upload_progress_provider.dart).
//
// All display-facing derivations are guarded here (single place): the fraction is
// clamped to [0,1] and never divides by zero; uploaded counts are clamped to their
// totals so a transient over-report (uploaded > total) can never show >100% or a
// negative value. Byte→MB FORMATTING lives in utils/byte_format.dart (one shared
// formatter), not here.

/// The lifecycle state of the upload, as reported by the pipeline.
///
/// [cancelled] is a terminal transfer-aborted state: the in-flight transfer was
/// stopped at the user's request. It is NOT a delete — the local captured data is
/// retained and re-uploadable; only the transfer was abandoned.
enum UploadStatus { idle, inProgress, completed, failed, paused, cancelled }

class UploadProgress {
  const UploadProgress({
    required this.status,
    required this.bytesUploaded,
    required this.totalBytes,
    required this.filesUploaded,
    required this.totalFiles,
  });

  /// The safe pre-total state: nothing transferred, totals unknown, idle. The bar
  /// renders empty-but-determinate (fraction 0) — never an indeterminate spinner.
  static const UploadProgress initial = UploadProgress(
    status: UploadStatus.idle,
    bytesUploaded: 0,
    totalBytes: 0,
    filesUploaded: 0,
    totalFiles: 0,
  );

  final UploadStatus status;
  final int bytesUploaded;
  final int totalBytes;
  final int filesUploaded;
  final int totalFiles;

  /// Progress fraction in [0, 1]. 0 when totals are unknown (`totalBytes <= 0`) so
  /// there is no divide-by-zero; clamped so a transient `uploaded > total` (or a
  /// non-finite ratio) never renders as >100% or negative.
  double get fraction {
    if (totalBytes <= 0) return 0;
    final f = bytesUploaded / totalBytes;
    return f.isFinite ? f.clamp(0.0, 1.0) : 0.0;
  }

  /// Whether the totals are known yet (the bar/counters are meaningful).
  bool get hasTotals => totalBytes > 0 || totalFiles > 0;

  /// Bytes uploaded clamped to `[0, totalBytes]` for display.
  int get displayBytesUploaded {
    if (bytesUploaded < 0) return 0;
    if (totalBytes > 0 && bytesUploaded > totalBytes) return totalBytes;
    return bytesUploaded;
  }

  /// Files uploaded clamped to `[0, totalFiles]` for display.
  int get displayFilesUploaded {
    if (filesUploaded < 0) return 0;
    if (totalFiles > 0 && filesUploaded > totalFiles) return totalFiles;
    return filesUploaded;
  }

  bool get isInProgress => status == UploadStatus.inProgress;
  bool get isComplete => status == UploadStatus.completed;
  bool get isFailed => status == UploadStatus.failed;
  bool get isPaused => status == UploadStatus.paused;

  /// The transfer was aborted at the user's request. Local captured data is
  /// retained (re-uploadable) — this is NOT a delete.
  bool get isCancelled => status == UploadStatus.cancelled;

  UploadProgress copyWith({
    UploadStatus? status,
    int? bytesUploaded,
    int? totalBytes,
    int? filesUploaded,
    int? totalFiles,
  }) =>
      UploadProgress(
        status: status ?? this.status,
        bytesUploaded: bytesUploaded ?? this.bytesUploaded,
        totalBytes: totalBytes ?? this.totalBytes,
        filesUploaded: filesUploaded ?? this.filesUploaded,
        totalFiles: totalFiles ?? this.totalFiles,
      );

  @override
  bool operator ==(Object other) =>
      other is UploadProgress &&
      other.status == status &&
      other.bytesUploaded == bytesUploaded &&
      other.totalBytes == totalBytes &&
      other.filesUploaded == filesUploaded &&
      other.totalFiles == totalFiles;

  @override
  int get hashCode => Object.hash(
        status,
        bytesUploaded,
        totalBytes,
        filesUploaded,
        totalFiles,
      );

  @override
  String toString() => 'UploadProgress($status, $displayFilesUploaded/$totalFiles '
      'files, $bytesUploaded/$totalBytes bytes)';
}
