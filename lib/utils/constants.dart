// ─── PREVIOUS CONTENT (backed up — P0 scaffold applied 2026-06-08) ──────────
// import 'package:flutter/foundation.dart';
// import 'package:flutter_dotenv/flutter_dotenv.dart';
//
// abstract final class AppConstants {
//   static String get apiBaseUrl {
//     final url = dotenv.env['API_BASE_URL'];
//     if (url == null || url.isEmpty) {
//       debugPrint('WARNING: API_BASE_URL not set in .env — falling back to localhost.');
//       return 'http://localhost:3000';
//     }
//     return url;
//   }
//
//   static const Duration connectTimeout = Duration(seconds: 15);
//   static const Duration receiveTimeout = Duration(seconds: 30);
//
//   static const String boxSession = 'session';
//   static const String boxProjects = 'projects';
//   static const String boxCapture = 'capture';
//
//   static const String channelCapture = 'com.mayasabhaxr.recapture/capture';
//   static const String channelSensors = 'com.mayasabhaxr.recapture/sensors';
// }
// ─────────────────────────────────────────────────────────────────────────────

// lib/utils/constants.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

abstract final class AppConfig {
  static String get apiBaseUrl {
    final url = dotenv.env['API_BASE_URL'];
    if (url == null || url.isEmpty) {
      debugPrint('WARNING: API_BASE_URL not set — falling back to localhost.');
      return 'http://localhost:3000';
    }
    return url;
  }

  /// Bounds only the TCP/TLS handshake, so a genuinely offline device still
  /// fails fast (and `CatalogFailure.fromDio` still reports it as OFFLINE)
  /// regardless of how generous [receiveTimeout] is.
  static const Duration connectTimeout = Duration(seconds: 15);

  /// Long enough to outlast a Render cold start.
  ///
  /// The sleeping dev instance takes ~60s to answer its first request, which
  /// [BackendWarmupService] already documents and allows for. But that warm-up
  /// is FIRE-AND-FORGET — it wakes the backend without holding the first real
  /// request back, so that request routinely lands while the instance is still
  /// booting. Render accepts the connection immediately and then holds it open
  /// while it boots, so the wait shows up here, on the response, never on
  /// [connectTimeout].
  ///
  /// This was 30s — shorter than the cold start the app itself documents — and
  /// every request issued during a cold start died at 30s with a
  /// `receiveTimeout`, which the UI reports as "you're offline".
  ///
  /// The catalog screen is where that surfaced, because it is the ONE surface
  /// with no disk cache to fall back on (see `CatalogNotifier` — catalog state
  /// is deliberately server-truth only). Projects, which caches to Hive, rode
  /// out the same failure showing stale rows and looked healthy.
  ///
  /// Keep this >= the cold start; it costs nothing when the backend is warm,
  /// because it is a ceiling and not a delay.
  static const Duration receiveTimeout = Duration(seconds: 75);

  static const String boxSession = 'session';
  static const String boxProjects = 'projects';
  static const String boxCapture = 'capture';

  static const String channelCapture = 'com.mayasabhaxr.recapture/capture';
  static const String channelSensors = 'com.mayasabhaxr.recapture/sensors';
  static const String channelCaptureEvents = 'com.mayasabhaxr.recapture/captureEvents';

  /// Native Android permissions channel — must match
  /// PermissionManager.CHANNEL_NAME on the Kotlin side.
  static const String channelPermissions = 'com.mayasabhaxr.recapture/permissions';

  /// Native camera-preview channel — must match
  /// CameraPreviewManager.CHANNEL_NAME on the Kotlin side. Carries the live
  /// back-camera preview (external texture) for the capture screen.
  static const String channelCameraPreview =
      'com.mayasabhaxr.recapture/camera_preview';

  /// Native iOS camera-preview PlatformView (`UiKitView`) type — must match
  /// `CameraPreviewViewFactory.viewType` on the Swift side. On iOS the live feed
  /// is rendered by an embedded `AVCaptureVideoPreviewLayer` (vs Android's
  /// external texture); the session lifecycle is still driven over
  /// [channelCameraPreview]. Unused on Android.
  static const String viewTypeCameraPreviewIos =
      'com.mayasabhaxr.recapture/camera_preview_view';

