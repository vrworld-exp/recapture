// lib/application/capture/review_grid_items_provider.dart
//
// Bridges the per-level [LevelCaptureLedger] (the real captured-frame record the
// capture screen writes during a guided pass) to the display [ReviewItem] list the
// shared review grid (Screen 7A/7B/7C) renders. This is the single source that
// turns ACTUAL captured frames into reviewable tiles — the flow review screens are
// no longer driven by placeholder data.
//
// Mapping (accepted photos only — the captured set the user reviews):
//   * captureId / filePath = the record's `framePath`. framePath is the stable,
//     unique per-photo key the ledger keys on (removeAccepted) and the retake flow
//     targets (RetakeRequest.replacingCaptureId) — so the grid's tile id, the
//     delete/retake action, and the ledger all agree on one identity.
//   * verdict = warn when the frame's path also appears in a WarnedPhotoRecord
//     (exposure is orthogonal/warn-only — see LevelCaptureLedger), else accepted.
//     Rejected attempts are historical telemetry (often no kept frame) and are NOT
//     shown — the grid reviews the captures that were kept, flagging the warned ones.
//   * ringIndex = the record's segmentIndex (the ring position label / retake target).
//   * capturedAt = derived from the camera-aligned sensor timestamp (nanoseconds →
//     microseconds); used only for ordering/value-equality, never displayed.
//
// AUTODISPOSE: the registry instance never changes (see review_grid_providers.dart's
// manual-invalidation note), so this is `autoDispose` — each time a review screen
// mounts it recomputes a fresh snapshot of the ledger, and is dropped when the
// screen leaves. That gives the review an up-to-date view of the captured set on
// every visit without wiring registry change-notification (out of scope).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/capture_evaluation.dart';
import '../../domain/entities/review_item.dart';
import 'ledger/level_capture_ledger_registry_provider.dart';

/// The captured frames for the level identified by [levelId] (a `PitchBand.id` —
/// 'mid'/'high'/'low', via `pitchBandIdForLevel`), as display [ReviewItem]s in
/// capture order. Empty when nothing was captured for the level (→ the grid's
/// empty state).
final reviewGridItemsProvider =
    Provider.autoDispose.family<List<ReviewItem>, String>((ref, levelId) {
  final registry = ref.watch(levelCaptureLedgerRegistryProvider);
  final ledger = registry.ledgerFor(levelId);
  final warnedPaths = ledger.warned.map((w) => w.framePath).toSet();

  return [
    for (final r in ledger.accepted)
      ReviewItem(
        captureId: r.framePath,
        filePath: r.framePath,
        verdict: warnedPaths.contains(r.framePath)
            ? CaptureVerdict.warn
            : CaptureVerdict.accepted,
        ringIndex: r.segmentIndex,
        capturedAt: DateTime.fromMicrosecondsSinceEpoch(
          r.sensorTimestampNs ~/ 1000,
          isUtc: true,
        ),
      ),
  ];
});
