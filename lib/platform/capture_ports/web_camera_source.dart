// lib/platform/capture_ports/web_camera_source.dart
//
// WEB ONLY (imported exclusively from `*_web.dart` port implementations).
//
// The single owner of the browser camera: one `getUserMedia` stream, one
// `<video>` element, one scratch canvas. Three ports read from it —
//   • camera preview (renders the element in an HtmlElementView),
//   • still capture (draws the current frame to the canvas → JPEG bytes),
//   • frame quality (draws a 640px-wide copy → ImageData → blur/exposure),
// which is exactly the native arrangement, where preview, ImageCapture and
// ImageAnalysis are three use-cases bound to ONE CameraX session. Sharing the
// element is what makes "preview FOV == capture FOV" true by construction.
//
// Load-bearing details:
//  • `playsinline` + `muted` + `autoplay` are all required. Without
//    `playsinline` iOS Safari takes the video fullscreen; without `muted` it
//    refuses to autoplay at all.
//  • `facingMode: 'environment'` is a *preference*, not a guarantee — a laptop
//    resolves it to the front camera. The preflight probe reports what was
//    actually bound.
//  • getUserMedia is a secure-context API: over plain HTTP (other than
//    localhost) `navigator.mediaDevices` is undefined, which is reported here
//    as INSECURE_CONTEXT rather than as a mysterious null crash.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:web/web.dart' as web;

/// The platform-view type the web camera preview is registered under.
const String kWebCameraPreviewViewType =
    'com.mayasabhaxr.recapture/camera_preview_web';

/// A started browser camera: the bound track's real dimensions.
class WebCameraStart {
  const WebCameraStart({
    required this.width,
    required this.height,
    required this.facingMode,
  });

  final int width;
  final int height;

  /// What the browser actually bound (`environment`, `user`, or `unknown`).
  final String facingMode;
}

/// A browser camera failure mapped onto the app's existing error vocabulary.
class WebCameraException implements Exception {
  const WebCameraException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'WebCameraException($code): $message';
}

/// Process-wide browser camera session.
class WebCameraSource {
  WebCameraSource._();

  static final WebCameraSource instance = WebCameraSource._();

  web.MediaStream? _stream;
  web.HTMLVideoElement? _video;
  web.HTMLCanvasElement? _scratch;
  bool _viewFactoryRegistered = false;

  /// The live `<video>` element, or null when the camera is not running.
  web.HTMLVideoElement? get video => _video;

  /// The bound `MediaStream`, or null when the camera is not running.
  web.MediaStream? get stream => _stream;

  /// Whether a stream is currently bound.
  bool get isRunning => _stream != null;

  /// Intrinsic frame size of the bound track (0 before metadata arrives).
  int get frameWidth => _video?.videoWidth ?? 0;
  int get frameHeight => _video?.videoHeight ?? 0;

  /// `performance.now()` (in ns) at the last successful [drawFrame]. It is the
  /// frame-association key the blur and exposure results share, and it lives on
  /// the same monotonic clock as the orientation samples and the captured
  /// frames' `timestampNs` — the join the native pipeline gets for free from
  /// CLOCK_MONOTONIC.
  int get lastDrawTimestampNs => _lastDrawTimestampNs;

  int _lastDrawTimestampNs = 0;

