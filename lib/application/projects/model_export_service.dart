// lib/application/projects/model_export_service.dart
//
// The staff-only "Export model" action on the 3D model viewer: saves a
// generated model file (GLB, or USDZ when one exists) into the user's system.
// Delivery is platform-split by conditional import, the exact pattern proven
// by preview_download_service.dart:
//   • native → fetch the CloudFront url's bytes → temp file → share sheet
//     (model_export_delivery_io.dart), so the user saves it to Files/Downloads
//     with NO new plugin and NO storage permission.
//   • web    → anchor download of the url (model_export_delivery_web.dart);
//     model/* content types aren't renderable, so the browser saves the file.
//
// The whole thing sits behind [ModelExporter] so widget tests inject a fake
// and assert "exported exactly once, with THIS file" without touching the
// network, the share sheet, or the browser.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'model_export_file.dart';
import 'model_export_delivery_stub.dart'
    if (dart.library.io) 'model_export_delivery_io.dart'
    if (dart.library.js_interop) 'model_export_delivery_web.dart';

export 'model_export_file.dart';

/// Seam over "export one model file": production delivers per-platform;
/// tests fake it.
abstract interface class ModelExporter {
  Future<void> export(ModelExportFile file);
}

/// Production [ModelExporter]: delegates to the conditionally-imported,
/// per-platform delivery ([deliverModelExport]).
class PlatformModelExporter implements ModelExporter {
  const PlatformModelExporter();

  @override
  Future<void> export(ModelExportFile file) => deliverModelExport(file);
}

/// App-wide model exporter (staff surface). Overridden with a fake in tests.
final modelExporterProvider = Provider<ModelExporter>(
  (ref) => const PlatformModelExporter(),
);
