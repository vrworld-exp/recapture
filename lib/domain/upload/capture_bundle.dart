// lib/domain/upload/capture_bundle.dart
//
// Pure Dart — NO Flutter / IO imports. The BUNDLE LAYOUT contract + the
// deterministic planner for the upload bundle the packer produces:
//
//   <bundle>/
//     images/EYE/<name>.jpg
//     images/TOP/<name>.jpg
//     images/LOW/<name>.jpg
//     capture_manifest.json      // the reconciled manifest (buildCaptureManifest)
//
// The per-level folders are the backend ring names (EYE/TOP/LOW) — the SAME single
// source the manifest uses ([ringNameForLevelCode]: A→EYE, B→TOP, C→LOW), so a
// level can never be mapped one way in the folder tree and another in the manifest.
//
// The planner is pure + deterministic: given the same accepted-frame set it yields
// the same filenames, relative paths, and order every time (so a re-pack is
// byte-stable and the manifest — generated from this same plan — can never diverge
// from the files on disk). Physical copying + the manifest write are IO wired around
// this (see capture_bundle_packer.dart).
import 'capture_manifest.dart' show ringNameForLevelCode, levelOrderIndex;

/// The bundle's images root folder name.
const String kBundleImagesDir = 'images';

/// The manifest file name at the bundle root — the backend's `capture_manifest.json`
/// (UploadInfo.manifestKey), NOT the native `_manifest.json` job marker.
const String kBundleManifestFileName = 'capture_manifest.json';

/// The bundle-relative directory for a ring's images, e.g. `images/EYE`.
String bundleImageDir(String ringName) => '$kBundleImagesDir/$ringName';

/// The bundle-relative path of one image, e.g. `images/EYE/eye_0001.jpg`. Forward
/// slashes always (a portable bundle reference, independent of the host separator).
String bundleImageRelPath(String ringName, String fileName) =>
    '${bundleImageDir(ringName)}/$fileName';

/// The deterministic, collision-free file name for the [index]-th (1-based) image
/// of [ringName]: `eye_0001.jpg` / `top_0007.jpg` / `low_0012.jpg`. Zero-padded so
/// lexical and numeric order agree.
String bundleImageFileName(String ringName, int index) =>
    '${ringName.toLowerCase()}_${index.toString().padLeft(4, '0')}.jpg';

/// One accepted source frame the planner maps into the bundle. [sourcePath] is the
/// device-absolute JPEG (never mutated — the packer copies it). Ordering keys
/// ([segmentIndex]/[captureTimestampNs]) come from the capture ledger.
class BundleSourceImage {
  const BundleSourceImage({
    required this.sourcePath,
    required this.captureTimestampNs,
    this.segmentIndex,
    this.warned = false,
  });

  /// Device-absolute path of the accepted JPEG (the copy source; read-only).
  final String sourcePath;

  /// Camera-aligned sensor timestamp (ns) — an ordering key.
  final int captureTimestampNs;

  /// Ring segment index (primary ordering key; nulls sort last).
  final int? segmentIndex;

  /// Whether the frame carried an exposure warning (→ manifest verdict).
  final bool warned;
}

/// One level's accepted sources, tagged with the level identity. Passed to
/// [planBundleImages] in flow order.
class BundleLevelSources {
  const BundleLevelSources({
    required this.levelCode,
    required this.levelId,
    required this.images,
  });

  /// Display code "A"/"B"/"C" (drives ring folder + ordering).
  final String levelCode;

  /// The `PitchBand.id` ("mid"/"high"/"low").
  final String levelId;

  final List<BundleSourceImage> images;
}

/// A source frame resolved to its deterministic bundle destination.
class PlannedBundleImage {
  const PlannedBundleImage({
    required this.levelCode,
    required this.levelId,
    required this.ringName,
    required this.sourcePath,
    required this.fileName,
    required this.relPath,
    required this.index,
    required this.captureTimestampNs,
    this.segmentIndex,
    this.warned = false,
  });

  final String levelCode;
  final String levelId;

  /// EYE / TOP / LOW.
  final String ringName;

  /// Device-absolute copy source (read-only).
  final String sourcePath;

  /// Deterministic bundle file name (e.g. `eye_0001.jpg`).
  final String fileName;

  /// Bundle-relative path (e.g. `images/EYE/eye_0001.jpg`).
  final String relPath;

  /// 1-based per-level index (drives [fileName]).
  final int index;

  final int captureTimestampNs;
  final int? segmentIndex;
  final bool warned;
}

