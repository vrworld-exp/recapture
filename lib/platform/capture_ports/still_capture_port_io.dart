// lib/platform/capture_ports/still_capture_port_io.dart
//
// NATIVE implementation of [StillCapturePort]: the `capture` MethodChannel and
// the `captureEvents` EventChannel, with exactly the behaviour
// lib/platform/method_channels.dart and lib/platform/event_channels.dart had
// before the port existed — the same method names, the same argument maps, the
// same "degrade to null rather than throw" error handling, and the same
// malformed-event filtering. Android and iOS are unchanged.
import 'package:flutter/services.dart';

import '../../utils/constants.dart';
import 'still_capture_port.dart';

/// Selected by the conditional import in lib/platform/method_channels.dart and
/// lib/platform/event_channels.dart when `dart:io` exists.
StillCapturePort createStillCapturePort({
  MethodChannel? captureChannel,
  EventChannel? eventsChannel,
}) =>
    ChannelStillCapturePort(
      captureChannel: captureChannel,
      eventsChannel: eventsChannel,
    );

/// Channel-backed [StillCapturePort].
class ChannelStillCapturePort implements StillCapturePort {
  ChannelStillCapturePort({
    MethodChannel? captureChannel,
    EventChannel? eventsChannel,
  })  : _channel =
            captureChannel ?? const MethodChannel(AppConfig.channelCapture),
        _events =
            eventsChannel ?? const EventChannel(AppConfig.channelCaptureEvents);

  final MethodChannel _channel;
  final EventChannel _events;

  @override
  Future<CapturedFrame?> captureSingle() async {
    try {
      final res =
          await _channel.invokeMapMethod<String, dynamic>('captureSingle');
      return res == null ? null : CapturedFrame.fromMap(res);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<String?> startBurst(int count, {int? intervalMs}) =>
      _start('startBurst', {'count': count, 'intervalMs': intervalMs});

  @override
  Future<String?> startAutoCapture({int? intervalMs}) =>
      _start('startAutoCapture', {'intervalMs': intervalMs});

  @override
  Future<bool> configureCaptureResolution(
    CaptureResolutionPolicy policy,
  ) async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'configureCaptureResolution',
        policy.toMap(),
      );
      return res?['accepted'] as bool? ?? false;
    } on PlatformException {
      // INVALID_ARGS — the prior policy stands.
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<ActiveCaptureResolution?> getActiveCaptureResolution() async {
    try {
      final res = await _channel
          .invokeMapMethod<String, dynamic>('getActiveCaptureResolution');
      return res == null ? null : ActiveCaptureResolution.fromMap(res);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> stopAutoCapture() async {
    try {
      await _channel.invokeMethod<void>('stopAutoCapture');
    } on PlatformException {
      // Best-effort.
    } on MissingPluginException {
      // Nothing native to stop.
    }
  }

  @override
  Stream<CaptureEvent> events() => _events
      .receiveBroadcastStream()
      .map(CaptureEvent.fromEvent)
      .where((e) => e != null)
      .cast<CaptureEvent>();

  Future<String?> _start(String method, Map<String, dynamic> args) async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(method, args);
      return res?['sessionId'] as String?;
    } on PlatformException {
      // BUSY / NO_CAMERA / INVALID_ARGS.
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
