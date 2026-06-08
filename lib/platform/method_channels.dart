// ─── PREVIOUS CONTENT (backed up — P0 scaffold applied 2026-06-08) ──────────
// import '../utils/constants.dart';
//
// /// MethodChannel wrapper for native capture module.
// abstract final class CaptureChannel {
//   static const String channelName = AppConstants.channelCapture;
//   static const String startCapture = 'startCapture';
//   static const String stopCapture = 'stopCapture';
//   static const String takePicture = 'takePicture';
//   static const String getOrientation = 'getOrientation';
// }
// ─────────────────────────────────────────────────────────────────────────────

// lib/platform/method_channels.dart
//
// MethodChannel wrapper for the native CaptureModule.
// Provides typed Dart API over the Android (Kotlin) and iOS (Swift)
// camera + capture native implementations.
// Channel name: com.mayasabhaxr.recapture/capture
//
// Implemented in task: P3 › Native Camera & Sensor Pipeline › "Flutter Platform Bridge"
