// lib/application/projects/preview_download_service.dart
//
// The per-photo "Download" action for the staff Preview gallery: fetch the
// bytes of a presigned URL → write a temp file → hand it to the platform share
// sheet (share_plus) so the user saves it to Photos/Files/Drive. This mirrors
// the export-share pattern (project_export_service.dart) and adds NO new plugin
// or permission.
//
// The whole thing sits behind [PreviewDownloader] so widget tests inject a fake
// and assert "shared exactly once" without touching the network or the share
// sheet. The presigned URL is a bearer credential — it is never logged.
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../domain/entities/preview_manifest.dart';

/// Seam over "download one photo": production fetches + shares; tests fake it.
abstract interface class PreviewDownloader {
  Future<void> download(PreviewPhoto photo);
}

/// Production [PreviewDownloader]: bare-Dio byte fetch → temp file → share sheet.
class SharePreviewDownloader implements PreviewDownloader {
  SharePreviewDownloader({Dio? httpClient, Future<String> Function()? tempDirPath})
      // A BARE Dio (no baseUrl, no auth interceptor): the presigned URL is a
      // fully-qualified S3 URL carrying its own credentials in the query — the
      // app's authenticated client would corrupt that request.
      : _http = httpClient ?? Dio(),
        _tempDirPath = tempDirPath ?? (() async => (await getTemporaryDirectory()).path);

  final Dio _http;
  final Future<String> Function() _tempDirPath;

  @override
  Future<void> download(PreviewPhoto photo) async {
    final res = await _http.get<List<int>>(
      photo.url,
      options: Options(responseType: ResponseType.bytes),
    );
    final bytes = Uint8List.fromList(res.data ?? const <int>[]);

    final dir = await _tempDirPath();
    // Derive a collision-free, filesystem-safe name from the relative key so two
    // rings' identically-named files never clobber each other in temp.
    final safeName = photo.key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final path = '$dir/$safeName';
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);

    await SharePlus.instance.share(ShareParams(
      files: [XFile(path, mimeType: 'image/jpeg')],
      subject: photo.fileName,
    ));
  }
}

/// App-wide preview downloader (staff surface). Overridden with a fake in tests.
final previewDownloaderProvider = Provider<PreviewDownloader>(
  (ref) => SharePreviewDownloader(),
);