  /// Binds the environment-facing camera and resolves once the first frame's
  /// dimensions are known. Idempotent: calling it while running re-reports.
  ///
  /// Throws [WebCameraException] with one of INSECURE_CONTEXT /
  /// PERMISSION_DENIED / NO_CAMERA / CAMERA_BUSY / CAMERA_ERROR.
  Future<WebCameraStart> start({int idealWidth = 1920}) async {
    if (_stream != null && _video != null && frameWidth > 0) {
      return WebCameraStart(
        width: frameWidth,
        height: frameHeight,
        facingMode: _facingModeOf(_stream!),
      );
    }
    if (!web.window.isSecureContext) {
      throw const WebCameraException(
        'INSECURE_CONTEXT',
        'Camera access requires HTTPS. Open this page over a secure '
            'connection and try again.',
      );
    }
    final devices = web.window.navigator.mediaDevices;
    // ignore: unnecessary_null_comparison — the object is genuinely absent on
    // non-secure origins in some browsers, despite the non-nullable IDL type.
    if ((devices as JSAny?) == null) {
      throw const WebCameraException(
        'INSECURE_CONTEXT',
        'This browser is not exposing camera devices to the page.',
      );
    }

    final constraints = web.MediaStreamConstraints(
      audio: false.toJS,
      video: _videoConstraints(idealWidth),
    );

    final web.MediaStream stream;
    try {
      stream = await devices.getUserMedia(constraints).toDart;
    } catch (e) {
      throw _mapGetUserMediaError(e);
    }

    final video = _ensureVideoElement();
    video.srcObject = stream;
    _stream = stream;

    try {
      await video.play().toDart;
    } catch (_) {
      // Autoplay can still be refused (a browser with media autoplay blocked).
      // The element is attached and `muted`, so the retry path is the user
      // tapping the preview; do not fail the whole start here.
    }
    await _awaitDimensions(video);

    if (video.videoWidth == 0) {
      await _releaseStream();
      throw const WebCameraException(
        'CAMERA_ERROR',
        'The camera produced no video frames.',
      );
    }
    return WebCameraStart(
      width: video.videoWidth,
      height: video.videoHeight,
      facingMode: _facingModeOf(stream),
    );
  }

  /// Releases the camera but keeps the element so a restart is cheap.
  Future<void> stop() => _releaseStream();

  /// Releases everything, including the DOM element.
  Future<void> dispose() async {
    await _releaseStream();
    _video?.remove();
    _video = null;
    _scratch = null;
  }

  /// Registers the platform-view factory exactly once. The SAME element is
  /// returned every time, so the stream survives preview remounts.
  void registerViewFactory() {
    if (_viewFactoryRegistered) return;
    _viewFactoryRegistered = true;
    ui_web.platformViewRegistry.registerViewFactory(
      kWebCameraPreviewViewType,
      (int viewId) => _ensureVideoElement(),
    );
  }

  /// Draws the current frame into an offscreen canvas and returns it, cropped
  /// to [aspect] (width / height) about the centre when [aspect] is non-null.
  ///
  /// Cropping the DRAW RECT (rather than scaling) is what keeps the capture FOV
  /// identical to the preview FOV, which the native contract already requires
  /// and photogrammetry depends on.
  web.HTMLCanvasElement? drawFrame({double? aspect, int? targetWidth}) {
    final video = _video;
    if (video == null || video.videoWidth == 0) return null;
    final srcW = video.videoWidth;
    final srcH = video.videoHeight;

    var cropW = srcW;
    var cropH = srcH;
    if (aspect != null && aspect > 0) {
      if (srcW / srcH > aspect) {
        cropW = (srcH * aspect).round();
      } else {
        cropH = (srcW / aspect).round();
      }
    }
    final cropX = ((srcW - cropW) / 2).round();
    final cropY = ((srcH - cropH) / 2).round();

    var outW = cropW;
    var outH = cropH;
    if (targetWidth != null && targetWidth > 0 && cropW > targetWidth) {
      outW = targetWidth;
      outH = _atLeastOne((cropH * targetWidth / cropW).round());
    }

    _lastDrawTimestampNs = (web.window.performance.now() * 1000000).round();
    final canvas = _ensureScratch();
    canvas.width = outW;
    canvas.height = outH;
    final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D?;
    if (ctx == null) return null;
    ctx.drawImage(
      video,
      cropX.toDouble(),
      cropY.toDouble(),
      cropW.toDouble(),
      cropH.toDouble(),
      0,
      0,
      outW.toDouble(),
      outH.toDouble(),
    );
    return canvas;
  }

  /// The RGBA bytes of the whole [canvas] (for the frame-quality metrics).
  Uint8List? readPixels(web.HTMLCanvasElement canvas) {
    final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D?;
    if (ctx == null) return null;
    final data = ctx.getImageData(0, 0, canvas.width, canvas.height);
    // `ImageData.data` is a Uint8ClampedList; the metrics want a plain
    // Uint8List over the SAME buffer — a view, never a copy of a full frame.
    final clamped = data.data.toDart;
    return Uint8List.view(
      clamped.buffer,
      clamped.offsetInBytes,
      clamped.lengthInBytes,
    );
  }

