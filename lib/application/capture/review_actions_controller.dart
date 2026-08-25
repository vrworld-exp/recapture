// lib/application/capture/review_actions_controller.dart
//
// The Screen 7A bottom-action-bar logic, lifted OUT of the widgets into a
// testable handler that composes the existing subsystems and keeps them
// CONSISTENT: per-photo file+sidecar deletion (storage), metadata removal
// (ledger), and segment-coverage decrement must agree — a photo gone from disk
// must not still count toward its segment's fill (that would make coverage lie).
//
// Everything it touches is an injected seam, so it is exhaustively unit-testable
// with fakes and carries no Riverpod/IO imports of its own. The real wiring
// (native per-frame delete, the live ledger + SegmentCoverageNotifier, the
// platform confirm + GoRouter navigation, and the analytics context) is supplied
// by the parent that owns the screen.
//
// ANALYTICS: when [ReviewActionsAnalytics] is supplied, a SUCCESSFUL action emits
// exactly one funnel event with the ACTUAL affected count — `photo_deleted` for a
// pure delete, `photo_retaken` for a retake (its internal delete step is silent so
// the action never double-reports). A cancelled confirm or a fully-failed action
// emits nothing. The emit is fire-and-forget (guarded `Analytics` dispatcher), so
// it can never break the action.
//
// Action semantics (from the task):
//   - delete : confirm → remove files+sidecars + metadata + decrement coverage,
//              consistently (partial failures kept consistent, not half-applied),
//              then exit selection. Stays on the grid.
//   - retake : delete (with retake wording) THEN navigate to capture targeting a
//              freed (now-missing) segment. Distinct from delete by the navigate.
//   - backToCapture : just resume guided capture (exits selection first).
import '../../domain/entities/confirm_kind.dart';
import '../../domain/entities/retake_request.dart';
import 'analytics/review_flow_events.dart';
import 'ledger/captured_photo_record.dart';

/// Deletes the image file + its JSON sidecar for [framePath]. Returns `true` only
/// when the file is actually gone; `false` (locked/in-use/IO error) means the
/// caller must KEEP the metadata + coverage for it so storage/metadata/coverage
/// stay consistent. The native per-frame deletion that backs this in production
/// is a deferred dependency — today only whole level/job/project deletion exists
/// (`CaptureStorageClient`), so this seam is defined here for the controller to
/// compose and the native method is wired later.
typedef DeletePhotoFile = Future<bool> Function(String framePath);

/// Removes the accepted record(s) at [framePath] from the metadata ledger and
/// returns them (for their segment indices). Backed by
/// `LevelCaptureLedger.removeAccepted`.
typedef RemoveFromLedger = List<CapturedPhotoRecord> Function(String framePath);

/// Decrements [segmentIndex]'s coverage by one capture; returns whether it is now
/// MISSING (dropped below the fill threshold). Backed by
/// `SegmentCoverageNotifier.removeCapture`.
typedef DecrementSegment = bool Function(int segmentIndex);

/// Presents the platform-idiomatic destructive confirmation for [count] photos
/// and resolves confirmed/cancelled. Backed by `showDeleteConfirmation`.
typedef ConfirmDestructive = Future<bool> Function(int count, ConfirmKind kind);

/// Navigates to the capture screen; a non-null [request] enters retake mode
/// targeting a freed segment, null just resumes guided capture.
typedef NavigateToCapture = void Function(RetakeRequest? request);

/// Outcome of a delete/retake action — what was removed, what survived, and which
/// segments are now missing (the retake targets).
class ReviewActionResult {
  const ReviewActionResult({
    this.deleted = const [],
    this.failed = const [],
    this.freedSegments = const [],
    this.cancelled = false,
  });

  /// No-op result (empty selection / in-flight).
  static const ReviewActionResult none = ReviewActionResult();

  /// The user cancelled the confirmation — nothing changed.
  static const ReviewActionResult cancelledResult =
      ReviewActionResult(cancelled: true);

  /// framePaths actually removed (file gone + metadata + coverage updated).
  final List<String> deleted;

  /// framePaths whose file could not be deleted — metadata + coverage left intact
  /// for these, so the three stores stay consistent. Surface for a retry/report.
  final List<String> failed;

  /// Segments that became MISSING as a result (the retake targets), ascending.
  final List<int> freedSegments;

  /// True iff the confirmation was declined.
  final bool cancelled;

  bool get anyDeleted => deleted.isNotEmpty;
  bool get hasFailures => failed.isNotEmpty;
}

