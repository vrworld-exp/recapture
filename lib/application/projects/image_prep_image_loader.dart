// lib/application/projects/image_prep_image_loader.dart
//
// Fetches the ORIGINAL bytes of a selected Preview-gallery photo so the
// Prepare-Images screen can edit a local copy. Reads happen straight off the
// photo's presigned URL with a BARE Dio — the URL carries its own SigV4
// credentials in the query, so the app's authenticated client would corrupt
// the request (same reasoning as preview_download_delivery_io). The presigned
// URL is a bearer credential — never logged.
//
// Behind a seam so widget tests inject synthetic bytes and never touch the
// network. Note: on the WEB build this fetch requires bucket CORS the raw
// bucket does not have — the screen surfaces a per-image load error there.
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/preview_manifest.dart';

/// Seam over "give me this photo's original bytes".
abstract interface class PrepImageLoader {
  /// Throws on any transport/HTTP failure — the screen maps it to a retryable
  /// per-image error tile (mapped copy only, never the URL).
  Future<Uint8List> load(PreviewPhoto photo);
}

class DioPrepImageLoader implements PrepImageLoader {
  const DioPrepImageLoader();

  @override
  Future<Uint8List> load(PreviewPhoto photo) async {
    final http = Dio();
    final res = await http.get<List<int>>(
      photo.url,
      options: Options(
        responseType: ResponseType.bytes,
        // An expired presign returns 403 XML — that must fail loudly, not be
        // decoded as if it were the photo.
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
  (ref) => const DioPrepImageLoader(),
);
