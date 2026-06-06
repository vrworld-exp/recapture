import '../utils/constants.dart';

/// EventChannel wrapper for real-time sensor streams.
abstract final class SensorChannel {
  // Channel name — instantiate EventChannel(AppConstants.channelSensors) in P3 stream wrapper
  static const String channelName = AppConstants.channelSensors;
}
