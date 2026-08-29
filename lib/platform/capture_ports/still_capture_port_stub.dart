// lib/platform/capture_ports/still_capture_port_stub.dart
//
// Compile-time fallback for the platform-split [StillCapturePort]. Only
// reachable on a target with neither `dart:io` nor `dart:js_interop`; it
// degrades exactly the way a missing plugin already did (null frames, null
// session ids, an empty event stream) rather than throwing at import time.
import 'package:flutter/services.dart';

import 'still_capture_port.dart';

StillCapturePort createStillCapturePort({
  MethodChannel? captureChannel,
  EventChannel? eventsChannel,
}) =>
    const _UnsupportedStillCapturePort();

class _UnsupportedStillCapturePort implements StillCapturePort {
  const _UnsupportedStillCapturePort();

  @override
  Future<CapturedFrame?> captureSingle() async => null;

  @override
  Future<String?> startBurst(int count, {int? intervalMs}) async => null;

  @override
  Future<String?> startAutoCapture({int? intervalMs}) async => null;

  @override
  Future<void> stopAutoCapture() async {}

  @override
  Future<bool> configureCaptureResolution(
    CaptureResolutionPolicy policy,
  ) async =>
      false;

  @override
  Future<ActiveCaptureResolution?> getActiveCaptureResolution() async => null;

  @override
  Stream<CaptureEvent> events() => const Stream<CaptureEvent>.empty();
}
