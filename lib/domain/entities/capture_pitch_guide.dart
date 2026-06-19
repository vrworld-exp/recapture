// lib/domain/entities/capture_pitch_guide.dart
//
// Pure Dart — NO Flutter/Riverpod imports. Answers "is the device aimed at a
// capture band?" from the device pitch (in DEGREES — e.g.
// SmoothedOrientation.pitchDegrees from lib/platform/imu_rotation_channel.dart)
// against the SERVER-TUNABLE [CaptureConfig.pitchBands]. Bands are NOT hardcoded
// here — they come from remote config (sanitized remote → cache → bundled
// defaults), so adding/retuning a band needs no app release and no change to
// this file.
import 'capture_config.dart';

/// Stateless band-membership helpers over the config-driven [PitchBand] slices.
///
/// Membership follows the [PitchBand] contract exactly: `minDegrees` inclusive,
/// `maxDegrees` exclusive — so the bands tile the capture sphere without overlap
/// and a given pitch maps to at most one band. All methods are pure + static.
abstract final class CapturePitchGuide {
  CapturePitchGuide._();

  /// True iff [pitchDegrees] lies in [band): `minDegrees <= pitch < maxDegrees`.
  ///
  /// A `NaN`/`Infinity` pitch (broken sensor read) yields `false` by IEEE-754
  /// comparison semantics — never throws, no guard needed.
  static bool isInBand(PitchBand band, double pitchDegrees) =>
      pitchDegrees >= band.minDegrees && pitchDegrees < band.maxDegrees;

  /// The band [pitchDegrees] currently falls into, or `null` if it is outside
  /// every band in [config]. Bands are non-overlapping (per the contract), so
  /// the first match is the only match.
  static PitchBand? activeBand(CaptureConfig config, double pitchDegrees) {
    for (final band in config.pitchBands) {
      if (isInBand(band, pitchDegrees)) return band;
    }
    return null;
  }
}
