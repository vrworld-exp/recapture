// lib/data/remote/admin_photo_image.dart
//
// An [ImageProvider] that loads a capture photo through the AUTHENTICATED staff
// proxy `GET /admin/projects/:id/photo-bytes?key=…`, rather than from a
// presigned S3 url.
//
// Why not Image.network: that endpoint needs the staff bearer token, and
// minting a presigned url instead would spend the server's rate-limited export
// budget on something as routine as drawing a thumbnail. Going through the
// app's configured [dioProvider] client inherits both the token attach AND the
// 401-refresh interceptor, so a long browse session survives a token rotation
// that a baked-in header would not.
//
// Identity is (projectId, photoKey, maxWidth) — deliberately NOT the Dio
// instance — so Flutter's ImageCache dedupes the same photo across tiles and
// rebuilds, and a thumbnail and its full-size view stay distinct entries.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

@immutable
class AdminPhotoImage extends ImageProvider<AdminPhotoImage> {
  const AdminPhotoImage({
    required this.dio,
    required this.projectId,
    required this.photoKey,
    this.maxWidth,
    this.scale = 1.0,
  });

  /// The app's authenticated client (token attach + 401 refresh).
  final Dio dio;

  final String projectId;

  /// The job-root-relative key, e.g. `images/EYE/eye_0001.jpg`.
  final String photoKey;

  /// Server-side downscale target in px. Pass a grid-sized value for tiles so a
  /// 30-photo gallery doesn't pull 30 full-resolution captures; omit for the
  /// full-screen viewer, which wants the original.
  final int? maxWidth;

  final double scale;

  @override
  Future<AdminPhotoImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<AdminPhotoImage>(this);

  @override
  ImageStreamCompleter loadImage(
    AdminPhotoImage key,
    ImageDecoderCallback decode,
  ) {
    // Real download progress, so a caller's `loadingBuilder` can show a spinner
    // instead of an empty frame (Image only reports progress when the provider
    // emits chunk events).
    final chunks = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _fetch(key, decode, chunks),
      chunkEvents: chunks.stream,
      scale: key.scale,
      debugLabel: 'AdminPhotoImage(${key.projectId}/${key.photoKey})',
    );
  }

  Future<ui.Codec> _fetch(
    AdminPhotoImage key,
    ImageDecoderCallback decode,
    StreamController<ImageChunkEvent> chunks,
  ) async {
    try {
      final res = await key.dio.get<List<int>>(
        '/admin/projects/${key.projectId}/photo-bytes',
        queryParameters: {
          'key': key.photoKey,
          if (key.maxWidth != null) 'w': key.maxWidth,
        },
        options: Options(responseType: ResponseType.bytes),
        onReceiveProgress: (received, total) {
          if (chunks.isClosed) return;
          chunks.add(ImageChunkEvent(
            cumulativeBytesLoaded: received,
            // Dio reports -1 when the server sends no Content-Length.
            expectedTotalBytes: total < 0 ? null : total,
          ));
        },
      );
      final data = res.data;
      if (data == null || data.isEmpty) {
        // Surfaces through the caller's errorBuilder as a broken tile, which is
        // the truthful outcome — an empty body is not a decodable image.
        throw StateError('Empty photo body for ${key.photoKey}');
      }
      final buffer = await ui.ImmutableBuffer.fromUint8List(
        data is Uint8List ? data : Uint8List.fromList(data),
      );
      return decode(buffer);
    } finally {
      // Must close, or the completer waits on the chunk stream forever.
      unawaited(chunks.close());
    }
  }

  @override
  bool operator ==(Object other) =>
      other is AdminPhotoImage &&
      other.projectId == projectId &&
      other.photoKey == photoKey &&
      other.maxWidth == maxWidth &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(projectId, photoKey, maxWidth, scale);

  @override
  String toString() =>
      'AdminPhotoImage($projectId/$photoKey, maxWidth: $maxWidth)';
}
