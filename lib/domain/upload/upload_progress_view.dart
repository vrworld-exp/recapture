// lib/domain/upload/upload_progress_view.dart
//
// Pure Dart — NO Flutter / IO. A phase-aware VIEW over the base [UploadProgress]
// contract (Screen 9's shape). It ADDS the reporting detail the in-progress UI
// wants — a coarse [UploadPhase] (uploading / retrying / finalizing) and the
// current [retryAttempt] — WITHOUT changing the base [UploadProgress] model or its
// [UploadStatus] enum (so the existing screen contract is untouched).
//
// It composes (does not duplicate) [UploadProgress], so the guarded fraction /
// clamped counts live in ONE place. The upload CONTROLLER remains the authority on
// the success/failure/cancel OUTCOME; this view carries the base [status] only for
// display (e.g. rendering the final 100% state), never as the verdict source.
import '../entities/upload_progress.dart';

/// A coarse progress phase — orthogonal to the outcome [UploadStatus]. Lets the UI
/// distinguish "actively transferring" from "waiting out a backoff" (so a retry
/// looks like a retry, not a frozen bar) and the final "finalizing" step.
enum UploadPhase { uploading, retrying, finalizing }

/// The phase-annotated progress snapshot the reporting layer emits.
class UploadProgressView {
  const UploadProgressView({
    required this.progress,
    this.phase = UploadPhase.uploading,
    this.retryAttempt = 0,
  });

  /// The base progress (bytes/files/totals/status), with its guarded derivations.
  final UploadProgress progress;

  /// The coarse phase (uploading / retrying / finalizing).
  final UploadPhase phase;

  /// The current retry attempt number while [phase] is [UploadPhase.retrying]
  /// (0 otherwise). For a "Retrying (2/3)…" style label.
  final int retryAttempt;

  /// The safe initial view — determinate-but-empty, uploading.
  static const UploadProgressView initial =
      UploadProgressView(progress: UploadProgress.initial);

  // ── delegated, already-guarded core fields ─────────────────────────────────
  int get bytesUploaded => progress.displayBytesUploaded;
  int get totalBytes => progress.totalBytes;
  int get filesUploaded => progress.displayFilesUploaded;
  int get totalFiles => progress.totalFiles;

  /// Byte progress fraction in [0, 1] — guarded against zero totals (see
  /// [UploadProgress.fraction]).
  double get fraction => progress.fraction;

  /// File progress fraction in [0, 1]; 0 when [totalFiles] is 0 (guarded).
  double get fileFraction =>
      totalFiles > 0 ? (filesUploaded / totalFiles).clamp(0.0, 1.0) : 0.0;

  /// The base outcome status (display only — the controller owns the verdict).
  UploadStatus get status => progress.status;

  bool get isRetrying => phase == UploadPhase.retrying;

  /// Whether byte transfer has reached 100% (guarded for zero totals: an empty
  /// bundle is trivially complete).
  bool get isBytesComplete =>
      totalBytes <= 0 ? true : bytesUploaded >= totalBytes;

  UploadProgressView copyWith({
    UploadProgress? progress,
    UploadPhase? phase,
    int? retryAttempt,
  }) =>
      UploadProgressView(
        progress: progress ?? this.progress,
        phase: phase ?? this.phase,
        retryAttempt: retryAttempt ?? this.retryAttempt,
      );

  @override
  bool operator ==(Object other) =>
      other is UploadProgressView &&
      other.progress == progress &&
      other.phase == phase &&
      other.retryAttempt == retryAttempt;

  @override
  int get hashCode => Object.hash(progress, phase, retryAttempt);

  @override
  String toString() =>
      'UploadProgressView(${phase.name}, ${(fraction * 100).toStringAsFixed(1)}%, '
      '$filesUploaded/$totalFiles files, retry: $retryAttempt)';
}