  /// Native IMU rotation-vector EventChannel — must match
  /// ImuRotationStreamManager.CHANNEL_NAME on the Kotlin side. Streams device
  /// orientation (unit quaternion) at 50–100Hz with camera-clock-aligned
  /// (CLOCK_MONOTONIC) timestamps for the later pose/frame-fusion task.
  static const String channelImuRotation =
      'com.mayasabhaxr.recapture/imu_rotation';

  /// Native smoothed-orientation EventChannel — must match
  /// ImuRotationStreamManager.ORIENTATION_CHANNEL_NAME on the Kotlin side. Streams
  /// low-pass-filtered yaw/pitch/roll (+ smoothed quaternion) for the capture
  /// level/orientation guide; same timestamp/clock domain as the raw stream.
  static const String channelImuOrientation =
      'com.mayasabhaxr.recapture/imu_orientation';

  /// Native stability-gate EventChannel — must match
  /// StabilityStreamManager.CHANNEL_NAME on the Kotlin side. Streams a debounced
  /// stable/unstable state (+ a "stable" trigger for auto-capture) from a
  /// gyro/linear-accel motion gate.
  static const String channelStability =
      'com.mayasabhaxr.recapture/stability';

  /// Native blur-detection EventChannel — must match
  /// BlurAnalysisManager.CHANNEL_NAME on the Kotlin side. Streams a per-frame
  /// sharpness score (variance of Laplacian @ 640px) + sharp/blurry decision for a
  /// real-time "too blurry" indicator; timestampNs matches the capture clock.
  static const String channelBlur = 'com.mayasabhaxr.recapture/blur';

  /// Native exposure-check EventChannel — must match
  /// BlurAnalysisManager.EXPOSURE_CHANNEL_NAME on the Kotlin side. Streams a
  /// per-frame mean luminance (0–255) + dark/ok/bright band for a real-time
  /// "too dark"/"too bright" warning; warn-only (never rejects). Shares the blur
  /// analyzer's frame pass, so timestampNs/frameIndex match the blur stream.
  static const String channelExposure = 'com.mayasabhaxr.recapture/exposure';

  /// Native capture-storage MethodChannel — must match
  /// CaptureStorage.CHANNEL_NAME on the Kotlin side. App-scoped capture tree
  /// (/recapture/{project}/{job}/images/{level}); Dart uses it for accounting,
  /// free space, incomplete-job listing, and delete (incl. the P1 project-deletion
  /// cleanup hook). Frame writing/allocation stays native (the burst task).
  static const String channelCaptureStorage =
      'com.mayasabhaxr.recapture/capture_storage';

  /// Native Android upload foreground-service MethodChannel — must match
  /// UploadForegroundService.CHANNEL_NAME on the Kotlin side. Starts/stops/updates
  /// the background-upload foreground service + its persistent notification so a
  /// long upload survives backgrounding. Android-only (no-op elsewhere); the
  /// transport itself is a STUB the upload pipeline plugs into.
  static const String channelUploadService =
      'com.mayasabhaxr.recapture/upload_service';

  /// Native iOS background-upload MethodChannel — must match
  /// BackgroundUploadManager.methodChannelName on the Swift side. `enqueueUpload`
  /// hands a file to a background URLSession so the transfer survives
  /// suspension/kill. iOS-only (no-op elsewhere; Android's counterpart is the
  /// foreground service + WorkManager pair on [channelUploadService]).
  static const String channelUploadEngine =
      'com.mayasabhaxr.recapture/upload_engine';

  /// Native iOS background-upload EventChannel — must match
  /// BackgroundUploadManager.eventsChannelName on the Swift side. Streams
  /// progress / success / failure payloads for enqueued background uploads
  /// (buffered natively across background relaunches until Dart subscribes).
  static const String channelUploadEvents =
      'com.mayasabhaxr.recapture/upload_events';
}
