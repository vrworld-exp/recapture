// lib/domain/entities/preview_manifest.dart
//
// Typed model of the staff export manifest as the Preview gallery consumes it.
// The raw `GET /admin/projects/:id/export` response is a `Map<String,dynamic>`
// full of presigned-URL bearer credentials; this parses it ONCE at the repo
// seam so no untyped map (and no stray URL handling) leaks into the widgets.
//
// A `PreviewPhoto.url` is used as BOTH the thumbnail source and the download
// URL — it expires (~1h, ADMIN_EXPORT_URL_TTL_SECONDS), so the manifest is held
// for the lifetime of one Preview open and never re-requested per thumbnail.

/// One capturable object: its job-root-relative [key] (stable identity, e.g.
/// `images/EYE/eye_0001.jpg`), its presigned [url] (bearer credential — never
/// logged), and byte [size].
class PreviewPhoto {
  const PreviewPhoto({required this.key, required this.url, required this.size});

  final String key;
  final String url;
  final int size;

  /// A short label for the viewer (the file name, not the full key path).
  String get fileName {
    final slash = key.lastIndexOf('/');
    return slash < 0 ? key : key.substring(slash + 1);
  }

  /// Defensive parse — a malformed row is dropped by the caller, never crashes.
  static PreviewPhoto? tryFromMap(Object? raw) {
    if (raw is! Map) return null;
    final key = (raw['key'] ?? '').toString();
    final url = (raw['url'] ?? '').toString();
    if (key.isEmpty || url.isEmpty) return null;
    final size = raw['size'];
    return PreviewPhoto(
      key: key,
      url: url,
      size: size is num && size >= 0 ? size.toInt() : 0,
    );
  }
}

/// The parsed export manifest backing one Preview gallery session.
class PreviewManifest {
  const PreviewManifest({
    required this.files,
    required this.expiresAt,
    required this.fileCount,
    required this.expectedFileCount,
  });

  final List<PreviewPhoto> files;

  /// When the presigned URLs stop working (null if unparsable) — drives the
  /// subtle "links expire at HH:MM" note.
  final DateTime? expiresAt;

  /// Server-reported listed count (the export's truth). May differ from
  /// [files.length] only if a row failed to parse.
  final int fileCount;

  /// The job's verified expectation — a drift below it (e.g. after a delete) is
  /// surfaced, not hidden.
  final int expectedFileCount;

  PreviewManifest copyWithFiles(List<PreviewPhoto> next) => PreviewManifest(
        files: next,
        expiresAt: expiresAt,
        fileCount: next.length,
        expectedFileCount: expectedFileCount,
      );

  /// Parses the raw `export` object (the same map [LiveProjectsRepository.export]
  /// returns). Unparsable file rows are skipped so one bad entry can't blank the
  /// whole grid.
  factory PreviewManifest.fromExportMap(Map<String, dynamic> map) {
    final rawFiles = map['files'];
    final files = <PreviewPhoto>[
      if (rawFiles is List)
        for (final entry in rawFiles)
          if (PreviewPhoto.tryFromMap(entry) case final photo?) photo,
    ];
    final rawFileCount = map['fileCount'];
    final rawExpected = map['expectedFileCount'];
    return PreviewManifest(
      files: files,
      expiresAt: DateTime.tryParse((map['expiresAt'] ?? '').toString()),
      fileCount: rawFileCount is num ? rawFileCount.toInt() : files.length,
      expectedFileCount: rawExpected is num ? rawExpected.toInt() : files.length,
    );
  }
}
