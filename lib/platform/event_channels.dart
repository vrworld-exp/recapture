// ─── PREVIOUS CONTENT (backed up — P0 scaffold applied 2026-06-08) ──────────
// import '../utils/constants.dart';
//
// /// EventChannel wrapper for real-time sensor streams.
// abstract final class SensorChannel {
//   static const String channelName = AppConstants.channelSensors;
// }
// ─────────────────────────────────────────────────────────────────────────────

// lib/platform/event_channels.dart
//
// EventChannel wrapper for real-time IMU sensor data streams.
// Provides a typed Stream<SensorFrame> from the native sensor pipeline.
// Channel name: com.mayasabhaxr.recapture/sensors
//
// Implemented in task: P3 › Native Camera & Sensor Pipeline › "Flutter Platform Bridge"
