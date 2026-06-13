// lib/domain/entities/capture_photo_result.dart
import 'package:freezed_annotation/freezed_annotation.dart';

part 'capture_photo_result.freezed.dart';

/// Response from CaptureChannel.takePicture().
///
/// Mirrors the native stub response shape:
///   { filePath: String, timestamp: int, blurScore: double, accepted: bool }
///
/// P3 TODO: `blurScore` and `accepted` will reflect real Laplacian variance
/// blur detection (threshold <40 reject, 40-80 warn, >80 accept per PRD
/// Photo Acceptance Criteria) once native capture is implemented.
@freezed
class CapturePhotoResult with _$CapturePhotoResult {
  const factory CapturePhotoResult({
    required String filePath,

    /// Capture timestamp, converted from native milliseconds-since-epoch.
    required DateTime timestamp,

    /// Laplacian variance blur score.
    /// <40 = reject, 40-80 = warn, >80 = accept (per PRD thresholds).
    required double blurScore,

    /// Whether this photo passed quality checks and counts toward
    /// the ring segment coverage.
    required bool accepted,
  }) = _CapturePhotoResult;

  /// Parses the raw Map returned by the native MethodChannel.
  /// Converts the native `timestamp` (int, ms-since-epoch) to [DateTime].
  factory CapturePhotoResult.fromMap(Map<dynamic, dynamic> map) {
    return CapturePhotoResult(
      filePath: map['filePath'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
      blurScore: (map['blurScore'] as num).toDouble(),
      accepted: map['accepted'] as bool,
    );
  }
}
