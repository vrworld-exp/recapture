// lib/platform/capture_ports/capture_preflight_web.dart
//
// WEB half of the capture preflight — the real probe.
//
// Ordering is deliberate: the secure-context check runs first because it is the
// ROOT CAUSE of the other three. Over plain HTTP `navigator.mediaDevices` and
// the motion events are simply absent, so probing them would report "no camera"
// and "no motion sensors" — three symptoms, none of them the actual problem,
// and the actual problem ("this page is not on HTTPS") is by far the most
// common cause of a "works locally, dead on staging" report.
//
// Motion is required for `meshy` and optional for `full`. That asymmetry is not
// a preflight opinion, it is the app's existing rule surfaced early:
// `CaptureMode.meshy.usesHardTiltGate` disables `CaptureReadiness`'s fail-open,
// so a Meshy shutter with no tilt stream stays blocked by design. Telling the
// user that up front is the alternative to a shutter that looks broken.
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import '../../domain/capture/capture_mode.dart';
import 'capture_preflight.dart';
import 'web_capture_store.dart';
import 'web_motion_permission.dart';

/// True: the browser is the only platform where these questions are both
/// answerable up front and worth answering up front.
const bool capturePreflightRequired = true;

Future<CapturePreflightReport> probeCaptureCapabilities({
  required CaptureMode mode,
  required int expectedPhotoCount,
  required int estimatedBytesPerPhoto,
}) async {
  final results = <CaptureCapabilityResult>[];

  // ── 1. Secure context ──────────────────────────────────────────────────────
  final secure = web.window.isSecureContext;
  results.add(CaptureCapabilityResult(
    capability: CaptureCapability.secureContext,
    available: secure,
    required_: true,
    detail: secure
        ? null
        : 'The camera and motion sensors are only available over HTTPS. Open '
            'this page on a secure (https://) address and try again.',
  ));
  if (!secure) {
    // Everything below is unknowable off a secure origin; reporting it would
    // just add noise to the one thing the user has to fix.
    return CapturePreflightReport(results);
  }

  // ── 2. Camera ──────────────────────────────────────────────────────────────
  final camera = await _probeCamera();
  results.add(camera);

  // ── 3. Motion sensors ──────────────────────────────────────────────────────
  final motionStatus = motionPermissionStatus();
  final motionOk = motionStatus == 'granted';
  final motionRequired = mode.usesHardTiltGate;
  results.add(CaptureCapabilityResult(
    capability: CaptureCapability.motionSensors,
    available: motionOk,
    required_: motionRequired,
    detail: motionOk
        ? null
        : motionRequired
            ? _meshyMotionDetail(motionStatus)
            : 'Tilt guidance will be unavailable, so the on-screen band and '
                'ring hints will not appear. Capture still works.',
  ));

  // ── 4/5. Local store + quota ───────────────────────────────────────────────
  final writable = await WebCaptureStore.instance.isWritable();
  results.add(CaptureCapabilityResult(
    capability: CaptureCapability.localStorage,
    available: writable,
    required_: true,
    detail: writable
        ? null
        : 'This browser is not letting the page store photos. Private/incognito '
            'browsing and blocked site data are the usual causes.',
  ));

  final needed = expectedPhotoCount * estimatedBytesPerPhoto;
  final estimate = await WebCaptureStore.instance.estimate();
  final quota = estimate.quota;
  final used = estimate.usage ?? 0;
  // A browser that does not implement `storage.estimate()` (older Safari)
  // reports null. Treated as available: refusing to capture on a device we
  // simply cannot measure would block real, working sessions.
  final quotaOk = quota == null || (quota - used) >= needed;
  results.add(CaptureCapabilityResult(
    capability: CaptureCapability.storageQuota,
    available: quotaOk,
    required_: true,
    detail: quotaOk
        ? null
        : 'This capture needs about ${_mb(needed)} MB of free space and only '
            '${_mb(quota - used)} MB is available. Free up space for '
            'this site and try again.',
  ));

  return CapturePreflightReport(results);
}

String _meshyMotionDetail(String status) => switch (status) {
      // iOS Safari, never asked: recoverable with a gesture-triggered retry.
      'notRequested' =>
        'Maya Capture needs motion access to know where the camera is pointing. '
            'Tap Allow motion access to grant it.',
      // Denied: Safari will not prompt again for this site.
      'denied' =>
        'Motion access is blocked for this site, and Maya Capture cannot check '
            'the camera angle without it. Enable Motion & Orientation Access '
            'for this site in your browser settings, then retry.',
      _ =>
        'This browser does not report device orientation, which Maya Capture '
            'needs to check the camera angle. Try Safari on iOS or Chrome on '
            'Android.',
    };

Future<CaptureCapabilityResult> _probeCamera() async {
  final devices = web.window.navigator.mediaDevices;
  // ignore: unnecessary_null_comparison
  if ((devices as JSAny?) == null || !devices.has('getUserMedia')) {
    return const CaptureCapabilityResult(
      capability: CaptureCapability.camera,
      available: false,
      required_: true,
      detail: 'This browser does not expose a camera to web pages.',
    );
  }
  try {
    // `enumerateDevices` needs no permission. Before the camera has been
    // granted the labels are blank, but the ENTRIES exist — which is exactly
    // the question here: does this device have a camera at all.
    final list = await devices.enumerateDevices().toDart;
    final hasCamera = list.toDart.any((d) => d.kind == 'videoinput');
    return CaptureCapabilityResult(
      capability: CaptureCapability.camera,
      available: hasCamera,
      required_: true,
      detail: hasCamera
          ? null
          : 'No camera was found on this device. Both capture modes need a '
              'rear-facing camera.',
    );
  } catch (_) {
    // Some browsers throw when media devices are policy-blocked (an iframe
    // without `allow="camera"`). Reported as unavailable, because it is.
    return const CaptureCapabilityResult(
      capability: CaptureCapability.camera,
      available: false,
      required_: true,
      detail: 'The camera is blocked for this page. If it is embedded in '
          'another site, open it directly.',
    );
  }
}

String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(0);
