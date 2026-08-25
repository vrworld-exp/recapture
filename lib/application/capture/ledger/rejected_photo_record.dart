// lib/application/capture/ledger/rejected_photo_record.dart
//
// One rejected capture attempt. The metric fields are nullable because the
// reasons populate different ones: `blur` carries [blurScore], `motion` carries
// [stabilityScore], and `overlap` carries NEITHER (and no [framePath]) — an
// overlap rejection is decided pre-capture, before any JPEG is written
// (RingCoverageEngine.evaluateCapture runs before triggering the capture).
import 'package:flutter/foundation.dart';

import 'photo_rejection_reason.dart';

@immutable
class RejectedPhotoRecord {
  const RejectedPhotoRecord({
    required this.reason,
    this.framePath,
    this.blurScore,
    this.stabilityScore,
    required this.yawDegrees,
    required this.sensorTimestampNs,
  });

  final PhotoRejectionReason reason;

  /// Absolute path of the rejected frame, if one was written before rejection.
  /// Null for overlap rejections that occur pre-capture.
  final String? framePath;

  /// Sharpness score if [reason] == blur, else null.
  final double? blurScore;

  /// Stillness score [0,1] if [reason] == motion, else null.
  final double? stabilityScore;

  /// Device yaw in DEGREES at the rejected attempt.
  final double yawDegrees;

  /// Camera-aligned sensor timestamp in NANOSECONDS of the attempt.
  final int sensorTimestampNs;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RejectedPhotoRecord &&
          reason == other.reason &&
          framePath == other.framePath &&
          blurScore == other.blurScore &&
          stabilityScore == other.stabilityScore &&
          yawDegrees == other.yawDegrees &&
          sensorTimestampNs == other.sensorTimestampNs;

  @override
  int get hashCode => Object.hash(
        reason,
        framePath,
        blurScore,
        stabilityScore,
        yawDegrees,
        sensorTimestampNs,
      );

  @override
  String toString() => 'RejectedPhotoRecord(reason: $reason, '
      'framePath: $framePath, blurScore: $blurScore, '
      'stabilityScore: $stabilityScore, '
      'yawDegrees: ${yawDegrees.toStringAsFixed(2)}, '
      'sensorTimestampNs: $sensorTimestampNs)';
}
