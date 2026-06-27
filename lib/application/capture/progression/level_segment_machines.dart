// lib/application/capture/progression/level_segment_machines.dart
//
// Builds one independent [LevelSegmentMachine] per level (A→B→C) FROM CONFIG —
// the same source, and the SAME band resolution, as `levelStatesFromConfig`
// (level_progression_builder.dart), so a level's machine and its progression
// summary can never disagree on segment count or which band it is.
//
// Each level resolves its band via the single [pitchBandIdForLevel] map and takes
// THAT band's `segments` as its per-level count — so Top/Bottom rings get their
// own counts (which may differ from the Eye Ring), straight from remote config
// with no code change. The instances are fully independent; the level progression
// controller composes them via the machine's uniform interface.
//
// Kept OUT of the pure machine (domain/capture/level_segment_machine.dart)
// because it depends on the CaptureLevel taxonomy + config; the machine stays
// config-agnostic and pure.
import '../../../domain/capture/level_segment_machine.dart';
import '../../../domain/entities/capture_config.dart';
import '../analytics/capture_level_events.dart';

/// The independent per-level segment machines in flow order (A→B→C), each sized
/// and banded from [config]. A level whose band is missing from config falls back
/// to the first band (never an empty ring), mirroring [levelStatesFromConfig].
List<LevelSegmentMachine> levelSegmentMachinesFromConfig(
  CaptureConfig config, {
  int fillThreshold = 1,
}) =>
    [
      for (final level in CaptureLevel.values)
        levelSegmentMachineFor(level, config, fillThreshold: fillThreshold),
    ];

/// One independent [LevelSegmentMachine] for [level], banded + sized from [config].
LevelSegmentMachine levelSegmentMachineFor(
  CaptureLevel level,
  CaptureConfig config, {
  int fillThreshold = 1,
}) {
  final bandId = pitchBandIdForLevel(level);
  final band = config.pitchBands.firstWhere(
    (b) => b.id == bandId,
    orElse: () => config.pitchBands.isNotEmpty
        ? config.pitchBands.first
        : PitchBand(id: bandId, minDegrees: 0, maxDegrees: 90, segments: 12),
  );
  return LevelSegmentMachine(
    levelId: bandId,
    levelCode: level.code,
    band: band,
    fillThreshold: fillThreshold,
  );
}
