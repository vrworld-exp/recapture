// lib/application/capture/capture_analytics_event.dart
//
// Sealed hierarchy for the four capture-decision analytics events. Each subtype
// maps to exactly one canonical name in [AnalyticsEvents]. Grounded on the real
// quality/stability types (BlurBand + BlurThresholdPolicy, ExposureBand, the
// stability gate thresholds) — not the brief's fictional FrameQualityResult.
//
// Event names are sourced from [AnalyticsEvents] (single source of truth, shared
// with the server schema). Each [toMap] spreads the shared [properties] first,
// then layers event-specific keys.
import 'package:flutter/foundation.dart';

import '../../platform/blur_policy.dart';
import '../../platform/exposure_policy.dart';
import '../../utils/analytics.dart';
import 'capture_event_properties.dart';

/// Sealed base for the capture pipeline analytics events. `sealed` so any future
/// subtype forces an exhaustive update of every `switch` over the hierarchy.
sealed class CaptureAnalyticsEvent {
  const CaptureAnalyticsEvent({required this.properties});

  /// Properties common to all four events (pitch/stability/device/platform).
  final CaptureEventProperties properties;

  /// The canonical snake_case event name (from [AnalyticsEvents]).
  String get name;

  /// Shared properties spread first, then event-specific keys. NOTE: an
  /// event-specific key with the same name as a shared key would silently win —
  /// none currently collide; keep it that way.
  Map<String, Object?> toMap();
}

// ─── photo_captured ──────────────────────────────────────────────────────────

/// A capture attempt succeeded and a frame was written to disk.
@immutable
class PhotoCapturedEvent extends CaptureAnalyticsEvent {
  const PhotoCapturedEvent({
    required super.properties,
    required this.blurScore,
    required this.blurBand,
    required this.meanLuminance,
    required this.exposureBand,
    required this.framePath,
  });

  /// Sharpness score (variance of Laplacian) of the accepted frame; higher = sharper.
  final double blurScore;

  /// The [BlurBand] the score classified into (expected `accept`, possibly `warn`).
  final BlurBand blurBand;

  /// Mean luminance (0–255) of the accepted frame.
  final double meanLuminance;

  /// The [ExposureBand] the mean luminance classified into.
  final ExposureBand exposureBand;

  /// Absolute path of the written frame.
  final String framePath;

  @override
  String get name => AnalyticsEvents.photoCaptured;

  @override
  Map<String, Object?> toMap() => {
        ...properties.toMap(),
        'blur_score': blurScore,
        'blur_band': blurBand.name,
        'mean_luminance': meanLuminance,
        'exposure_band': exposureBand.name,
        'frame_path': framePath,
      };
}

// ─── photo_rejected_blur ─────────────────────────────────────────────────────

/// A capture attempt was rejected because the sharpness score fell in the blur
/// REJECT band. Mutually exclusive with [PhotoCapturedEvent] for one attempt.
@immutable
class PhotoRejectedBlurEvent extends CaptureAnalyticsEvent {
  const PhotoRejectedBlurEvent({
    required super.properties,
    required this.blurScore,
    required this.blurRejectBelow,
  });

  /// The sharpness score that triggered the rejection (< [blurRejectBelow]).
  final double blurScore;

  /// The active reject threshold — `BlurThresholdPolicy.rejectBelow` (default
  /// [BlurThresholdPolicy.defaultRejectBelow]). A real Dart constant exists, so
  /// pass it through; never hardcode 0.0.
  final double blurRejectBelow;

  @override
  String get name => AnalyticsEvents.photoRejectedBlur;

  @override
  Map<String, Object?> toMap() => {
        ...properties.toMap(),
        'blur_score': blurScore,
        'blur_reject_below': blurRejectBelow,
      };
}

// ─── photo_rejected_motion ───────────────────────────────────────────────────

/// A capture attempt was rejected because the stability gate was not open (the
/// device was moving). Mutually exclusive with [PhotoCapturedEvent] for one
/// attempt. The motion magnitudes live in the shared [properties]
/// (gyroMag/linAccelMag); this event adds the gate thresholds they failed.
@immutable
class PhotoRejectedMotionEvent extends CaptureAnalyticsEvent {
  const PhotoRejectedMotionEvent({
    required super.properties,
    required this.stabilityScoreAtRejection,
    required this.gyroThreshRadS,
    required this.accelThreshG,
  });

  /// The stillness score at rejection (low — the gate was not open).
  final double stabilityScoreAtRejection;

  /// The gyro gate threshold (rad/s) the motion exceeded
  /// (`StabilityGateStream.defaultGyroThreshRadS` unless remote-tuned).
  final double gyroThreshRadS;

  /// The linear-accel gate threshold (in g) the motion exceeded
  /// (`StabilityGateStream.defaultAccelThreshG` unless remote-tuned).
  final double accelThreshG;

  @override
  String get name => AnalyticsEvents.photoRejectedMotion;

  @override
  Map<String, Object?> toMap() => {
        ...properties.toMap(),
        'stability_score_at_rejection': stabilityScoreAtRejection,
        'gyro_thresh_rad_s': gyroThreshRadS,
        'accel_thresh_g': accelThreshG,
      };
}

// ─── photo_warned_exposure ───────────────────────────────────────────────────

/// The frame's exposure was DARK or BRIGHT at the capture attempt. Fires
/// INDEPENDENTLY of the capture/rejection outcome (exposure is warn-only and
/// never gates a capture), so it may co-occur with any other capture event.
@immutable
class PhotoWarnedExposureEvent extends CaptureAnalyticsEvent {
  const PhotoWarnedExposureEvent({
    required super.properties,
    required this.exposureBand,
    required this.meanLuminance,
    required this.darkBelow,
    required this.brightAbove,
  });

  /// The warning band — [ExposureBand.dark] or [ExposureBand.bright]. (Call sites
  /// only emit this event when `exposureBand.isWarning`.)
  final ExposureBand exposureBand;

  /// Mean luminance (0–255) at the warning.
  final double meanLuminance;

  /// The active dark threshold (`ExposureThresholdPolicy.darkBelow`).
  final double darkBelow;

  /// The active bright threshold (`ExposureThresholdPolicy.brightAbove`).
  final double brightAbove;

  /// Derived convenience: the warning was an underexposure (too dark).
  bool get isUnderexposed => exposureBand == ExposureBand.dark;

  /// Derived convenience: the warning was an overexposure (too bright).
  bool get isOverexposed => exposureBand == ExposureBand.bright;

  @override
  String get name => AnalyticsEvents.photoWarnedExposure;

  @override
  Map<String, Object?> toMap() => {
        ...properties.toMap(),
        'exposure_band': exposureBand.name,
        'is_underexposed': isUnderexposed,
        'is_overexposed': isOverexposed,
        'mean_luminance': meanLuminance,
        'dark_below': darkBelow,
        'bright_above': brightAbove,
      };
}
