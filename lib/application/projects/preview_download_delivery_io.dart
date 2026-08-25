// lib/application/projects/preview_download_delivery_io.dart
//
// Native (Android / iOS / desktop) preview download: fetch the presigned url's
// bytes with a BARE Dio — the url is a fully-qualified S3 link carrying its own
// SigV4 credentials in the query, so the app's authenticated client would
// corrupt the request — write a temp file, then hand it to the platform share
// sheet (share_plus) so the user saves it to Photos / Files / Downloads.
//
// This is the product-approved mechanism (Download = share sheet): it adds NO
// new plugin and needs NO storage permission, so it never touches the native
// permission facade (see project-staff-preview-gallery). The presigned url is a
// bearer credential — it is never logged.
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../domain/entities/preview_manifest.dart';

Future<void> deliverPreviewDownload(PreviewPhoto photo) async {
  final http = Dio();
  final res = await http.get<List<int>>(
    photo.url,
    options: Options(
      responseType: ResponseType.bytes,
      // A non-2xx (e.g. an expired / re-signed url returning 403) must fail
      // loudly, not silently write S3's error XML to disk as if it were the
      // photo. The caller refreshes the url before we get here, but this is the
      // last line of defence against a saved-but-broken file.
      validateStatus: (status) => status != null && status >= 200 && status < 300,
    ),
  );
  final data = res.data;
  if (data == null || data.isEmpty) {
    throw StateError('Downloaded an empty body.');
  }
  final bytes = Uint8List.fromList(data);

  final dir = (await getTemporaryDirectory()).path;
  // Collision-free, filesystem-safe temp name from the relative key so two
  // rings' identically-named files never clobber each other in temp.
  final safeName = photo.key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final path = '$dir/$safeName';
  await File(path).writeAsBytes(bytes, flush: true);

  await SharePlus.instance.share(ShareParams(
    files: [XFile(path, mimeType: 'image/jpeg')],
    subject: photo.fileName,
  ));
}
