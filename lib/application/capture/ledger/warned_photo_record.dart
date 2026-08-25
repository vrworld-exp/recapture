// lib/application/capture/ledger/warned_photo_record.dart
//
// A photo capture where exposure was flagged (dark/bright). Exposure is WARN-only
// in this pipeline (see exposure_policy.dart) and ORTHOGONAL to the accept/reject
// decision — a warned photo can ALSO appear in the accepted list if it cleared the
// blur, motion, and overlap gates despite the warning. Correlation with an accepted
// record is by framePath (see LevelCaptureLedger.hasAcceptedPhotosWithWarnings).
import 'package:flutter/foundation.dart';

@immutable
class WarnedPhotoRecord {
  const WarnedPhotoRecord({
    required this.framePath,
    required this.isUnderexposed,
    required this.isOverexposed,
    required this.meanLuminance,
    required this.sensorTimestampNs,
  });

  /// Absolute path of the JPEG that triggered the warning. May equal a
  /// CapturedPhotoRecord.framePath if the photo was ultimately accepted.
  final String framePath;

  /// ExposureBand.dark.
  final bool isUnderexposed;

  /// ExposureBand.bright.
  final bool isOverexposed;

  /// Mean luminance (0–255) at warning time.
  final double meanLuminance;

  /// Camera-aligned sensor timestamp in NANOSECONDS.
  final int sensorTimestampNs;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WarnedPhotoRecord &&
          framePath == other.framePath &&
          isUnderexposed == other.isUnderexposed &&
          isOverexposed == other.isOverexposed &&
          meanLuminance == other.meanLuminance &&
          sensorTimestampNs == other.sensorTimestampNs;

  @override
  int get hashCode => Object.hash(
        framePath,
        isUnderexposed,
        isOverexposed,
        meanLuminance,
        sensorTimestampNs,
      );

  @override
  String toString() => 'WarnedPhotoRecord(framePath: $framePath, '
      'isUnderexposed: $isUnderexposed, isOverexposed: $isOverexposed, '
      'meanLuminance: ${meanLuminance.toStringAsFixed(2)}, '
      'sensorTimestampNs: $sensorTimestampNs)';
}
