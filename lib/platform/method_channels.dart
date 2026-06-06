import '../utils/constants.dart';

/// MethodChannel wrapper for native capture module.
/// All method names are declared as constants to prevent typo bugs.
abstract final class CaptureChannel {
  // Channel name — instantiate MethodChannel(AppConstants.channelCapture) in P3 wrappers
  static const String channelName = AppConstants.channelCapture;

  // Method name constants — must match Android CaptureModule.kt + iOS CaptureModuleController.swift
  static const String startCapture = 'startCapture';
  static const String stopCapture = 'stopCapture';
  static const String takePicture = 'takePicture';
  static const String getOrientation = 'getOrientation';
}
