// lib/application/capture/progression/level_progression_provider.dart
//
// Reactive exposure of the multi-level progression core. The Notifier owns the
// current [LevelProgression] for a project and the side-channel adapters around
// the pure core: it builds the sequence from the live [CaptureConfig], persists
// incrementally to the injected [LevelProgressionStore] (durable), and resumes on
// reopen. The pure core (level_progression.dart) makes every decision; this is the
// thin reactive + persistence wrapper.
//
// SCOPE: this is the standalone, testable controller. Wiring it into the live
// capture/interstitial/router flow (which today sequences A→B→C via GoRouter) is a
// separate task, per the progression task's own scope.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config/config_notifier.dart';
import 'level_progression.dart';
import 'level_progression_builder.dart';
import 'level_progression_store.dart';

/// The Hive-backed progression store. Overridable in tests with a fake.
final levelProgressionStoreProvider =
    Provider<LevelProgressionStore>((ref) => LevelProgressionStore());

/// The current project's progression, or null before [start]/[resume]. Watched by
/// any UI that needs to reflect "where are we in the flow"; mutated via the
/// notifier's gated transforms.
final levelProgressionControllerProvider =
    NotifierProvider<LevelProgressionController, LevelProgression?>(
  LevelProgressionController.new,
);

class LevelProgressionController extends Notifier<LevelProgression?> {
  String? _projectId;

  @override
  LevelProgression? build() => null;

  LevelProgressionStore get _store => ref.read(levelProgressionStoreProvider);

  /// Best-effort durable save — a persistence failure must never break the flow.
  Future<void> _persist() async {
    final p = state;
    final id = _projectId;
    if (p == null || id == null) return;
    try {
      await _store.save(id, p);
    } catch (_) {
      // Durability is best-effort; the in-memory state remains authoritative.
    }
  }

  /// Begins a FRESH progression for [projectId] (frontier at the first level),
  /// built from the current config, and persists it.
  Future<void> start(String projectId) async {
    _projectId = projectId;
    state = initialProgressionFromConfig(ref.read(captureConfigProvider));
    await _persist();
  }

  /// Restores [projectId]'s progression from the store, reconciled against the
  /// CURRENT config (segment counts/thresholds win; the user's per-level progress
  /// + frontier carry over). Missing/corrupt persisted state → a fresh start (no
  /// crash). Returns the restored/started progression.
  Future<LevelProgression> resume(String projectId) async {
    _projectId = projectId;
    final config = ref.read(captureConfigProvider);
    LevelProgression? persisted;
    try {
      persisted = await _store.load(projectId);
    } catch (_) {
      persisted = null;
    }
    final restored = persisted == null
        ? initialProgressionFromConfig(config)
        : reconcileWithConfig(persisted, config);
    state = restored;
    // Re-persist the reconciled snapshot so the stored shape matches live config.
    await _persist();
    return restored;
  }

  /// No-forward-skip advance: moves to the next level only when the current level's
  /// gate passes. Returns true iff the frontier moved (false = rejected: incomplete
  /// current level, last level, or no active progression). Persists on success.
  Future<bool> advance() async {
    final p = state;
    if (p == null) return false;
    final next = p.advance();
    if (identical(next, p) || next == p) return false; // gated / last level
    state = next;
    await _persist();
    return true;
  }

  /// Records capture progress (or a review un-complete) for [levelId] and persists.
  /// A prior level dropping below its gate flips [LevelProgression.overallComplete]
  /// to false; the frontier is unchanged.
  Future<void> recordLevelProgress(
    String levelId, {
    int? filledCount,
    int? acceptedCount,
    int? segmentCount,
    Set<int>? firedMilestones,
  }) async {
    final p = state;
    if (p == null) return;
    final next = p.updateLevel(
      levelId,
      filledCount: filledCount,
      acceptedCount: acceptedCount,
      segmentCount: segmentCount,
      firedMilestones: firedMilestones,
    );
    if (next == p) return;
    state = next;
    await _persist();
  }

  /// Whether [levelId] may be reviewed (backward review of any reached level).
  /// Pure validation — reviewing never moves the frontier, so this does NOT mutate
  /// state (matches "returning keeps currentLevelIndex").
  bool canReview(String levelId) => state?.canReviewId(levelId) ?? false;

  /// True only when EVERY level is complete (a prior un-completed level → false).
  bool get overallComplete => state?.overallComplete ?? false;

  /// Clears the persisted progression for the active project (e.g. project reset).
  Future<void> clearPersisted() async {
    final id = _projectId;
    if (id == null) return;
    try {
      await _store.clear(id);
    } catch (_) {
      // best-effort
    }
  }
}
