// lib/application/projects/model_export_delivery_web.dart
//
// Web model export: trigger a browser download by pointing a transient anchor
// at the CloudFront url. `model/gltf-binary` / `model/vnd.usdz+zip` are not
// renderable content types, so the browser saves the file instead of
// navigating (on iOS Safari a USDZ opens Quick Look, which itself offers
// save/share — an acceptable, even pleasant, degradation).
//
// The `download` attribute is ignored cross-origin, but it still signals
// "download, don't navigate"; the saved filename comes from the url's last
// path segment (`model.glb` / `model.usdz`). No byte fetch, no blob: the
// anchor path needs zero CORS and zero memory for a file that can run tens
// of MB.
//
// Written against package:web (not dart:html, which is deprecated in this
// SDK). Only ever compiled for the web target — selected by the conditional
// import in model_export_service.dart.
import 'package:web/web.dart' as web;

import 'model_export_file.dart';

Future<void> deliverModelExport(ModelExportFile file) async {
  final anchor = web.HTMLAnchorElement()
    ..href = file.url
    ..download = file.fileName
    ..style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
}
