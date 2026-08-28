// lib/application/capture/session/capture_session_state.dart
//
// Immutable, resumable snapshot of a guided-capture session for ONE level —
// persisted so an app relaunch restores exact in-progress state: the ring's
// per-segment fill counts, and every accepted/warned/rejected photo record.
//
// GROUNDED on the real state classes (see CaptureSessionCodec): segment fill is
// the [SegmentCoverage] model's `fillCounts` (raw per-segment counts +
// `fillThreshold`), NOT a separate RingSegment/RingSegmentState map — so a
// `fillThreshold > 1` ring with partial counts restores EXACTLY. The level is
// keyed by the [PitchBand.id] string ("mid" = Level A Eye Ring), the same id the
// ledger registry and capture analytics use (there is no PitchLevel enum).
import '../ledger/captured_photo_record.dart';
import '../ledger/rejected_photo_record.dart';
import '../ledger/warned_photo_record.dart';

class CaptureSessionState {
  const CaptureSessionState({
    required this.projectId,
    required this.levelId,
    required this.segmentCount,
    required this.fillThreshold,
    required this.fillCounts,
    required this.position,
    required this.accepted,
    required this.warned,
    required this.rejected,
    required this.savedAtMs,
  });

  /// The project this session belongs to (part of the storage key).
  final String projectId;

  /// The guided-capture level — a [PitchBand.id] ("mid" = Level A Eye Ring).
  final String levelId;

  /// Ring segment count (N) at save time. Validated on restore against the live
  /// expected count (a product update could change ring density).
  final int segmentCount;

  /// Captures required per segment to count as filled (SegmentCoverage policy).
  final int fillThreshold;

  /// Raw per-segment capture counts, length == [segmentCount]. The source of
  /// truth for fill state (filled ⇔ count >= fillThreshold).
  final List<int> fillCounts;

  /// The user's current segment (SegmentCoverage.position) for exact resume.
  final int position;

  final List<CapturedPhotoRecord> accepted;
  final List<WarnedPhotoRecord> warned;
  final List<RejectedPhotoRecord> rejected;

  /// Wall-clock save time, epoch milliseconds (repo convention).
  final int savedAtMs;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CaptureSessionState &&
          projectId == other.projectId &&
          levelId == other.levelId &&
          segmentCount == other.segmentCount &&
          fillThreshold == other.fillThreshold &&
          _listEquals(fillCounts, other.fillCounts) &&
          position == other.position &&
          _listEquals(accepted, other.accepted) &&
          _listEquals(warned, other.warned) &&
          _listEquals(rejected, other.rejected) &&
          savedAtMs == other.savedAtMs;

  @override
  int get hashCode => Object.hash(
        projectId,
        levelId,
        segmentCount,
        fillThreshold,
        Object.hashAll(fillCounts),
        position,
        Object.hashAll(accepted),
        Object.hashAll(warned),
        Object.hashAll(rejected),
        savedAtMs,
      );

  @override
  String toString() {
    final filled = fillCounts.where((c) => c >= fillThreshold).length;
    return 'CaptureSessionState(project: $projectId, level: $levelId, '
        'filled: $filled/$segmentCount, accepted: ${accepted.length}, '
        'warned: ${warned.length}, rejected: ${rejected.length}, '
        'savedAtMs: $savedAtMs)';
  }
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
