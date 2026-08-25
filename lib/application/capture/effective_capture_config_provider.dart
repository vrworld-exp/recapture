// lib/application/capture/effective_capture_config_provider.dart
//
// The MODE-AWARE view of the live [CaptureConfig] that the capture screen's band
// resolution reads. In FULL mode it is the plain config, byte-for-byte. In MESHY
// mode it remaps the EYE ring's ('mid') pitch band to the HARD eye→top window
// [60,180) so that the band resolver, the tilt meter, the gauge, AND the shutter
// gate all share ONE band — guidance and enforcement can never target different
// windows.
//
// WHY A CONFIG REMAP, NOT A CALL-SITE SPECIAL-CASE: the eye ring's band is read
// through [resolvedPitchBandProvider] (override → remote/cache → bundled). Every
// HUD element that shows or enforces the band flows from that one resolution, so
// changing the config it resolves against is the single seam that moves all of
// them together. Special-casing degrees at individual call sites would let the
// tilt meter and the shutter gate drift apart.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/capture/capture_mode.dart';
import '../../domain/entities/capture_config.dart';
import '../config/config_notifier.dart';
import 'capture_mode_provider.dart';

/// The client band id of the EYE ring — the one band Meshy captures. Mirrors
/// `pitchBandIdForLevel(CaptureLevel.a)`.
const String kMeshyEyeBandId = 'mid';

/// The HARD Meshy eye→top tilt window on the 0–180° camera-tilt scale (0 = at
/// the sky, 90 = eye level, 180 = at the ground): from ~30° above eye level
/// through fully looking down at the object's top. `min` inclusive, `max`
/// exclusive — see [PitchBand]. "No bottom" = the camera never tips up toward
/// the underside (never below [kMeshyEyeMinDegrees]).
///
/// This is the ONE knob to retune if product moves the window; keep min
/// inclusive / max exclusive.
const double kMeshyEyeMinDegrees = 60;
const double kMeshyEyeMaxDegrees = 180;

/// The capture config the band resolution should use for the CURRENT mode.
///
/// - full  → the live [captureConfigProvider], unchanged.
/// - meshy → the same config with its EYE band ('mid') forced to the hard
///   eye→top window [60,180) (and sized to the single ring of 6). Every other
///   band is left untouched; only 'mid' is ever consulted in Meshy mode (the
///   flow runs Level A alone — see `activeCaptureLevels`).
final effectiveCaptureConfigProvider = Provider<CaptureConfig>((ref) {
  final config = ref.watch(captureConfigProvider);
  final mode = ref.watch(captureModeProvider);
  if (mode != CaptureMode.meshy) return config;
  return config.copyWith(
    pitchBands: [
      for (final band in config.pitchBands)
        if (band.id == kMeshyEyeBandId)
          band.copyWith(
            minDegrees: kMeshyEyeMinDegrees,
            maxDegrees: kMeshyEyeMaxDegrees,
            segments: 6,
          )
        else
          band,
    ],
  );
});
