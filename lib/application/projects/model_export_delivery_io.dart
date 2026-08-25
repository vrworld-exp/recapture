// lib/application/projects/model_export_delivery_io.dart
//
// Native (Android / iOS / desktop) model export: fetch the CloudFront url's
// bytes with a BARE Dio — the CDN is public and cache-keyed, and the app's
// authenticated client would add headers the request doesn't want — write a
// temp file, then hand it to the platform share sheet (share_plus) so the user
// saves it to Files / Downloads or sends it to another app (Blender, a DCC
// tool, AirDrop…).
//
// Same product-approved mechanism as the Preview gallery download (Export =
// share sheet): no new plugin, no storage permission, never touches the native
// permission facade. GLBs run tens of MB — they go through a temp file, never
// a UI-thread byte juggle beyond the single write.
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'model_export_file.dart';

Future<void> deliverModelExport(ModelExportFile file) async {
  final http = Dio();
  final res = await http.get<List<int>>(
    file.url,
    options: Options(
      responseType: ResponseType.bytes,
      // A non-2xx must fail loudly, not silently share an error body as if it
      // were the model.
      validateStatus: (status) => status != null && status >= 200 && status < 300,
    ),
  );
  final data = res.data;
  if (data == null || data.isEmpty) {
    throw StateError('Downloaded an empty body.');
  }
  final bytes = Uint8List.fromList(data);

  final dir = (await getTemporaryDirectory()).path;
  // Filesystem-safe temp name (the id-derived name is already safe today;
  // this guards a future rename).
  final safeName = file.fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final path = '$dir/$safeName';
  await File(path).writeAsBytes(bytes, flush: true);

  await SharePlus.instance.share(ShareParams(
    files: [XFile(path, mimeType: file.mimeType)],
    subject: file.fileName,
  ));
}
