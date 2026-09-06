// lib/domain/entities/preview_manifest.dart
//
// Typed model of a project's capture set as the Preview gallery consumes it,
// parsed ONCE at the repo seam so no untyped map (and no stray URL handling)
// leaks into the widgets.
//
// It is fed by TWO endpoints, which is the point:
//   • GET /admin/projects/:id/photos — keys + sizes, NO credentials. This is
//     what a gallery open costs, and it is not rate-limited.
//   • GET /admin/projects/:id/export — the same set plus a presigned url per
//     file. Rate-limited (the urls are bearer credentials), so it is fetched
//     only when a downloadable url is actually needed.
//
// Hence [PreviewPhoto.url] is NULLABLE: a listed photo has no url and is drawn
// through the authenticated photo-bytes proxy instead. Thumbnails must never
// depend on a presigned url again — that coupling is what made ten gallery
// opens exhaust a budget meant for ten real exports.

/// One capture photo: its job-root-relative [key] (stable identity, e.g.
/// `images/EYE/eye_0001.jpg`), byte [size], and — only when it came from an
/// export manifest — a presigned [url] (bearer credential; never logged).
class PreviewPhoto {
  const PreviewPhoto({required this.key, required this.size, this.url});

  final String key;
  final int size;

  /// Presigned download url, or null when this photo was merely LISTED. Null is
  /// the normal case in the gallery; the download path mints one on demand.
  final String? url;

  /// A short label for the viewer (the file name, not the full key path).
  String get fileName {
    final slash = key.lastIndexOf('/');
    return slash < 0 ? key : key.substring(slash + 1);
  }

  /// Defensive parse — a malformed row is dropped by the caller, never crashes.
  /// Only [key] is required: an absent/empty url yields a listed photo, which
  /// renders through the proxy exactly like every other tile.
  static PreviewPhoto? tryFromMap(Object? raw) {
    if (raw is! Map) return null;
    final key = (raw['key'] ?? '').toString();
    if (key.isEmpty) return null;
    final url = (raw['url'] ?? '').toString();
    final size = raw['size'];
    return PreviewPhoto(
      key: key,
      size: size is num && size >= 0 ? size.toInt() : 0,
      url: url.isEmpty ? null : url,
    );
  }
}

/// The parsed capture set backing one Preview gallery session.
class PreviewManifest {
  const PreviewManifest({
    required this.files,
    required this.expiresAt,
    required this.fileCount,
    required this.expectedFileCount,
  });

  final List<PreviewPhoto> files;

  /// When the presigned urls stop working, or null when this set was LISTED
  /// (nothing to expire) — drives the "links expire at HH:MM" note, which is
  /// therefore absent in the normal browse case.
  final DateTime? expiresAt;

  /// Server-reported listed count (the server's truth). May differ from
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

  /// Parses the credential-free `photos` object from `GET /…/photos`.
  factory PreviewManifest.fromPhotosMap(Map<String, dynamic> map) =>
      PreviewManifest._from(map, expiresAt: null);

  /// Parses the raw `export` object (the same map [LiveProjectsRepository.export]
  /// returns), keeping each file's presigned url.
  factory PreviewManifest.fromExportMap(Map<String, dynamic> map) =>
      PreviewManifest._from(
        map,
        expiresAt: DateTime.tryParse((map['expiresAt'] ?? '').toString()),
      );

  /// Shared body of both factories — the two payloads differ only in whether a
  /// file carries a url and whether the set expires. Unparsable rows are
  /// skipped so one bad entry can't blank the whole grid.
  factory PreviewManifest._from(
    Map<String, dynamic> map, {
    required DateTime? expiresAt,
  }) {
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
      expiresAt: expiresAt,
      fileCount: rawFileCount is num ? rawFileCount.toInt() : files.length,
      expectedFileCount: rawExpected is num ? rawExpected.toInt() : files.length,
    );
  }
}
