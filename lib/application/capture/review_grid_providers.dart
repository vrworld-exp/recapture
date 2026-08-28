// lib/application/capture/review_grid_providers.dart
//
// Riverpod layer backing the Screen 7A review grid's All / Warned filter. Pure
// derivation over the per-level [LevelCaptureLedger]: the selected filter, the
// filtered accepted photos, and the All/Warned counts for the chip labels.
//
// Families are keyed by the String level id (a PitchBand.id — the repo has no
// `PitchLevel` enum; Level A Eye Ring = "mid"), matching
// [LevelCaptureLedgerRegistry]'s per-level isolation.
//
// MANUAL INVALIDATION: [LevelCaptureLedger] is a plain Dart object, not a
// ChangeNotifier, so mutating it (recordAccepted/recordWarned/reset) does NOT
// notify Riverpod. The derived providers below `watch` the registry instance,
// which never changes — so after any ledger mutation the caller must
// `ref.invalidate` these providers (or the registry provider) to recompute.
// Auto-refresh wiring is deliberately out of scope (it would touch every ledger
// consumer, not just the review grid).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/review_grid_filter.dart';
import 'ledger/captured_photo_record.dart';
import 'ledger/level_capture_ledger_registry_provider.dart';

/// Currently selected filter for the review grid, scoped per level id. Defaults
/// to [ReviewGridFilter.all].
final reviewGridFilterProvider =
    StateProvider.family<ReviewGridFilter, String>(
  (ref, levelId) => ReviewGridFilter.all,
);

/// The accepted photos for [levelId] filtered by the active [ReviewGridFilter].
/// The warned subset is the accepted photos whose `framePath` also appears in a
/// `WarnedPhotoRecord` — the exact framePath-equality join
/// [LevelCaptureLedger.hasAcceptedPhotosWithWarnings] uses, via an O(n) Set
/// lookup (not an O(n*m) nested scan).
final reviewGridFilteredPhotosProvider =
    Provider.family<List<CapturedPhotoRecord>, String>((ref, levelId) {
  final registry = ref.watch(levelCaptureLedgerRegistryProvider);
  final ledger = registry.ledgerFor(levelId);
  final filter = ref.watch(reviewGridFilterProvider(levelId));

  final warnedPaths = ledger.warned.map((w) => w.framePath).toSet();

  return switch (filter) {
    ReviewGridFilter.all => ledger.accepted,
    ReviewGridFilter.warned => ledger.accepted
        .where((p) => warnedPaths.contains(p.framePath))
        .toList(),
  };
});

/// Count of accepted photos for [levelId] that also carry a warning — the
/// "Warned (N)" chip badge.
final reviewGridWarnedCountProvider =
    Provider.family<int, String>((ref, levelId) {
  final registry = ref.watch(levelCaptureLedgerRegistryProvider);
  final ledger = registry.ledgerFor(levelId);
  final warnedPaths = ledger.warned.map((w) => w.framePath).toSet();
  return ledger.accepted.where((p) => warnedPaths.contains(p.framePath)).length;
});

/// Total accepted-photo count for [levelId] — the "All (N)" chip badge.
final reviewGridTotalCountProvider =
    Provider.family<int, String>((ref, levelId) {
  final registry = ref.watch(levelCaptureLedgerRegistryProvider);
  return registry.ledgerFor(levelId).accepted.length;
});