class ReviewActionsController {
  ReviewActionsController({
    required DeletePhotoFile deletePhotoFile,
    required RemoveFromLedger removeFromLedger,
    required DecrementSegment decrementSegment,
    required ConfirmDestructive confirm,
    required NavigateToCapture navigateToCapture,
    void Function()? exitSelection,
    ReviewActionsAnalytics? analytics,
  })  : _deletePhotoFile = deletePhotoFile,
        _removeFromLedger = removeFromLedger,
        _decrementSegment = decrementSegment,
        _confirm = confirm,
        _navigateToCapture = navigateToCapture,
        _exitSelection = exitSelection,
        _analytics = analytics;

  final DeletePhotoFile _deletePhotoFile;
  final RemoveFromLedger _removeFromLedger;
  final DecrementSegment _decrementSegment;
  final ConfirmDestructive _confirm;
  final NavigateToCapture _navigateToCapture;
  final void Function()? _exitSelection;

  /// Optional funnel-analytics seam. Null → the controller emits nothing (older
  /// call sites + most unit tests). When set, a successful action emits one
  /// `photo_deleted`/`photo_retaken` with the actual affected count.
  final ReviewActionsAnalytics? _analytics;

  /// Guards against overlapping actions (a double-tap or a tap while one is
  /// in-flight) so a photo is never deleted twice.
  bool _inFlight = false;

  /// Delete the selected photos: confirm, then for EACH — delete file+sidecar,
  /// and only on success remove its metadata + decrement its segment. A file that
  /// fails to delete is reported in [ReviewActionResult.failed] and keeps its
  /// metadata + coverage (consistency over optimism). Exits selection if anything
  /// was removed.
  Future<ReviewActionResult> deleteSelected(
    Set<String> ids, {
    ConfirmKind kind = ConfirmKind.delete,
  }) async {
    if (ids.isEmpty || _inFlight) return ReviewActionResult.none;
    _inFlight = true;
    try {
      final confirmed = await _confirm(ids.length, kind);
      if (!confirmed) return ReviewActionResult.cancelledResult;

      final deleted = <String>[];
      final failed = <String>[];
      final freed = <int>{};

      for (final framePath in ids) {
        final fileGone = await _deletePhotoFile(framePath);
        if (!fileGone) {
          // Storage still holds it → leave metadata + coverage untouched so all
          // three agree it still exists. The caller can retry exactly these.
          failed.add(framePath);
          continue;
        }
        for (final record in _removeFromLedger(framePath)) {
          final segment = record.segmentIndex;
          if (segment != null && _decrementSegment(segment)) {
            freed.add(segment); // now below threshold → missing again
          }
        }
        deleted.add(framePath);
      }

      if (deleted.isNotEmpty) _exitSelection?.call();
      final freedSorted = freed.toList()..sort();

      // Funnel: a PURE delete reports `photo_deleted` here with the ACTUAL count.
      // A retake routes through this method with `kind == retake` — stay silent so
      // `retakeSelected` reports `photo_retaken` instead (one event per action).
      if (kind == ConfirmKind.delete && deleted.isNotEmpty) {
        _analytics?.deleted(
          count: deleted.length,
          segmentsNowMissing: freedSorted,
        );
      }

      return ReviewActionResult(
        deleted: deleted,
        failed: failed,
        freedSegments: freedSorted,
        cancelled: false,
      );
    } finally {
      _inFlight = false;
    }
  }

  /// Retake the selected photos: the same removal (with retake confirm wording),
  /// THEN navigate to capture targeting the first freed segment so guidance points
  /// there. Distinct from [deleteSelected] purely by the navigation. Cancel or a
  /// fully-failed removal does NOT navigate.
  Future<ReviewActionResult> retakeSelected(Set<String> ids) async {
    final result = await deleteSelected(ids, kind: ConfirmKind.retake);
    if (result.cancelled || !result.anyDeleted) return result;

    // Funnel: one `photo_retaken` per completed retake, ACTUAL count + freed
    // targets. (deleteSelected stayed silent for kind == retake.)
    _analytics?.retaken(
      count: result.deleted.length,
      segmentIndices: result.freedSegments,
    );

    final target =
        result.freedSegments.isNotEmpty ? result.freedSegments.first : null;
    _navigateToCapture(
      target == null
          ? null
          : RetakeRequest(ringIndex: target, returnToReviewAfter: false),
    );
    return result;
  }

  /// Resume the guided capture flow (no selection action). Exits selection first
  /// if active, then navigates — allowed even when the ring is complete.
  void backToCapture() {
    _exitSelection?.call();
    _navigateToCapture(null);
  }
}
