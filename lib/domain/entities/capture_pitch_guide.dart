// lib/domain/entities/capture_pitch_guide.dart
//
// Pure Dart — NO Flutter/Riverpod imports. Answers "is the device aimed at a
// capture band?" from the CAMERA TILT in DEGREES on the 0–180° scale (0 =
// camera at the sky, 90 = horizon, 180 = at the ground —
// SmoothedOrientation.cameraTiltDegrees, see lib/domain/capture/camera_tilt.dart)
// against the SERVER-TUNABLE [CaptureConfig.pitchBands] (same scale, min
// inclusive / max exclusive). Bands are NOT hardcoded here — they come from
// remote config (sanitized remote → cache → bundled defaults), so
// adding/retuning a band needs no app release and no change to this file.
import 'capture_config.dart';

/// Stateless band-membership helpers over the config-driven [PitchBand] slices.
///
/// Membership follows the [PitchBand] contract exactly: `minDegrees` inclusive,
/// `maxDegrees` exclusive — so the bands tile the capture sphere without overlap
/// and a given pitch maps to at most one band. All methods are pure + static.
abstract final class CapturePitchGuide {
  CapturePitchGuide._();

  /// True iff [tiltDegrees] lies in [band): `minDegrees <= tilt < maxDegrees`.
  ///
  /// A `NaN`/`Infinity` tilt (broken sensor read) yields `false` by IEEE-754
  /// comparison semantics — never throws, no guard needed.
  static bool isInBand(PitchBand band, double tiltDegrees) =>
      tiltDegrees >= band.minDegrees && tiltDegrees < band.maxDegrees;

  /// The band [tiltDegrees] currently falls into, or `null` if it is outside
  /// every band in [config]. Bands are non-overlapping (per the contract), so
  /// the first match is the only match.
  static PitchBand? activeBand(CaptureConfig config, double tiltDegrees) {
    for (final band in config.pitchBands) {
      if (isInBand(band, tiltDegrees)) return band;
    }
    return null;
  }
}
