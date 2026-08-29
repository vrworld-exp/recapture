// lib/platform/capture_ports/frame_quality_port_io.dart
//
// NATIVE implementation of [FrameQualityPort]: the `blur` and `exposure`
// EventChannels, with exactly the listen arguments and malformed-event
// filtering lib/platform/blur_channel.dart and
// lib/platform/exposure_channel.dart used before the port existed.
import 'package:flutter/services.dart';

import '../../utils/constants.dart';
import 'frame_quality_port.dart';

/// Selected by the conditional import in lib/platform/blur_channel.dart and
/// lib/platform/exposure_channel.dart when `dart:io` exists.
FrameQualityPort createFrameQualityPort({
  EventChannel? blurChannel,
  EventChannel? exposureChannel,
}) =>
    ChannelFrameQualityPort(
      blurChannel: blurChannel,
      exposureChannel: exposureChannel,
    );

/// EventChannel-backed [FrameQualityPort].
class ChannelFrameQualityPort implements FrameQualityPort {
  ChannelFrameQualityPort({
    EventChannel? blurChannel,
    EventChannel? exposureChannel,
  })  : _blur = blurChannel ?? const EventChannel(AppConfig.channelBlur),
        _exposure =
            exposureChannel ?? const EventChannel(AppConfig.channelExposure);

  final EventChannel _blur;
  final EventChannel _exposure;

  @override
  Stream<BlurResult> blur({
    double? blurThreshold,
    double? rejectBelow,
    double? acceptAbove,
  }) {
    final args = <String, dynamic>{
      if (blurThreshold != null && blurThreshold >= 0)
        'blurThreshold': blurThreshold,
      if (rejectBelow != null) 'rejectBelow': rejectBelow,
      if (acceptAbove != null) 'acceptAbove': acceptAbove,
    };
    return _blur
        .receiveBroadcastStream(args)
        .map(BlurResult.fromEvent)
        .where((r) => r != null)
        .cast<BlurResult>();
  }

  @override
  Stream<ExposureResult> exposure({double? darkBelow, double? brightAbove}) {
    final args = <String, dynamic>{
      if (darkBelow != null) 'darkBelow': darkBelow,
      if (brightAbove != null) 'brightAbove': brightAbove,
    };
    return _exposure
        .receiveBroadcastStream(args)
        .map(ExposureResult.fromEvent)
        .where((r) => r != null)
        .cast<ExposureResult>();
  }
}
