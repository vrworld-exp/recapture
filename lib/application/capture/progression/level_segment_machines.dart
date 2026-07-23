// lib/application/capture/progression/level_segment_machines.dart
//
// Builds one independent [LevelSegmentMachine] per ACTIVE level of the flow
// variant — the same source, the SAME band resolution, and the SAME segment
// resolver ([effectiveSegmentsFor]) as `levelStatesFromConfig`
// (level_progression_builder.dart), so a level's machine and its progression
// summary can never disagree on segment count or which band it is.
//
// Each level resolves its band via the single [pitchBandIdForLevel] map and its
// count via [effectiveSegmentsFor] (variant counts → legacy band counts → 16),
// so the 16-16-16 / 24-24 variant counts come straight from remote config with
// no code change. The instances are fully independent; the level progression
// controller composes them via the machine's uniform interface.
//
// Kept OUT of the pure machine (domain/capture/level_segment_machine.dart)
// because it depends on the CaptureLevel taxonomy + config; the machine stays
// config-agnostic and pure.
import '../../../domain/capture/capture_flow_variant.dart';
import '../../../domain/capture/capture_shape_mode.dart';
import '../../../domain/capture/level_segment_machine.dart';
import '../../../domain/entities/capture_config.dart';
import '../analytics/capture_level_events.dart';

/// The independent per-level segment machines for [variant]'s active levels in
/// flow order (A→B[→C]), each sized and banded from [config].
List<LevelSegmentMachine> levelSegmentMachinesFromConfig(
  CaptureConfig config, {
  required CaptureFlowVariant variant,
  CaptureShapeMode mode = CaptureShapeMode.full,
  int fillThreshold = 1,
}) =>
    [
      for (final level in activeCaptureLevels(variant, mode))
        levelSegmentMachineFor(
          level,
          config,
          variant: variant,
          fillThreshold: fillThreshold,
        ),
    ];

/// One independent [LevelSegmentMachine] for [level], banded from [config] and
/// sized via [effectiveSegmentsFor] under [variant]. A level whose band is
/// missing from config still gets a valid band shell (never an empty ring).
LevelSegmentMachine levelSegmentMachineFor(
  CaptureLevel level,
  CaptureConfig config, {
  required CaptureFlowVariant variant,
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
    segmentCount: effectiveSegmentsFor(config, variant, bandId),
    fillThreshold: fillThreshold,
  );
}
