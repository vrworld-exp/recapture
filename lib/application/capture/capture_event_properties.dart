// lib/application/capture/capture_event_properties.dart
//
// Shared property set carried by every capture-decision analytics event
// (photo_captured / photo_rejected_blur / photo_rejected_motion /
// photo_warned_exposure). Grounded entirely on types that exist in this repo —
// there is no `PitchLevel` enum, no `SensorFrame`, and no `StabilityScore.confidence`
// (the original feature brief assumed those; see the grounded analytics layer doc).
//
// Sources of each field at the capture-attempt instant:
//   - pitchBandId / pitchDegrees  → CapturePitchGuide.activeBand(config, pitchDeg)
//                                    over SmoothedOrientation.pitchDegrees (DEGREES).
//   - stabilityScore / gyroMag / linAccelMag / sensorTimestampNs
//                                  → the most recent StabilityScoreEvent
//                                    (lib/platform/stability_channel.dart).
//   - deviceModel / platform      → device info captured once at flow init.
import 'package:flutter/foundation.dart';

/// Properties common to all four capture analytics events. `const`-constructible
/// (no clamping, no validation — the upstream producers own those invariants).
@immutable
class CaptureEventProperties {
  const CaptureEventProperties({
    required this.pitchBandId,
    required this.pitchDegrees,
    required this.stabilityScore,
    required this.gyroMag,
    required this.linAccelMag,
    required this.sensorTimestampNs,
    required this.deviceModel,
    required this.platform,
  });

  /// The active [PitchBand.id] (e.g. `"low"`/`"mid"`/`"high"`) the device was
  /// aimed at, or `null` when the pitch is outside every configured band. Bands
  /// are server-tunable, so this is the band id, NOT a fixed enum name.
  final String? pitchBandId;

  /// Device pitch in DEGREES at the attempt (`SmoothedOrientation.pitchDegrees`).
  final double pitchDegrees;

  /// Continuous stillness score in [0, 1] from the most recent
  /// [StabilityScoreEvent] (1.0 = perfectly still). Not clamped here.
  final double stabilityScore;

  /// Gyro magnitude (rad/s) at the attempt — quantifies rotational motion.
  final double gyroMag;

  /// Gravity-removed linear-accel magnitude (m/s²) at the attempt — quantifies
  /// translational motion. (Replaces the brief's fictional `confidence`.)
  final double linAccelMag;

  /// Camera-aligned (CLOCK_MONOTONIC) sensor timestamp in NANOSECONDS of the
  /// frame used for the decision. (The native sensor clock is ns, not µs.)
  final int sensorTimestampNs;

  /// Device model string (captured once at flow init; `'unknown'` if unavailable).
  final String deviceModel;

  /// `'android'` or `'ios'`. Validation is the call site's responsibility — this
  /// value type stores whatever string it is given.
  final String platform;

  Map<String, Object?> toMap() => {
        'pitch_band': pitchBandId,
        'pitch_degrees': pitchDegrees,
        'stability_score': stabilityScore,
        'gyro_mag': gyroMag,
        'lin_accel_mag': linAccelMag,
        'sensor_timestamp_ns': sensorTimestampNs,
        'device_model': deviceModel,
        'platform': platform,
      };
}
