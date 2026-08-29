// lib/platform/capture_ports/capture_preflight_stub.dart
//
// Compile-time fallback for the capture preflight on a target with neither
// `dart:io` nor `dart:js_interop`. It reports all-clear rather than blocking:
// the probe exists to give an honest early answer where one is knowable, not to
// invent a refusal on a platform it cannot inspect.
import '../../domain/capture/capture_mode.dart';
import 'capture_preflight.dart';

/// False: an unknown platform is not probed, so the gate stays transparent.
const bool capturePreflightRequired = false;

Future<CapturePreflightReport> probeCaptureCapabilities({
  required CaptureMode mode,
  required int expectedPhotoCount,
  required int estimatedBytesPerPhoto,
}) async =>
    CapturePreflightReport.allClear;