/// Plans every accepted source into its deterministic bundle destination. Levels
/// are processed in canonical flow order (A→B→C via [levelOrderIndex]); within a
/// level, images sort by (segmentIndex[nulls-last], captureTimestampNs, sourcePath),
/// sources sharing a NON-NULL segmentIndex collapse to the NEWEST one (a retake
/// appends a second ledger record for the same segment — the bundle carries at
/// most ONE image per ring segment, so segment-tracked rings can never exceed
/// their segment count; the backend rejects a ring with more than its variant
/// per-ring total), and the survivors are numbered 1..N. Sources with a null
/// segmentIndex (no live segment at capture time) are all kept — they cannot be
/// attributed to a segment, so no dedupe key exists for them. Same input →
/// identical plan (names, paths, order).
List<PlannedBundleImage> planBundleImages(List<BundleLevelSources> levels) {
  final ordered = [...levels]
    ..sort((a, b) {
      final byOrder =
          levelOrderIndex(a.levelCode).compareTo(levelOrderIndex(b.levelCode));
      return byOrder != 0 ? byOrder : a.levelId.compareTo(b.levelId);
    });

  final out = <PlannedBundleImage>[];
  for (final level in ordered) {
    final ring = ringNameForLevelCode(level.levelCode);
    final sorted = _dedupePerSegment([...level.images]..sort(_compareSources));
    for (var i = 0; i < sorted.length; i++) {
      final src = sorted[i];
      final index = i + 1;
      final fileName = bundleImageFileName(ring, index);
      out.add(PlannedBundleImage(
        levelCode: level.levelCode,
        levelId: level.levelId,
        ringName: ring,
        sourcePath: src.sourcePath,
        fileName: fileName,
        relPath: bundleImageRelPath(ring, fileName),
        index: index,
        captureTimestampNs: src.captureTimestampNs,
        segmentIndex: src.segmentIndex,
        warned: src.warned,
      ));
    }
  }
  return out;
}

/// Collapses sources sharing a non-null segmentIndex to ONE — the last in sort
/// order, i.e. the newest capture (largest captureTimestampNs; path breaks
/// ties), so a retake replaces the original shot in the bundle. Input must be
/// sorted by [_compareSources] (equal segments are adjacent, oldest first).
List<BundleSourceImage> _dedupePerSegment(List<BundleSourceImage> sorted) {
  final out = <BundleSourceImage>[];
  for (final src in sorted) {
    if (src.segmentIndex != null &&
        out.isNotEmpty &&
        out.last.segmentIndex == src.segmentIndex) {
      out[out.length - 1] = src; // later sort position = newer capture wins
    } else {
      out.add(src);
    }
  }
  return out;
}

int _compareSources(BundleSourceImage a, BundleSourceImage b) {
  final as = a.segmentIndex, bs = b.segmentIndex;
  if (as != bs) {
    if (as == null) return 1; // nulls last
    if (bs == null) return -1;
    final bySeg = as.compareTo(bs);
    if (bySeg != 0) return bySeg;
  }
  final byTs = a.captureTimestampNs.compareTo(b.captureTimestampNs);
  if (byTs != 0) return byTs;
  return a.sourcePath.compareTo(b.sourcePath);
}

/// Why a pack failed — the `reason` carried on `bundle_pack_failed` telemetry and
/// mapped to a Screen 9F `error_category` when packing is the cause of an upload
/// failure.
enum BundlePackFailureReason {
  missingSourceFile('missing_source_file'),
  insufficientStorage('insufficient_storage'),
  encodeError('encode_error'),
  checksumError('checksum_error'),
  integrityMismatch('integrity_mismatch'),
  cancelled('cancelled'),
  unknown('unknown');

  const BundlePackFailureReason(this.wireName);

  /// The stable telemetry value.
  final String wireName;
}

/// Raised when a pack fails or is cancelled. Carries the [reason] and the [stage]
/// it failed at (telemetry); never leaks the raw underlying error to the UI.
class BundlePackException implements Exception {
  const BundlePackException(this.reason, {this.stage = 'unknown', this.detail});

  final BundlePackFailureReason reason;

  /// The pack stage that failed ("stage", "manifest", "verify", "finalize", …).
  final String stage;

  /// Optional non-PII diagnostic detail (logs only; not shown to the user).
  final String? detail;

  bool get isCancelled => reason == BundlePackFailureReason.cancelled;

  @override
  String toString() =>
      'BundlePackException(${reason.wireName} at $stage${detail == null ? '' : ': $detail'})';
}

/// The finalized bundle handle handed to the upload engine — a fully written,
/// verified directory. Immutable value.
class CaptureBundle {
  const CaptureBundle({
    required this.path,
    required this.manifestPath,
    required this.totalImages,
    required this.totalBytes,
    required this.perLevelCounts,
  });

  /// Absolute path of the finalized bundle directory.
  final String path;

  /// Absolute path of the bundle's `capture_manifest.json`.
  final String manifestPath;

  final int totalImages;

  /// On-disk bytes of the copied images (excludes the manifest).
  final int totalBytes;

  /// Images per ring name (EYE/TOP/LOW → count), in flow order.
  final Map<String, int> perLevelCounts;
}
