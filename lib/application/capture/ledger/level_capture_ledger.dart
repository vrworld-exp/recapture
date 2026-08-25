// lib/application/capture/ledger/level_capture_ledger.dart
//
// In-memory per-level capture ledger: the queryable aggregation layer above the
// fire-and-forget capture analytics events and the ring overlap gate. It records
// what happened during ONE guided-capture level's session (accepted / warned /
// rejected) for UI/progress, scoped per level by LevelCaptureLedgerRegistry.
//
// PASSIVE record store: it dispatches no analytics, performs no IO/persistence,
// and does NO cross-list validation. The same framePath landing in both accepted
// and rejected (which should never happen at a correct call site) is the caller's
// invariant to keep, not the ledger's — keeping it passive is deliberate.
import 'captured_photo_record.dart';
import 'photo_rejection_reason.dart';
import 'rejected_photo_record.dart';
import 'warned_photo_record.dart';

class LevelCaptureLedger {
  final List<CapturedPhotoRecord> _accepted = [];
  final List<WarnedPhotoRecord> _warned = [];
  final List<RejectedPhotoRecord> _rejected = [];

  /// Accepted photos, in record order. Unmodifiable — external mutation is
  /// impossible (the record methods are the only way to add).
  List<CapturedPhotoRecord> get accepted => List.unmodifiable(_accepted);

  /// Exposure warnings, in record order. A warning may correspond to a photo that
  /// also appears in [accepted] (exposure is orthogonal to accept/reject).
  List<WarnedPhotoRecord> get warned => List.unmodifiable(_warned);

  /// Rejected attempts, in record order.
  List<RejectedPhotoRecord> get rejected => List.unmodifiable(_rejected);

  void recordAccepted(CapturedPhotoRecord record) => _accepted.add(record);

  /// Records an exposure warning, independently of accept/reject (mirrors the
  /// analytics layer's PhotoWarnedExposureEvent independence).
  void recordWarned(WarnedPhotoRecord record) => _warned.add(record);

  void recordRejected(RejectedPhotoRecord record) => _rejected.add(record);

  /// Capture attempts of any committed outcome (accepted + rejected). Excludes
  /// [warned] — a warning co-occurs with an accept/reject, it is not itself an
  /// attempt outcome.
  int get totalAttempts => _accepted.length + _rejected.length;

  /// Count of rejections matching [reason].
  int rejectedCountFor(PhotoRejectionReason reason) =>
      _rejected.where((r) => r.reason == reason).length;

  /// True if at least one accepted photo shares a framePath with a warned record
  /// (a warned-but-kept photo). Matches on framePath only — timestamps may differ
  /// across pipeline stages for the same physical frame.
  bool get hasAcceptedPhotosWithWarnings =>
      _accepted.any((a) => _warned.any((w) => w.framePath == a.framePath));

  /// Removes the accepted photo(s) at [framePath] when a capture is deleted,
  /// along with any warned record for the SAME frame (the warning belongs to the
  /// physical photo, so it goes with it). Returns the removed accepted records so
  /// the caller can decrement their segments' coverage. A framePath with no
  /// accepted record → empty list (idempotent; a double-delete is a no-op).
  /// Rejected attempts are historical telemetry and are deliberately untouched.
  List<CapturedPhotoRecord> removeAccepted(String framePath) {
    final removed =
        _accepted.where((r) => r.framePath == framePath).toList(growable: false);
    if (removed.isEmpty) return const [];
    _accepted.removeWhere((r) => r.framePath == framePath);
    _warned.removeWhere((w) => w.framePath == framePath);
    return removed;
  }

  /// Clears all three lists — restart a level's capture session from scratch.
  void reset() {
    _accepted.clear();
    _warned.clear();
    _rejected.clear();
  }

  @override
  String toString() => 'LevelCaptureLedger(accepted: ${_accepted.length}, '
      'warned: ${_warned.length}, rejected: ${_rejected.length})';
}
