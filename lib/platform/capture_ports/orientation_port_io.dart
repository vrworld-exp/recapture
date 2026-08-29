// lib/platform/capture_ports/orientation_port_io.dart
//
// NATIVE implementation of [OrientationPort]: the two rotation-vector
// EventChannels, exactly as lib/platform/imu_rotation_channel.dart drove them
// before the port existed — same channel names, same listen arguments, same
// clamping, same malformed-event filtering. Nothing about Android/iOS
// behaviour changes; the code simply moved behind the port boundary.
import 'package:flutter/services.dart';

import '../../utils/constants.dart';
import 'orientation_port.dart';

/// Selected by the conditional import in lib/platform/imu_rotation_channel.dart
/// when `dart:io` exists (Android / iOS / the unit-test host).
OrientationPort createOrientationPort({
  EventChannel? rotationChannel,
  EventChannel? orientationChannel,
}) =>
    ChannelOrientationPort(
      rotationChannel: rotationChannel,
      orientationChannel: orientationChannel,
    );

/// EventChannel-backed [OrientationPort].
class ChannelOrientationPort implements OrientationPort {
  ChannelOrientationPort({
    EventChannel? rotationChannel,
    EventChannel? orientationChannel,
  })  : _rotation =
            rotationChannel ?? const EventChannel(AppConfig.channelImuRotation),
        _orientation = orientationChannel ??
            const EventChannel(AppConfig.channelImuOrientation);

  final EventChannel _rotation;
  final EventChannel _orientation;

  static const int _minRateHz = 50;
  static const int _maxRateHz = 100;

  @override
  Stream<ImuRotationSample> samples({int rateHz = _maxRateHz}) {
    final clamped = rateHz.clamp(_minRateHz, _maxRateHz);
    return _rotation
        .receiveBroadcastStream(<String, dynamic>{'rateHz': clamped})
        .map(ImuRotationSample.fromEvent)
        .where((s) => s != null)
        .cast<ImuRotationSample>();
  }

  @override
  Stream<SmoothedOrientation> orientation({
    int rateHz = _maxRateHz,
    double tauMs = 100.0,
  }) {
    final clampedRate = rateHz.clamp(_minRateHz, _maxRateHz);
    final safeTau = tauMs < 0 ? 0.0 : tauMs;
    return _orientation
        .receiveBroadcastStream(<String, dynamic>{
          'rateHz': clampedRate,
          'tauMs': safeTau,
        })
        .map(SmoothedOrientation.fromEvent)
        .where((s) => s != null)
        .cast<SmoothedOrientation>();
  }
}