  /// Encodes [canvas] as JPEG at [quality] (1..100) and returns the bytes.
  Future<Uint8List?> encodeJpeg(
    web.HTMLCanvasElement canvas, {
    required int quality,
  }) async {
    final q = (quality.clamp(1, 100)) / 100.0;
    final completer = Completer<web.Blob?>();
    canvas.toBlob(
      ((web.Blob? blob) {
        if (!completer.isCompleted) completer.complete(blob);
      }).toJS,
      'image/jpeg',
      q.toJS,
    );
    final blob = await completer.future;
    if (blob == null) return null;
    final buffer = await blob.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  }

  // ── internals ──────────────────────────────────────────────────────────────

  web.HTMLVideoElement _ensureVideoElement() {
    final existing = _video;
    if (existing != null) return existing;
    final el = web.HTMLVideoElement()
      ..autoplay = true
      ..muted = true
      // `playsInline` is the property behind the `playsinline` attribute; both
      // are set because older iOS Safari only honours the attribute form.
      ..playsInline = true
      ..setAttribute('playsinline', 'true')
      ..setAttribute('webkit-playsinline', 'true')
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'cover';
    _video = el;
    return el;
  }

  web.HTMLCanvasElement _ensureScratch() =>
      _scratch ??= web.HTMLCanvasElement();

  Future<void> _releaseStream() async {
    final stream = _stream;
    _stream = null;
    if (stream == null) return;
    final tracks = stream.getTracks().toDart;
    for (final track in tracks) {
      track.stop();
    }
    _video?.srcObject = null;
  }

  /// Waits (briefly) for `loadedmetadata` so `videoWidth` is meaningful.
  Future<void> _awaitDimensions(web.HTMLVideoElement video) async {
    if (video.videoWidth > 0) return;
    final completer = Completer<void>();
    late final JSFunction listener;
    listener = ((web.Event _) {
      if (!completer.isCompleted) completer.complete();
    }).toJS;
    video.addEventListener('loadedmetadata', listener);
    try {
      await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
    } finally {
      video.removeEventListener('loadedmetadata', listener);
    }
  }

  static web.MediaTrackConstraints _videoConstraints(int idealWidth) =>
      web.MediaTrackConstraints(
        facingMode: 'environment'.toJS,
        width: web.ConstrainULongRange(ideal: idealWidth),
        height: web.ConstrainULongRange(ideal: (idealWidth * 9 / 16).round()),
      );

  static String _facingModeOf(web.MediaStream stream) {
    final tracks = stream.getVideoTracks().toDart;
    if (tracks.isEmpty) return 'unknown';
    final settings = tracks.first.getSettings();
    final facing = settings.getProperty<JSAny?>('facingMode'.toJS);
    if (facing.isA<JSString>()) return (facing as JSString).toDart;
    return 'unknown';
  }

  /// Maps the DOMException names getUserMedia throws onto the app's error codes
  /// (the mapping the prompt fixes: NotAllowedError → permission denied,
  /// NotFoundError → no camera, NotReadableError → device busy).
  static WebCameraException _mapGetUserMediaError(Object error) {
    final name = _domExceptionName(error);
    return switch (name) {
      'NotAllowedError' || 'SecurityError' => const WebCameraException(
          'PERMISSION_DENIED',
          'Camera access was blocked. Allow the camera for this site and '
              'try again.',
        ),
      'NotFoundError' || 'OverconstrainedError' => const WebCameraException(
          'NO_CAMERA',
          'No rear-facing camera was found on this device.',
        ),
      'NotReadableError' || 'AbortError' => const WebCameraException(
          'CAMERA_BUSY',
          'The camera is in use by another app or tab. Close it and '
              'try again.',
        ),
      _ => WebCameraException(
          'CAMERA_ERROR',
          'The camera could not be started ($name).',
        ),
    };
  }

  static String _domExceptionName(Object error) {
    // A thrown DOMException reaches Dart as a JSObject on dart2js/dart2wasm;
    // `isA` is the platform-consistent way to ask (a bare `is JSObject` check
    // is flagged as compile-target-dependent).
    // ignore: invalid_runtime_check_with_js_interop_types
    if (error is! JSAny) return 'UnknownError';
    if (!error.isA<JSObject>()) return 'UnknownError';
    final obj = error as JSObject;
    if (!obj.has('name')) return 'UnknownError';
    final name = obj.getProperty<JSAny?>('name'.toJS);
    if (name.isA<JSString>()) return (name as JSString).toDart;
    return 'UnknownError';
  }
}

int _atLeastOne(int v) => v < 1 ? 1 : v;
