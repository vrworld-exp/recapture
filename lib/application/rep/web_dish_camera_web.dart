// lib/application/rep/web_dish_camera_web.dart
//
// The browser dish camera: `getUserMedia` into a `<video>`, frames out through
// a `<canvas>`.
//
// WHY NOT A CAMERA PACKAGE. The repo's rule is that the camera is a bespoke
// channel, not a plugin (see rep_capabilities_io.dart and lib/platform/camera),
// and pulling `package:camera` in for the browser half would put a second
// camera abstraction next to the first one for the sake of ~120 lines. This
// uses `package:web`, which is ALREADY a dependency — the model-viewer load
// probe uses it — so the browser path costs no new package at all.
//
// WHAT IT DELIBERATELY DOES NOT DO. No exposure metering, no blur scoring, no
// stability gate, no yaw tracking. Those are the four native channels the ring
// is built on and none of them exists here. The rep aims and taps; the screen
// says so rather than implying a guidance it cannot provide.
//
// LIFECYCLE IS THE RISK. A `MediaStream` that outlives its screen leaves the
// laptop's camera light on, which reads to the rep — correctly — as an app
// spying on them. [stop] halts every track and is called from the screen's
// dispose, and again on a successful finish.
import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'web_dish_camera_stub.dart';

export 'web_dish_camera_stub.dart' show WebDishCamera, WebDishCameraException;

/// The browser is the one target that has this.
const bool kHasWebDishCamera = true;

WebDishCamera createWebDishCamera() => _BrowserDishCamera();

/// Registered once per instance — a second capture screen in the same session
/// must not adopt the first one's `<video>` element.
int _viewIdSeed = 0;

class _BrowserDishCamera implements WebDishCamera {
  _BrowserDishCamera() : _viewType = 'rep-dish-camera-${_viewIdSeed++}';

  final String _viewType;

  web.MediaStream? _stream;
  web.HTMLVideoElement? _video;
  bool _registered = false;

  @override
  Future<void> start() async {
    final mediaDevices = web.window.navigator.mediaDevices;

    // `mediaDevices` is undefined — not merely empty — on an insecure origin.
    // That is the single most likely reason this fails in practice: a rep
    // opening a dev build over plain http on a LAN address. Naming it is worth
    // more than a generic failure, because the fix is a URL, not a setting.
    if (mediaDevices.isUndefinedOrNull) {
      throw const WebDishCameraException(
        'This browser will not open a camera on an insecure page. Use the '
        'https:// address (or localhost) and try again.',
      );
    }

    final video = web.HTMLVideoElement()
      // Required for autoplay to be allowed without a user gesture; without
      // BOTH of these Safari and Chrome refuse to start the preview and the
      // screen shows a frozen black rectangle with no error.
      ..muted = true
      ..autoplay = true
      ..setAttribute('playsinline', 'true')
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'cover';

    try {
      // `facingMode: environment` asks for the REAR camera where there is a
      // choice. It is a request, not a demand — a laptop has one camera and
      // simply returns it, which is why this is not an `exact` constraint that
      // would fail outright on a desktop.
      final constraints = web.MediaStreamConstraints(
        video: {'facingMode': 'environment'}.jsify() ?? true.toJS,
        audio: false.toJS,
      );
      _stream = await mediaDevices.getUserMedia(constraints).toDart;
    } catch (error) {
      throw WebDishCameraException(_messageFor(error));
    }

    video.srcObject = _stream;
    _video = video;

    if (!_registered) {
      ui_web.platformViewRegistry
          .registerViewFactory(_viewType, (int _) => video);
      _registered = true;
    }

    // The first frame is not available the instant getUserMedia resolves, and
    // grabbing before it lands yields a 0x0 canvas — a blank photo the rep
    // cannot tell from a real one until the model fails days later.
    await _awaitFirstFrame(video);
  }

  /// Resolves when the element reports real dimensions, or gives up quietly.
  ///
  /// Bounded on purpose: a camera that never produces a frame must not hang the
  /// screen forever. If the wait expires the preview simply stays dark and the
  /// shutter still works — [grabFrame] does its own size check.
  static Future<void> _awaitFirstFrame(web.HTMLVideoElement video) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (video.videoWidth == 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  @override
  Widget preview() => HtmlElementView(viewType: _viewType);

  @override
  Future<Uint8List> grabFrame() async {
    final video = _video;
    if (video == null || video.videoWidth == 0) {
      throw const WebDishCameraException(
        'The camera is not ready yet. Wait a moment and try again.',
      );
    }

    final canvas = web.HTMLCanvasElement()
      ..width = video.videoWidth
      ..height = video.videoHeight;

    final context = canvas.getContext('2d') as web.CanvasRenderingContext2D;
    context.drawImage(video, 0, 0);

    // 0.92 rather than 1.0: visually indistinguishable for photogrammetry input
    // and roughly a third of the bytes, which matters because six of these are
    // held in memory at once and then uploaded over whatever connection a
    // restaurant has.
    final dataUrl = canvas.toDataURL('image/jpeg', 0.92.toJS);
    return _bytesFromJpegDataUrl(dataUrl);
  }

  /// `data:image/jpeg;base64,<payload>` → raw bytes.
  static Uint8List _bytesFromJpegDataUrl(String dataUrl) {
    final comma = dataUrl.indexOf(',');
    final payload = comma == -1 ? dataUrl : dataUrl.substring(comma + 1);
    final binary = web.window.atob(payload);
    final bytes = Uint8List(binary.length);
    for (var i = 0; i < binary.length; i++) {
      bytes[i] = binary.codeUnitAt(i) & 0xFF;
    }
    return bytes;
  }

  @override
  Future<void> stop() async {
    // Every track, not just video: if audio is ever added to the constraints
    // above, a track-type-specific stop would leave the microphone live.
    final tracks = _stream?.getTracks().toDart ?? const [];
    for (final track in tracks) {
      track.stop();
    }
    _stream = null;
    _video?.srcObject = null;
    _video = null;
  }

  /// The browser's DOMException name, in this app's words.
  static String _messageFor(Object error) {
    final name = error.toString();
    if (name.contains('NotAllowedError') || name.contains('Permission')) {
      return 'Camera access was blocked. Allow the camera for this site in '
          'your browser, then try again.';
    }
    if (name.contains('NotFoundError') || name.contains('DevicesNotFound')) {
      return 'No camera was found on this device.';
    }
    if (name.contains('NotReadableError') || name.contains('TrackStart')) {
      return 'Another app is already using the camera. Close it and try again.';
    }
    return 'The camera could not be started.';
  }
}
