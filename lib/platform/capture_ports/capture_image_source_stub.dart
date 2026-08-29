// lib/platform/capture_ports/capture_image_source_stub.dart
//
// Compile-time fallback for [captureImage] on a target with neither `dart:io`
// nor `dart:js_interop`. It resolves to an image that always fails to load, so
// the caller's existing `errorBuilder` renders its broken-image placeholder —
// the same surface a missing file produces — rather than throwing at import
// time.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

ImageProvider createCaptureImage(String path) => _UnsupportedCaptureImage(path);

@immutable
class _UnsupportedCaptureImage extends ImageProvider<_UnsupportedCaptureImage> {
  const _UnsupportedCaptureImage(this.path);

  final String path;

  @override
  Future<_UnsupportedCaptureImage> obtainKey(
          ImageConfiguration configuration) =>
      SynchronousFuture<_UnsupportedCaptureImage>(this);

  @override
  ImageStreamCompleter loadImage(
    _UnsupportedCaptureImage key,
    ImageDecoderCallback decode,
  ) =>
      MultiFrameImageStreamCompleter(
        codec: Future<ui.Codec>.error(
          StateError('Captured frames cannot be read on this platform.'),
        ),
        scale: 1.0,
      );

  @override
  bool operator ==(Object other) =>
      other is _UnsupportedCaptureImage && other.path == path;

  @override
  int get hashCode => path.hashCode;
}
