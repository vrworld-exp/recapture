// lib/domain/entities/capture_thumbnail.dart
//
// Pure Dart — NO Flutter imports. A reference to one recently-captured photo for
// the Level A thumbnail strip. The strip DISPLAYS these (loading the image from
// [filePath]); the parent owns the authoritative capture set, capture, and save.
class CaptureThumbnail {
  const CaptureThumbnail({
    required this.id,
    required this.filePath,
    required this.capturedAt,
  });

  /// Stable id (capture id / ring index) — the strip keys tiles by this so they
  /// reuse correctly as items shift, and a re-capture of the same id updates
  /// rather than duplicating.
  final String id;

  /// Local path to the captured image.
  final String filePath;

  /// When it was captured — the strip orders newest-first by this.
  final DateTime capturedAt;

  @override
  bool operator ==(Object other) =>
      other is CaptureThumbnail &&
      other.id == id &&
      other.filePath == filePath &&
      other.capturedAt == capturedAt;

  @override
  int get hashCode => Object.hash(id, filePath, capturedAt);
}
