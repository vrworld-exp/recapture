// lib/platform/capture_ports/camera_preview_port_stub.dart
//
// Compile-time fallback for the platform-split [CameraPreviewPort]. Only
// reachable on a target with neither `dart:io` nor `dart:js_interop`; it fails
// the way a missing plugin already failed, so the preview shows its graceful
// error surface instead of throwing at import time.
import 'package:flutter/services.dart';

import 'camera_preview_port.dart';

CameraPreviewPort createCameraPreviewPort([MethodChannel? channel]) =>
    const _UnsupportedCameraPreviewPort();

class _UnsupportedCameraPreviewPort implements CameraPreviewPort {
  const _UnsupportedCameraPreviewPort();

  @override
  Future<CameraPreviewBinding> start() async =>
      throw const CameraPreviewFailure(
        'NO_PLUGIN',
        'Camera preview is not supported on this platform.',
      );

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}

  @override
  void setPushHandler(void Function(CameraPreviewPush push)? handler) {}
}
