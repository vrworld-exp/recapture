// lib/domain/entities/capture_summary.dart
import 'package:freezed_annotation/freezed_annotation.dart';

part 'capture_summary.freezed.dart';

/// Response from CaptureChannel.stopCapture().
///
/// Mirrors the native stub response shape:
///   { status: String, totalPhotos: int }
///
/// P3 TODO: `totalPhotos` will reflect the real accepted photo count for
/// the session once CameraX/AVFoundation capture logic is implemented.
@freezed
class CaptureSummary with _$CaptureSummary {
  const factory CaptureSummary({
    required String status,
    required int totalPhotos,
  }) = _CaptureSummary;

  /// Parses the raw Map returned by the native MethodChannel.
  factory CaptureSummary.fromMap(Map<dynamic, dynamic> map) {
    return CaptureSummary(
      status: map['status'] as String,
      totalPhotos: map['totalPhotos'] as int,
    );
  }
}
