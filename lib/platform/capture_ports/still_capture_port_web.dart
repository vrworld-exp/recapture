// lib/platform/capture_ports/still_capture_port_web.dart
//
// WEB implementation of [StillCapturePort].
//
// One capture is: draw the live `<video>` frame into a canvas at the video's
// INTRINSIC resolution (never the CSS size — that would silently downscale every
// photo to the widget's pixel size), crop the draw rect to the configured
// aspect ratio so the capture FOV matches the preview FOV, encode JPEG at the
// policy's quality, and write the bytes straight into IndexedDB.
//
// The write-through is not an optimization, it is the memory contract: 48
// full-resolution JPEGs are hundreds of megabytes, so nothing is retained in the
// Dart heap — `captureSingle` returns a [CapturedFrame] holding only an
// `idb://…` handle, and the ledger, the review grid and the uploader all pass
// that handle around without ever materializing the bytes.
//
// The burst / auto-capture loop is a Dart timer over the same single-shot path,
// emitting the SAME [CaptureEvent] vocabulary the native EventChannel emits, so
// nothing downstream can tell the loop is running in Dart.
//
// Known degradations vs native (reported honestly rather than papered over):
// there is no RAW path, no exposure/focus lock, and no control over the encoder
// beyond the quality argument — see `CameraControls`, which already degrades to
// "unsupported" on web because the channel has no handler.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;

import 'still_capture_port.dart';
import 'web_camera_source.dart';
import 'web_capture_store.dart';

/// Selected by the conditional import in lib/platform/method_channels.dart and
/// lib/platform/event_channels.dart on a web build. Both resolve to the SAME
/// engine instance so a burst started through one is observed through the other.
StillCapturePort createStillCapturePort({
  MethodChannel? captureChannel,
  EventChannel? eventsChannel,
}) =>
    WebStillCapturePort.instance;

/// Canvas-backed [StillCapturePort].
class WebStillCapturePort implements StillCapturePort {
  WebStillCapturePort._();

  static final WebStillCapturePort instance = WebStillCapturePort._();

  /// Default cadence when a burst/auto run supplies no interval. Matches the
  /// native manager's minimum spacing closely enough that the auto-capture
  /// cooldown, not the loop, remains the limiting factor.
  static const int defaultIntervalMs = 400;

  final _events = StreamController<CaptureEvent>.broadcast();

  CaptureResolutionPolicy _policy = const CaptureResolutionPolicy();
  Timer? _loop;
  String? _sessionId;
  int _sessionCount = 0;
  int _frameSeq = 0;
  bool _capturing = false;

  @override
  Stream<CaptureEvent> events() => _events.stream;

  @override
  Future<bool> configureCaptureResolution(
    CaptureResolutionPolicy policy,
  ) async {
    if (policy.jpegQuality < 1 || policy.jpegQuality > 100) return false;
    _policy = policy;
    return true;
  }

  @override
  Future<ActiveCaptureResolution?> getActiveCaptureResolution() async {
    final source = WebCameraSource.instance;
    final bound = source.isRunning && source.frameWidth > 0;
    if (!bound) {
      // Not bound yet: report the resolved TARGET, exactly like native.
      return ActiveCaptureResolution(
        width: _policy.targetWidth ?? _policy.targetLongEdge ?? 0,
        height: _policy.targetHeight ?? 0,
        jpegQuality: _policy.jpegQuality,
        aspectRatio: _policy.aspectRatio,
        fellBack: false,
        bound: false,
        targetWidth: _policy.targetWidth,
        targetHeight: _policy.targetHeight,
        targetLongEdge: _policy.targetLongEdge,
      );
    }
    final size = _croppedSize(source.frameWidth, source.frameHeight);
    return ActiveCaptureResolution(
      width: size.width,
      height: size.height,
      jpegQuality: _policy.jpegQuality,
      aspectRatio: _policy.aspectRatio,
      // A browser gives no choice of capture size — whatever the track
      // negotiated IS the capture resolution — so any requested target that
      // does not match it is, honestly, a fallback.
      fellBack:
          _policy.targetWidth != null && _policy.targetWidth != size.width,
      bound: true,
      targetWidth: _policy.targetWidth,
      targetHeight: _policy.targetHeight,
      targetLongEdge: _policy.targetLongEdge,
    );
  }

