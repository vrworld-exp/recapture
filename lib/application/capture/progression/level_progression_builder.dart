// lib/application/capture/progression/level_progression_builder.dart
//
// Builds the ordered level sequence (A→B→C) for the progression core FROM CONFIG —
// never a hardcoded 3-tuple. It iterates the level taxonomy (CaptureLevel.values,
// the repo's level set — there is no separate PitchLevel enum) and resolves each
// level's band + segment count from [CaptureConfig.pitchBands] via the single
// level→band map [pitchBandIdForLevel]. Retuning a band's segment count or
// thresholds server-side flows straight through here with no code change.
//
// Kept OUT of the pure core (level_progression.dart) because it depends on the
// CaptureLevel taxonomy + config; the core stays config-agnostic and pure.
import '../../../domain/capture/coverage_milestones.dart';
import '../../../domain/entities/capture_config.dart';
import '../analytics/capture_level_events.dart';
import 'level_progression.dart';

/// Default min accepted photos per level (the repo has no Dart per-level count
/// config yet — same explicit input the completion gate documents).
const int kDefaultMinAcceptedPerLevel = 1;

/// One [LevelProgressState] per [CaptureLevel] in flow order, sized from [config].
/// A level whose band is missing from config falls back to the first band's
/// segment count (never 0 → the gate stays meaningful).
List<LevelProgressState> levelStatesFromConfig(
  CaptureConfig config, {
  int minAcceptedCount = kDefaultMinAcceptedPerLevel,
}) {
  return [
    for (final level in CaptureLevel.values)
      () {
        final bandId = pitchBandIdForLevel(level);
        final band = config.pitchBands.firstWhere(
          (b) => b.id == bandId,
          orElse: () => config.pitchBands.isNotEmpty
              ? config.pitchBands.first
              : PitchBand(
                  id: bandId, minDegrees: 0, maxDegrees: 90, segments: 12),
        );
        return LevelProgressState(
          levelId: bandId,
          levelCode: level.code,
          segmentCount: band.segments,
          minAcceptedCount: minAcceptedCount,
          minCoveragePct: config.thresholds.minCoveragePct,
        );
      }(),
  ];
}

/// A fresh progression (frontier at the first level) built from [config].
LevelProgression initialProgressionFromConfig(
  CaptureConfig config, {
  int minAcceptedCount = kDefaultMinAcceptedPerLevel,
}) =>
    LevelProgression.of(
      levelStatesFromConfig(config, minAcceptedCount: minAcceptedCount),
    );

/// Reconciles a [persisted] progression with the CURRENT [config] (config may have
/// changed between sessions): the level SHAPE (order, segment count, thresholds)
/// comes from fresh config; the user's PROGRESS (filled/accepted counts) carries
/// over by levelId where it still exists; the frontier is clamped into range.
///
/// So a remote-config change that, say, grew a level's segment count re-evaluates
/// that level's completeness against the new target while keeping the frames the
/// user already captured. A level dropped from config simply disappears; a new one
/// starts empty.
LevelProgression reconcileWithConfig(
  LevelProgression persisted,
  CaptureConfig config, {
  int minAcceptedCount = kDefaultMinAcceptedPerLevel,
}) {
  final fresh = levelStatesFromConfig(config, minAcceptedCount: minAcceptedCount);
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
