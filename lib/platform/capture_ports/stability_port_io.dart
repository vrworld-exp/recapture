// lib/platform/capture_ports/stability_port_io.dart
//
// NATIVE implementation of [StabilityPort]: the `stability` EventChannel,
// exactly as lib/platform/stability_channel.dart drove it before the port
// existed — same channel, same listen arguments, same malformed-event
// filtering. Android/iOS behaviour is unchanged.
import 'package:flutter/services.dart';

import '../../utils/constants.dart';
import 'stability_port.dart';

/// Selected by the conditional import in lib/platform/stability_channel.dart
/// when `dart:io` exists (Android / iOS / the unit-test host).
StabilityPort createStabilityPort([EventChannel? channel]) =>
    ChannelStabilityPort(channel);

/// EventChannel-backed [StabilityPort].
class ChannelStabilityPort implements StabilityPort {
  ChannelStabilityPort([EventChannel? channel])
      : _channel = channel ?? const EventChannel(AppConfig.channelStability);

  final EventChannel _channel;

  @override
  Stream<StabilityEvent> events({
    double gyroThresh = 0.8,
    double accelThresh = 0.15,
    int dwellMs = 250,
  }) {
    return _channel
        .receiveBroadcastStream(<String, dynamic>{
          'gyroThresh': gyroThresh,
          'accelThresh': accelThresh,
          'dwellMs': dwellMs,
        })
        .map(StabilityEvent.fromEvent)
        .where((e) => e != null)
        .cast<StabilityEvent>();
  }
}
