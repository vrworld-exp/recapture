// lib/application/projects/image_prep_image_loader.dart
//
// Fetches the ORIGINAL bytes of a selected Preview-gallery photo so the
// Prepare-Images screen can edit a local copy.
//
// TWO transports, tried in order:
//   1. The photo's presigned URL, straight to S3 with a BARE Dio — the URL
//      carries its own SigV4 credentials in the query, so the app's
//      authenticated client would corrupt the request (same reasoning as
//      preview_download_delivery_io). Fast, and costs our API nothing.
//   2. On ANY failure, the API's read-through proxy
//      (GET /admin/projects/:id/photo-bytes). This is what makes the screen
//      work on the WEB build — the raw bucket serves no CORS, so step 1 can
//      never succeed there — and it also rescues a long session whose presign
//      has expired (~1h), which used to strand the screen on device too.
//
// The presigned URL is a bearer credential — never logged.
//
// Behind a seam so widget tests inject synthetic bytes and never touch the
// network — or the image codec, which is why MEASURING the image lives here
// too rather than in the screen (see [LoadedPrepImage.width]).
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/live_projects_repository.dart';
import '../../domain/entities/preview_manifest.dart';

/// One fetched photo: its bytes and the dimensions it will actually DISPLAY at.
class LoadedPrepImage {
  const LoadedPrepImage({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;

  /// EXIF-APPLIED dimensions — what Image.memory renders, which is the box
  /// every normalized crop coordinate is measured against. Our captures carry
  /// orientation as a tag rather than rotated pixels, so a raw JPEG header
  /// read reports these swapped on a portrait shot and skews the whole crop.
  final int width;
  final int height;
}

/// Seam over "give me this photo's original bytes, and its display size".
abstract interface class PrepImageLoader {
  /// Throws only when BOTH transports fail — the screen then maps it to a
  /// retryable per-image error tile (mapped copy only, never the URL).
  Future<LoadedPrepImage> load(String projectId, PreviewPhoto photo);
}

class DioPrepImageLoader implements PrepImageLoader {
  const DioPrepImageLoader(this._repository);

  final LiveProjectsRepository _repository;

  @override
  Future<LoadedPrepImage> load(String projectId, PreviewPhoto photo) async {
    Uint8List bytes;
    try {
      bytes = await _fetchPresigned(photo);
    } catch (_) {
      // Deliberately catch-all: CORS rejections, expired presigns and plain
      // transport faults are indistinguishable here, and the proxy handles all
      // three. If IT fails too, that error propagates to the screen.
      bytes = await _repository.fetchPhotoBytes(projectId, photo.key);
    }
    return _measure(bytes);
  }

  /// Decodes through dart:ui — the ONLY decoder that applies EXIF orientation,
  /// and the same one Image.memory uses, so the reported size is exactly what
  /// the preview will lay out.
  Future<LoadedPrepImage> _measure(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      final image = LoadedPrepImage(
        bytes: bytes,
        width: frame.image.width,
        height: frame.image.height,
      );
      frame.image.dispose();
      return image;
    } finally {
      codec.dispose();
    }
  }

  Future<Uint8List> _fetchPresigned(PreviewPhoto photo) async {
    final http = Dio();
    final res = await http.get<List<int>>(
      photo.url,
      options: Options(
        responseType: ResponseType.bytes,
        // An expired presign returns 403 XML — that must fail loudly (and fall
        // through to the proxy), not be decoded as if it were the photo.
        validateStatus: (status) =>
            status != null && status >= 200 && status < 300,
      ),
    );
    final data = res.data;
    if (data == null || data.isEmpty) {
      throw StateError('Downloaded an empty body.');
    }
    return Uint8List.fromList(data);
  }
}

/// App-wide prep-image loader (staff Prepare-Images surface).
final prepImageLoaderProvider = Provider<PrepImageLoader>(
  (ref) => DioPrepImageLoader(ref.watch(liveProjectsRepositoryProvider)),
);
