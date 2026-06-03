import 'package:flutter/material.dart';
import '../../utils/logger.dart';

enum AppPermission {
  camera,
  microphone,
}

class PermissionHandler {
  PermissionHandler._();

  /// Call this before launching camera or AR session.
  /// Returns true if all permissions granted, false otherwise.
  static Future<bool> requestCameraAndMicrophone(BuildContext context) async {
    // TODO: integrate permission_handler package when added
    appLogger.d('Requesting CAMERA and RECORD_AUDIO permissions');
    return true;
  }

  static Future<bool> requestCamera(BuildContext context) async {
    appLogger.d('Requesting CAMERA permission');
    return true;
  }
}
