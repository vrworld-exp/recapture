// lib/platform/capture_ports/capture_image_source_web.dart
//
// WEB half of [captureImage]: resolves an `idb://…` handle through the
// IndexedDB capture store and decodes the JPEG bytes.
//
// Written as a real [ImageProvider] rather than "read bytes, then build a
// MemoryImage" so it keeps everything the file-backed path had: Flutter's image
// cache dedupes by the handle (so a thumbnail shown in the strip and again in
// the review grid decodes once), `ResizeImage` still decodes at tile size
// instead of full resolution, and a deleted frame surfaces through the normal
// image-error channel into the caller's existing `errorBuilder`.
//
// No object URLs are created, so there is none to revoke: the bytes go straight
// from IndexedDB into the decoder and are released with the codec.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'web_capture_store.dart';

ImageProvider createCaptureImage(String path) => IdbCaptureImage(path);

/// An [ImageProvider] over one IndexedDB-stored captured frame.
@immutable
class IdbCaptureImage extends ImageProvider<IdbCaptureImage> {
  const IdbCaptureImage(this.path);

  /// The `idb://{projectId}/{jobId}/{level}/{frameId}.jpg` handle.
  final String path;

  @override
  Future<IdbCaptureImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<IdbCaptureImage>(this);

  @override
  ImageStreamCompleter loadImage(
    IdbCaptureImage key,
    ImageDecoderCallback decode,
  ) =>
      MultiFrameImageStreamCompleter(
        codec: _load(key, decode),
        scale: 1.0,
        debugLabel: key.path,
      );

  static Future<ui.Codec> _load(
    IdbCaptureImage key,
    ImageDecoderCallback decode,
  ) async {
    final bytes = await WebCaptureStore.instance.readBytes(key.path);
    if (bytes == null || bytes.isEmpty) {
      throw StateError('Captured frame is no longer stored: ${key.path}');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      other is IdbCaptureImage && other.path == path;

  @override
  int get hashCode => path.hashCode;
}
