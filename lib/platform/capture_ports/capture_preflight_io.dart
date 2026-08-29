// lib/platform/capture_ports/capture_preflight_io.dart
//
// NATIVE half of the capture preflight: nothing to probe.
//
// On Android and iOS the questions the web probe asks are already owned
// elsewhere and answered with real OS surfaces — the permissions screen holds
// camera and motion, the native camera manager reports a missing/busy camera
// through the existing CameraPreviewStatus.error path, and the capture storage
// channel does the free-space check against the volume. Adding a second gate
// here would only be able to disagree with them.
import '../../domain/capture/capture_mode.dart';
import 'capture_preflight.dart';

/// False: there is nothing to probe, so the gate must not even cost a frame.
const bool capturePreflightRequired = false;

Future<CapturePreflightReport> probeCaptureCapabilities({
  required CaptureMode mode,
  required int expectedPhotoCount,
  required int estimatedBytesPerPhoto,
}) async =>
    CapturePreflightReport.allClear;