  @override
  Future<CapturedFrame?> captureSingle() async {
    // Single-flight, matching the native capturer's BUSY rejection: a second
    // shutter while an encode is in flight resolves null rather than queueing.
    if (_capturing) return null;
    _capturing = true;
    try {
      final source = WebCameraSource.instance;
      final canvas = source.drawFrame(aspect: _aspectValue());
      if (canvas == null) return null;
      final bytes = await source.encodeJpeg(
        canvas,
        quality: _policy.jpegQuality,
      );
      if (bytes == null || bytes.isEmpty) return null;
      final timestampNs = (web.window.performance.now() * 1000000).round();
      final frameId = _nextFrameId(timestampNs);
      final entry = await WebCaptureStore.instance.writeFrame(
        frameId: frameId,
        bytes: bytes,
        timestampNs: timestampNs,
      );
      return CapturedFrame(
        id: frameId,
        path: entry.path,
        timestampNs: timestampNs,
      );
    } catch (_) {
      // An over-quota IndexedDB write, a tainted canvas, a stopped track — all
      // report as "no frame", the same as a native capture failure.
      return null;
    } finally {
      _capturing = false;
    }
  }

  @override
  Future<String?> startBurst(int count, {int? intervalMs}) {
    if (count <= 0) return Future.value(null);
    return _startLoop(total: count, intervalMs: intervalMs);
  }

  @override
  Future<String?> startAutoCapture({int? intervalMs}) =>
      _startLoop(total: null, intervalMs: intervalMs);

  @override
  Future<void> stopAutoCapture() async {
    final sessionId = _sessionId;
    _loop?.cancel();
    _loop = null;
    _sessionId = null;
    if (sessionId != null && !_events.isClosed) {
      _events.add(
        CaptureCompletedEvent(count: _sessionCount, sessionId: sessionId),
      );
    }
    _sessionCount = 0;
  }

  Future<String?> _startLoop({required int? total, int? intervalMs}) async {
    if (_loop != null) return null; // BUSY — a run is already in flight
    if (!WebCameraSource.instance.isRunning) return null; // NO_CAMERA
    final sessionId = 'web-${DateTime.now().microsecondsSinceEpoch}';
    _sessionId = sessionId;
    _sessionCount = 0;
    final period = Duration(
      milliseconds: (intervalMs == null || intervalMs <= 0)
          ? defaultIntervalMs
          : intervalMs,
    );
    _loop = Timer.periodic(period, (timer) async {
      if (_sessionId != sessionId) return; // superseded
      // A tick that lands while the previous encode is still running is
      // SKIPPED, not reported as a failure: the JPEG encode can outrun a short
      // interval on a slow device, and an error event there would look like a
      // camera fault to the capture flow.
      if (_capturing) return;
      final frame = await captureSingle();
      if (_sessionId != sessionId) return;
      if (frame == null) {
        if (!_events.isClosed) {
          _events.add(CaptureErrorEvent(
            index: _sessionCount,
            message: 'The browser could not capture a frame.',
          ));
        }
      } else {
        if (!_events.isClosed) {
          _events.add(CaptureFrameEvent(
            id: frame.id,
            path: frame.path,
            timestampNs: frame.timestampNs,
            index: _sessionCount,
            total: total,
          ));
        }
        _sessionCount++;
      }
      if (total != null && _sessionCount >= total) {
        await stopAutoCapture();
      }
    });
    return sessionId;
  }

  /// `width / height` for the configured aspect ratio, in the orientation the
  /// track actually delivers — a portrait track needs the reciprocal, or the
  /// crop would take a letterbox out of the middle of the frame.
  double _aspectValue() {
    final source = WebCameraSource.instance;
    final landscape = source.frameWidth >= source.frameHeight;
    final ratio = switch (_policy.aspectRatio) {
      CaptureAspectRatio.ratio4x3 => 4 / 3,
      CaptureAspectRatio.ratio16x9 => 16 / 9,
    };
    return landscape ? ratio : 1 / ratio;
  }

  ({int width, int height}) _croppedSize(int srcW, int srcH) {
    final aspect = _aspectValue();
    if (srcW / srcH > aspect) {
      return (width: (srcH * aspect).round(), height: srcH);
    }
    return (width: srcW, height: (srcW / aspect).round());
  }

  String _nextFrameId(int timestampNs) => 'web_${timestampNs}_${_frameSeq++}';
}
