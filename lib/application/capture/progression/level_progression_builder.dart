// lib/application/capture/progression/level_progression_builder.dart
//
// Builds the ordered level sequence for the progression core FROM CONFIG + the
// FLOW VARIANT — never a hardcoded 3-tuple. It iterates the variant's ACTIVE
// levels (CaptureFlowVariant.levels: A→B→C with bottom, A→B without) and
// resolves each level's band via the single level→band map [pitchBandIdForLevel]
// and its segment count via the single [effectiveSegmentsFor] resolver
// (variant counts → legacy band counts → 12). Retuning a variant's counts
// server-side (guided_capture_variant_segments) flows straight through here
// with no code change.
//
// Kept OUT of the pure core (level_progression.dart) because it depends on the
// CaptureLevel taxonomy + config; the core stays config-agnostic and pure.
import '../../../domain/capture/capture_flow_variant.dart';
import '../../../domain/capture/coverage_milestones.dart';
import '../../../domain/entities/capture_config.dart';
import '../analytics/capture_level_events.dart';
import '../ledger/level_capture_ledger_registry.dart';
import 'level_progression.dart';

/// Default min accepted photos per level (the repo has no Dart per-level count
/// config yet — same explicit input the completion gate documents).
const int kDefaultMinAcceptedPerLevel = 1;

/// One [LevelProgressState] per ACTIVE level of [variant] in flow order, sized
/// from [config] via [effectiveSegmentsFor] (which is always `>= 1`, so the
/// gate stays meaningful even on degenerate config).
List<LevelProgressState> levelStatesFromConfig(
  CaptureConfig config, {
  required CaptureFlowVariant variant,
  int minAcceptedCount = kDefaultMinAcceptedPerLevel,
}) {
  return [
    for (final level in variant.levels)
      () {
        final bandId = pitchBandIdForLevel(level);
        return LevelProgressState(
          levelId: bandId,
          levelCode: level.code,
          segmentCount: effectiveSegmentsFor(config, variant, bandId),
          minAcceptedCount: minAcceptedCount,
          minCoveragePct: config.thresholds.minCoveragePct,
        );
      }(),
  ];
}

/// A fresh progression (frontier at the first level) built from [config] for
/// [variant].
LevelProgression initialProgressionFromConfig(
  CaptureConfig config, {
  required CaptureFlowVariant variant,
  int minAcceptedCount = kDefaultMinAcceptedPerLevel,
}) =>
    LevelProgression.of(
      levelStatesFromConfig(
        config,
        variant: variant,
        minAcceptedCount: minAcceptedCount,
      ),
    );

/// A progression SNAPSHOT derived from the LIVE capture data — each level's
/// accepted records in [registry] — instead of the progression controller's
/// state (which the live capture flow does not populate; it sequences levels
/// via GoRouter — see level_progression_provider.dart's SCOPE note). The level
/// shape comes from [levelStatesFromConfig]; the counts come from the SAME
/// source the Summary gate reads (the per-level ledgers), with each level's
/// min-accepted threshold resolved per level code so `isComplete` here can
/// never disagree with the Summary's verdict. Filled = distinct in-range
/// segment indices among accepted records (the ledger analogue of
/// SegmentCoverage.filledCount).
LevelProgression progressionFromLedger(
  CaptureConfig config, {
  required CaptureFlowVariant variant,
  required LevelCaptureLedgerRegistry registry,
}) {
  final thresholds = config.completionThresholds;
  return LevelProgression.of([
    for (final base in levelStatesFromConfig(config, variant: variant))
      () {
        final accepted = registry.ledgerFor(base.levelId).accepted;
        final filled = accepted
            .map((r) => r.segmentIndex)
            .whereType<int>()
            .where((i) => i >= 0 && i < base.segmentCount)
            .toSet()
            .length;
        return base.copyWith(
          filledCount: filled,
          acceptedCount: accepted.length,
          minAcceptedCount: thresholds.minAcceptedFramesFor(base.levelCode),
        );
      }(),
  ]);
}

/// Reconciles a [persisted] progression with the CURRENT [config] + [variant]
/// (either may have changed between sessions): the level SHAPE (order, which
/// levels exist, segment count, thresholds) comes from fresh config+variant;
/// the user's PROGRESS (filled/accepted counts) carries over by levelId where
/// the level still exists; the frontier is clamped into range.
///
/// So a remote-config change that grew a level's segment count re-evaluates
/// that level's completeness against the new target while keeping the frames
/// the user already captured — and a variant switched to `withoutBottom` simply
/// drops the Bottom Ring level (its persisted progress disappears with it).
LevelProgression reconcileWithConfig(
  LevelProgression persisted,
  CaptureConfig config, {
  required CaptureFlowVariant variant,
  int minAcceptedCount = kDefaultMinAcceptedPerLevel,
}) {
  final fresh = levelStatesFromConfig(
    config,
    variant: variant,
    minAcceptedCount: minAcceptedCount,
  );
  final merged = [
    for (final f in fresh)
      () {
        final prior = persisted.stateForId(f.levelId);
        if (prior == null) return f;
        // Carry progress; clamp filled to the (possibly new) segment count.
        final filled =
            prior.filledCount > f.segmentCount ? f.segmentCount : prior.filledCount;
        // Carry the fired milestones, but only those the (re-clamped) coverage
        // still satisfies — so if a config change dropped coverage below a
        // milestone, that milestone becomes eligible to fire again.
        final pct = coveragePercent(filled, f.segmentCount);
        final fired = {
          for (final m in prior.firedMilestones)
            if (pct >= m) m,
        };
        return f.copyWith(
          filledCount: filled,
          acceptedCount: prior.acceptedCount,
          firedMilestones: fired,
        );
      }(),
  ];
  // Keep the frontier on the same level id if it still exists, else clamp.
  final priorCurrentId = persisted.currentLevel.levelId;
  var idx = merged.indexWhere((l) => l.levelId == priorCurrentId);
  if (idx < 0) {
    idx = persisted.currentLevelIndex >= merged.length
        ? merged.length - 1
        : persisted.currentLevelIndex;
  }
  return LevelProgression.of(merged, currentLevelIndex: idx);
}
