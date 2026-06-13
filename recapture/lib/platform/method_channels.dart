// lib/platform/method_channels.dart
import 'package:flutter/services.dart';
import '../domain/entities/capture_session_info.dart';
import '../domain/entities/capture_summary.dart';
import '../domain/entities/capture_photo_result.dart';
import '../domain/entities/sensor_frame.dart';
import '../utils/constants.dart';

/// Exception thrown when a CaptureChannel call fails.
///
/// Wraps both [PlatformException] (native code threw an error) and
/// [MissingPluginException] (channel not registered — usually a
/// native-side registration bug, see CaptureModule.kt /
/// CaptureModuleController.swift).
class CaptureChannelException implements Exception {
  const CaptureChannelException(this.method, this.message, [this.cause]);

  /// The CaptureChannel method that failed (e.g. 'startCapture').
  final String method;

  /// Human-readable error message.
  final String message;

  /// The underlying exception, if any (PlatformException or
  /// MissingPluginException).
  final Object? cause;

  @override
  String toString() => 'CaptureChannelException($method): $message'
      '${cause != null ? ' (cause: $cause)' : ''}';
}

/// Typed wrapper around the native capture MethodChannel.
///
/// Channel name: com.mayasabhaxr.recapture/capture (AppConfig.channelCapture)
/// Native implementations:
///   - Android: CaptureModule.kt
///   - iOS: CaptureModuleController.swift
///
/// STATUS: Both native sides are currently STUBS (Phase P0) returning
/// static mock data. This Dart wrapper is the permanent API — P3 replaces
/// only the native method bodies, not this class's signatures.
///
/// All methods throw [CaptureChannelException] on failure — never let
/// a raw [PlatformException] or [MissingPluginException] escape to callers.
class CaptureChannel {
  CaptureChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(AppConfig.channelCapture);

  final MethodChannel _channel;

  // Method name constants — must match native CaptureModule.kt /
  // CaptureModuleController.swift companion object / enum constants exactly.
  static const String _methodStartCapture = 'startCapture';
  static const String _methodStopCapture = 'stopCapture';
  static const String _methodTakePicture = 'takePicture';
  static const String _methodGetOrientation = 'getOrientation';

  /// Starts a capture session.
  ///
  /// STUB (P0): returns a static session ID. P3: initializes camera +
  /// IMU listener natively and returns real session state.
  ///
  /// Throws [CaptureChannelException] if the native channel is unreachable
  /// or the native side reports an error.
  Future<CaptureSessionInfo> startCapture() async {
    final result = await _invoke(_methodStartCapture);
    return CaptureSessionInfo.fromMap(result);
  }

  /// Stops the active capture session.
  ///
  /// STUB (P0): returns totalPhotos: 0. P3: returns the real accepted
  /// photo count for the session.
  ///
  /// Throws [CaptureChannelException] if the native channel is unreachable
  /// or the native side reports an error.
  Future<CaptureSummary> stopCapture() async {
    final result = await _invoke(_methodStopCapture);
    return CaptureSummary.fromMap(result);
  }

  /// Captures a single photo and runs quality checks.
  ///
  /// STUB (P0): returns a static file path and blurScore: 95.0 (always
  /// accepted). P3: triggers real camera capture, runs Laplacian variance
  /// blur detection and exposure checks, returns real metadata.
  ///
  /// Throws [CaptureChannelException] if the native channel is unreachable
  /// or the native side reports an error.
  Future<CapturePhotoResult> takePicture() async {
    final result = await _invoke(_methodTakePicture);
    return CapturePhotoResult.fromMap(result);
  }

  /// Returns the latest device orientation reading.
  ///
  /// STUB (P0): returns all-zero SensorFrame. P3: returns real IMU data
  /// from TYPE_ROTATION_VECTOR (Android) / CMDeviceMotion (iOS).
  ///
  /// NOTE: This is a polled single-shot call. P3 may replace this with
  /// an EventChannel stream for continuous 50-100Hz updates — see
  /// SensorFrame's doc comment. If that happens, this method may be
  /// deprecated in favor of a `Stream<SensorFrame> get orientationStream`.
  ///
  /// Throws [CaptureChannelException] if the native channel is unreachable
  /// or the native side reports an error.
  Future<SensorFrame> getOrientation() async {
    final result = await _invoke(_methodGetOrientation);
    return SensorFrame.fromMap(result);
  }

  /// Internal helper: invokes [method] on the channel, converts
  /// [PlatformException] and [MissingPluginException] into
  /// [CaptureChannelException], and returns the raw response Map.
  Future<Map<dynamic, dynamic>> _invoke(String method) async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(method);

      if (result == null) {
        throw CaptureChannelException(
          method,
          'Native side returned null for method "$method"',
        );
      }

      return result;
    } on MissingPluginException catch (e) {
      throw CaptureChannelException(
        method,
        'Channel "${AppConfig.channelCapture}" method "$method" is not '
        'registered on the native side. Check CaptureModule.kt (Android) '
        'or CaptureModuleController.swift (iOS) registration.',
        e,
      );
    } on PlatformException catch (e) {
      throw CaptureChannelException(
        method,
        e.message ?? 'Native side reported an error for method "$method"',
        e,
      );
    }
  }
}
