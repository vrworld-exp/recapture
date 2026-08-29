// lib/platform/capture_ports/camera_preview_port_web.dart
//
// WEB implementation of [CameraPreviewPort]: `getUserMedia` into a `<video>`
// element rendered through an `HtmlElementView`.
//
// There is no texture id and no rotation to apply — the browser composites and
// orients the element itself — so [CameraPreviewBinding.textureId] stays null
// and `rotationDegrees` stays 0. That is precisely why
// camera_preview_view.dart must branch on web BEFORE it looks at
// `defaultTargetPlatform` or `hasTexture`: on a phone browser
// `defaultTargetPlatform` reports the host OS, so the widget would otherwise
// take the dead Android `Texture` or iOS `UiKitView` path and render black
// forever.
//
// Mid-session loss (the user revoking camera access from the browser's own UI,
// or another app grabbing the device) arrives as the track's `ended` event and
// is pushed through as `onError`, so the preview shows the same graceful error
// surface a native camera failure produces.
import 'dart:js_interop';

import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;

import 'camera_preview_port.dart';
import 'web_camera_source.dart';

/// Selected by the conditional import in
/// lib/platform/camera/camera_preview_controller.dart on a web build. The
/// channel argument exists only to match the shared factory signature.
CameraPreviewPort createCameraPreviewPort([MethodChannel? channel]) =>
    WebCameraPreviewPort();

/// `getUserMedia`-backed [CameraPreviewPort].
class WebCameraPreviewPort implements CameraPreviewPort {
  WebCameraPreviewPort();

  void Function(CameraPreviewPush push)? _handler;
  JSFunction? _trackEndedListener;
  web.MediaStreamTrack? _watchedTrack;

  @override
  void setPushHandler(void Function(CameraPreviewPush push)? handler) =>
      _handler = handler;

  @override
  Future<CameraPreviewBinding> start() async {
    // Registering the view factory here (not at app boot) keeps the whole web
    // camera path lazy: a build that never opens capture never touches
    // dart:ui_web.
    WebCameraSource.instance.registerViewFactory();
    try {
      final started = await WebCameraSource.instance.start();
      _watchTrackEnded();
      return CameraPreviewBinding(
        previewWidth: started.width,
        previewHeight: started.height,
      );
    } on WebCameraException catch (e) {
      throw CameraPreviewFailure(e.code, e.message);
    }
  }

  @override
  Future<void> stop() async {
    _unwatchTrackEnded();
    await WebCameraSource.instance.stop();
  }

  @override
  Future<void> dispose() async {
    _handler = null;
    _unwatchTrackEnded();
    await WebCameraSource.instance.dispose();
  }

  void _watchTrackEnded() {
    _unwatchTrackEnded();
    final stream = WebCameraSource.instance.stream;
    if (stream == null) return;
    final tracks = stream.getVideoTracks().toDart;
    if (tracks.isEmpty) return;
    final track = tracks.first;
    _watchedTrack = track;
    _trackEndedListener = ((web.Event _) {
      _handler?.call(
        const CameraPreviewPush('onError', {
          'code': 'CAMERA_ENDED',
          'message': 'The camera stopped. Check that no other app or tab is '
              'using it, then try again.',
        }),
      );
    }).toJS;
    track.addEventListener('ended', _trackEndedListener);
  }

  void _unwatchTrackEnded() {
    final listener = _trackEndedListener;
    final track = _watchedTrack;
    if (listener != null && track != null) {
      track.removeEventListener('ended', listener);
    }
    _trackEndedListener = null;
    _watchedTrack = null;
  }
}
