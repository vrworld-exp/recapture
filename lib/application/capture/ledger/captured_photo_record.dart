// lib/application/capture/ledger/captured_photo_record.dart
//
// One accepted photo within a guided-capture level — the ledger's record, NOT
// the analytics event (PhotoCapturedEvent is fire-and-forget telemetry; this is
// the queryable UI/progress record). Mirrors that event's data, grounded on the
// repo's real conventions: the segment is the ring engine's INT index (there is
// no RingSegment value type — see segment_capture_decision.dart); angles are
// DEGREES (SmoothedOrientation convention) and the sensor timestamp is
// NANOSECONDS (camera-aligned CLOCK_MONOTONIC), matching CaptureEventProperties.
import 'package:flutter/foundation.dart';

@immutable
class CapturedPhotoRecord {
  const CapturedPhotoRecord({
    required this.segmentIndex,
    required this.framePath,
    required this.blurScore,
    required this.meanLuminance,
    required this.yawDegrees,
    required this.pitchDegrees,
    required this.sensorTimestampNs,
  });

  /// The ring segment index this photo fills (RingCoverageEngine's unit). Null
  /// for levels without segment-based overlap tracking (a future single-shot
  /// level); Level A (Eye Ring) always populates it.
  final int? segmentIndex;

  /// Absolute path of the written JPEG.
  final String framePath;

  /// Sharpness score (variance of Laplacian) of the accepted frame.
  final double blurScore;

  /// Mean luminance (0–255) of the accepted frame.
  final double meanLuminance;

  /// Device yaw in DEGREES at capture (SmoothedOrientation.yawDegrees).
  final double yawDegrees;

  /// Camera tilt in DEGREES at capture on the 0–180° scale
  /// (SmoothedOrientation.cameraTiltDegrees — the value the capture was gated
  /// on). Field name kept for codec/manifest wire compatibility.
  final double pitchDegrees;

  /// Camera-aligned sensor timestamp in NANOSECONDS of the captured frame.
  final int sensorTimestampNs;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CapturedPhotoRecord &&
          segmentIndex == other.segmentIndex &&
          framePath == other.framePath &&
          blurScore == other.blurScore &&
          meanLuminance == other.meanLuminance &&
          yawDegrees == other.yawDegrees &&
          pitchDegrees == other.pitchDegrees &&
          sensorTimestampNs == other.sensorTimestampNs;

  @override
  int get hashCode => Object.hash(
        segmentIndex,
        framePath,
        blurScore,
        meanLuminance,
        yawDegrees,
        pitchDegrees,
        sensorTimestampNs,
      );

  @override
  String toString() => 'CapturedPhotoRecord(segment: $segmentIndex, '
      'framePath: $framePath, blurScore: ${blurScore.toStringAsFixed(2)}, '
      'meanLuminance: ${meanLuminance.toStringAsFixed(2)}, '
      'yawDegrees: ${yawDegrees.toStringAsFixed(2)}, '
      'pitchDegrees: ${pitchDegrees.toStringAsFixed(2)}, '
      'sensorTimestampNs: $sensorTimestampNs)';
}
