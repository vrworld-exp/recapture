// lib/application/projects/model_export_delivery_stub.dart
//
// Compile-time fallback for the platform-split model export delivery. The
// real implementation is chosen by conditional import in
// model_export_service.dart: `dart:io` (native — fetch bytes → temp file →
// share sheet) or js-interop web (anchor download). This stub is only
// reachable on a hypothetical platform that has neither library; it fails
// loudly rather than silently no-op-ing.
import 'model_export_file.dart';

Future<void> deliverModelExport(ModelExportFile file) =>
    throw UnsupportedError('Model export is not supported on this platform.');
