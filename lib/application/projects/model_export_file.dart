// lib/application/projects/model_export_file.dart
//
// One exportable model artifact, as handed to the ModelExporter seam. Lives in
// its own file (not model_export_service.dart) so the per-platform delivery
// variants can import the type without importing the service that
// conditionally imports THEM back.
class ModelExportFile {
  const ModelExportFile({
    required this.url,
    required this.fileName,
    required this.mimeType,
  });

  /// Our CloudFront URL (the backend re-hosts Meshy's expiring results), so it
  /// cannot expire mid-download. Still never logged or shown on screen.
  final String url;

  /// Download filename, e.g. `recapture-model-<id>.glb`.
  final String fileName;

  /// `model/gltf-binary` or `model/vnd.usdz+zip` — what the worker uploaded.
  final String mimeType;
}
