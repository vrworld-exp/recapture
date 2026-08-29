// lib/platform/capture_ports/camera_preview_port_io.dart
//
// NATIVE implementation of [CameraPreviewPort]: the `camera_preview`
// MethodChannel, with exactly the behaviour
// lib/platform/camera/camera_preview_controller.dart had before the port
// existed — the same method names, the same result keys, the same
// PlatformException / MissingPluginException → error mapping, and the same
// fire-and-forget `dispose`. Android and iOS are byte-for-byte unchanged.
import 'package:flutter/services.dart';

import '../../utils/constants.dart';
import 'camera_preview_port.dart';

/// Selected by the conditional import in
/// lib/platform/camera/camera_preview_controller.dart when `dart:io` exists.
CameraPreviewPort createCameraPreviewPort([MethodChannel? channel]) =>
    ChannelCameraPreviewPort(channel);

/// MethodChannel-backed [CameraPreviewPort].
class ChannelCameraPreviewPort implements CameraPreviewPort {
  ChannelCameraPreviewPort([MethodChannel? channel])
      : _channel =
            channel ?? const MethodChannel(AppConfig.channelCameraPreview);

  final MethodChannel _channel;
  void Function(CameraPreviewPush push)? _handler;

  @override
  void setPushHandler(void Function(CameraPreviewPush push)? handler) {
    _handler = handler;
    if (handler == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((call) async {
      _handler?.call(
        CameraPreviewPush(
          call.method,
          (call.arguments as Map?)?.cast<String, dynamic>(),
        ),
      );
    });
  }

  @override
  Future<CameraPreviewBinding> start() async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('start');
      if (res == null) {
        throw const CameraPreviewFailure(
          'NULL_RESULT',
          'Native preview returned no texture.',
        );
      }
      return CameraPreviewBinding(
        textureId: (res['textureId'] as num?)?.toInt(),
        previewWidth: (res['previewWidth'] as num?)?.toInt() ?? 0,
        previewHeight: (res['previewHeight'] as num?)?.toInt() ?? 0,
        rotationDegrees: (res['rotationDegrees'] as num?)?.toInt() ?? 0,
      );
    } on PlatformException catch (e) {
      throw CameraPreviewFailure(
        e.code,
        e.message ?? 'Failed to start camera preview.',
      );
    } on MissingPluginException {
      // Channel not registered (unit-test host, or a platform with no native
      // side).
      throw const CameraPreviewFailure(
        'NO_PLUGIN',
        'Camera preview channel unavailable.',
      );
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // Ignore — teardown is best-effort.
    } on MissingPluginException {
      // Ignore — nothing native to stop.
    }
  }

  @override
  Future<void> dispose() async {
    _handler = null;
    _channel.setMethodCallHandler(null);
    // Fire-and-forget native teardown; the controller is going away.
    _channel.invokeMethod<void>('dispose').catchError((Object _) {});
  }
}
