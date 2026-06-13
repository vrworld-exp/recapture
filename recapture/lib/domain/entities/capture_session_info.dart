// lib/domain/entities/capture_session_info.dart
import 'package:freezed_annotation/freezed_annotation.dart';

part 'capture_session_info.freezed.dart';

/// Response from CaptureChannel.startCapture().
///
/// Mirrors the native stub response shape:
///   { status: String, sessionId: String }
///
/// P3 TODO: `status` will reflect real session initialization outcomes
/// (e.g. "started", "camera_unavailable", "permission_denied") once
/// CameraX/AVFoundation initialization is implemented.
@freezed
class CaptureSessionInfo with _$CaptureSessionInfo {
  const factory CaptureSessionInfo({
    required String status,
    required String sessionId,
  }) = _CaptureSessionInfo;

  /// Parses the raw Map returned by the native MethodChannel.
  factory CaptureSessionInfo.fromMap(Map<dynamic, dynamic> map) {
    return CaptureSessionInfo(
      status: map['status'] as String,
      sessionId: map['sessionId'] as String,
    );
  }
}
