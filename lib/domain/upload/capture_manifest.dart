// lib/domain/upload/capture_manifest.dart
//
// Pure Dart — NO Flutter / Hive / IO imports. The DETERMINISTIC assembler of the
// `capture_manifest.json` document: the single index the backend ingests to
// understand and reconstruct a capture session. It AGGREGATES (never recomputes):
//   • session identity  (project / job / capture-session ids, timestamps, app ver)
//   • device info        (platform + descriptor + camera intrinsics)
//   • capture config     (config version, object size, thresholds, segment counts)
//   • levels + coverage  (READ from the progression controller — see ManifestLevel)
//   • per-photo metadata (the sidecar shape embedded LOSSLESSLY — see ManifestPhoto)
//   • a rolled-up summary (mirrors the backend CaptureSummary shape)
//
// TWO RECONCILIATIONS this file honours:
//
//   1. PRD / BACKEND-authoritative summary shape. The backend derives
//      `Job.captureSummary` from this manifest (recapture-api capture.types.ts:
//      CaptureSummary / CaptureLevels / LevelSummary). So the manifest's `summary`
//      block is byte-shaped to that contract: `levels` keyed by the ring name
//      (EYE / TOP / LOW), each `{ photos, coverage, segmentCount, warnings }`, plus
//      `totalPhotos` and `warningsCount`. The app's A/B/C levels map onto those ring
//      names via [ringNameForLevelCode] (A→EYE, B→TOP, C→LOW).
//
//   2. Per-photo entries stay CONSISTENT with the CapturePhotoMetadata model + the
//      native sidecar. Each photo entry embeds the sidecar verbatim under
//      `metadata` (== CapturePhotoMetadata.toJson()), so it round-trips losslessly
//      via CapturePhotoMetadata.fromJson — no divergent per-photo shape. The
//      guided-capture context the sidecar deliberately does NOT carry (level,
//      segment, verdict, quality, orientation) rides ALONGSIDE it as sibling keys
//      (the documented "join" — see capture_photo_metadata.dart's reconciliation
//      note). A null `pose` inside `metadata` stays a reserved null, exactly as the
//      sidecar writes it.
//
// DETERMINISM: same inputs → byte-identical manifest. Levels are emitted in
// canonical flow order (A→B→C via [levelOrderIndex]); photos are sorted by
// (levelCode, segmentIndex[nulls-last], captureTimestampNs, photoId). Dart map
// literals preserve insertion order, so `jsonEncode` over the returned map is
// stable and diffable.
//
// NOT the native `_manifest.json` (storage/JobManifest) — that is a tiny
// start/complete job MARKER for incomplete-job detection. This is the rich upload
// INDEX. They are distinct files with distinct purposes.
//
// PURITY: this builds a Map only. Reading the sidecars off disk and writing the
// JSON file are IO wired around it (see capture_manifest_assembler.dart).
import '../entities/capture_config.dart';
import '../entities/capture_photo_metadata.dart';
import 'file_checksum.dart' show kChecksumAlgorithmMd5;

/// Manifest schema version — bump on any breaking shape change so the backend can
/// branch on evolution. Emitted as the top-level `manifestVersion`.
const String kCaptureManifestVersion = '1.0';

/// Canonical flow-order index for a display level code ("A"/"B"/"C"). Unknown codes
/// sort last (stable). Drives deterministic level ordering.
int levelOrderIndex(String levelCode) => switch (levelCode.toUpperCase()) {
      'A' => 0,
      'B' => 1,
      'C' => 2,
      _ => 1 << 20,
    };

/// The backend ring name for a display level code — the key the backend
/// `CaptureLevels` uses (recapture-api capture.types.ts). A→EYE, B→TOP, C→LOW; an
/// unknown code passes through uppercased so nothing is silently dropped.
String ringNameForLevelCode(String levelCode) => switch (levelCode.toUpperCase()) {
      'A' => 'EYE',
      'B' => 'TOP',
      'C' => 'LOW',
      _ => levelCode.toUpperCase(),
    };

/// Session identity + timing for the manifest header. Timestamps are ISO-8601 UTC
/// strings (or null when not observed — omitted, never fabricated).
class ManifestSession {
  const ManifestSession({
    required this.projectId,
    required this.jobId,
    required this.captureSessionId,
    this.startedAtIso,
    this.completedAtIso,
    this.appVersion,
    this.objectSize,
  });

  /// The owning project id (path segment `/recapture/{projectId}/…`).
  final String projectId;

  /// The capture job id (path segment `…/{jobId}/…`) — one upload bundle.
  final String jobId;

  /// The in-app capture-session id (the ledger/sidecar `sessionId`). May equal
  /// [jobId] or be distinct depending on wiring; carried explicitly so the backend
  /// can pair per-photo `metadata.sessionId` to the session.
  final String captureSessionId;

  /// ISO-8601 UTC start of the session, or null if unknown (omitted).
  final String? startedAtIso;

  /// ISO-8601 UTC completion (manifest build time), or null if unknown (omitted).
  final String? completedAtIso;

  /// ReCapture app version (e.g. "1.0.3"), or null (omitted).
  final String? appVersion;

  /// Object-size preset applied ("SMALL"/"MEDIUM"/"LARGE"), or null when the
  /// project carries none (omitted — the app has no size field today).
  final String? objectSize;
}

/// Device descriptor for the manifest header. `platform` is always present; every
/// other field is nullable and OMITTED when null (never fabricated — matches the
/// sidecar/device null policy). Camera [intrinsics] reuse the sidecar's
/// [CaptureIntrinsics] (which itself omits its null fields).
class ManifestDevice {
  const ManifestDevice({
    required this.platform,
    this.manufacturer,
    this.model,
    this.osVersion,
    this.appVersion,
    this.cameraId,
    this.intrinsics = CaptureIntrinsics.empty,
  });

  /// "android" | "ios".
  final String platform;
  final String? manufacturer;
  final String? model;
  final String? osVersion;
  final String? appVersion;
  final String? cameraId;

  /// Camera intrinsics (focal length / sensor). Empty → an empty `{}` object.
  final CaptureIntrinsics intrinsics;

  Map<String, dynamic> toJson() => {
        'platform': platform,
        if (manufacturer != null) 'manufacturer': manufacturer,
        if (model != null) 'model': model,
        if (osVersion != null) 'osVersion': osVersion,
        if (appVersion != null) 'appVersion': appVersion,
        if (cameraId != null) 'cameraId': cameraId,
        'intrinsics': intrinsics.toJson(),
      };
}

/// One level's STRUCTURE + coverage, READ from the progression controller — the
/// builder never recomputes these from yaw. [filledCount]/[segmentCount]/
/// [coveragePct]/[complete] all come from the level's LevelProgressState; the
/// builder only serializes them and joins the photos belonging to the level.
class ManifestLevel {
  const ManifestLevel({
    required this.levelCode,
    required this.levelId,
    required this.segmentCount,
    required this.filledCount,
    required this.coveragePct,
    required this.complete,
    this.pitchBandMinDegrees,
    this.pitchBandMaxDegrees,
  });

  /// Display code "A"/"B"/"C" (drives ring name + ordering).
  final String levelCode;

  /// The `PitchBand.id` ("mid"/"high"/"low") — the per-level key the photos join on.
  final String levelId;

  /// Ring positions (N) for this level (from the object-size config).
  final int segmentCount;

  /// Filled segments (from the level's SegmentCoverage via progression). READ.
  final int filledCount;

  /// Ring coverage 0..100 (from progression). READ — not recomputed here.
  final int coveragePct;

  /// The level's completion-gate verdict (from progression). READ.
  final bool complete;

  /// Inclusive pitch-band floor in degrees (from CaptureConfig), or null (omitted).
  final double? pitchBandMinDegrees;

  /// Exclusive pitch-band ceiling in degrees (from CaptureConfig), or null (omitted).
  final double? pitchBandMaxDegrees;
}

/// One accepted photo — the "join" of the native sidecar ([metadata], embedded
/// losslessly) with the guided-capture context the sidecar does not carry
/// (level / segment / verdict / quality / orientation) plus its storage-path
/// references. This is the single per-photo representation; it round-trips with the
/// sidecar via `CapturePhotoMetadata.fromJson(entry['metadata'])`.
class ManifestPhoto {
  const ManifestPhoto({
    required this.photoId,
    required this.levelCode,
    required this.levelId,
    required this.imagePath,
    required this.verdict,
    required this.captureTimestampNs,
    this.sidecarPath,
    this.segmentIndex,
    this.blurScore,
    this.meanLuminance,
    this.yawDegrees,
    this.pitchDegrees,
    this.metadata,
    this.checksumMd5,
  });

  /// Stable per-photo id (the ledger's frame key — matches `metadata.frameId`).
  final String photoId;

  final String levelCode;
  final String levelId;

  /// Portable storage-path reference to the JPEG the upload sends
  /// (`recapture/{projectId}/{jobId}/images/{level}/<frame>.jpg`) — how the backend
  /// pairs this entry to the uploaded file. NOT the device-absolute path.
  final String imagePath;

  /// Storage-path reference to the paired sidecar (`…/<frame>.json`), or null when
  /// no separate sidecar file accompanies the image (e.g. a self-contained bundle
  /// that embeds the sidecar under [metadata] instead of shipping the file).
  final String? sidecarPath;

  /// "accepted" | "warn" (exposure-warned but kept). Rejected attempts are not
  /// manifest entries.
  final String verdict;

  /// Camera-aligned sensor timestamp (ns) — the ordering/alignment key.
  final int captureTimestampNs;

  /// Ring segment index this photo fills, or null for a segment-less level.
  final int? segmentIndex;

  /// Sharpness (variance of Laplacian) — guided-capture quality (not in sidecar).
  final double? blurScore;

  /// Mean luminance 0–255 — guided-capture quality (not in sidecar).
  final double? meanLuminance;

  /// Device yaw in degrees at capture (not in sidecar).
  final double? yawDegrees;

  /// Device pitch in degrees at capture (not in sidecar).
  final double? pitchDegrees;

  /// The per-frame sidecar, embedded verbatim (lossless round-trip). Null when the
  /// sidecar could not be read — the entry is kept (never fabricated) with
  /// `metadata: null` so the backend can detect the gap.
  final CapturePhotoMetadata? metadata;

  /// Lowercase-hex MD5 of the image FILE's bytes, for end-to-end backend integrity
  /// verification. DISTINCT from any S3 multipart ETag (a different value/purpose —
  /// never cross-assigned). Null only when checksums aren't computed for this
  /// manifest (the upload bundle always populates it); emitted with an explicit
  /// `checksumAlgorithm` so the algorithm is never implied. See [FileChecksum].
  final String? checksumMd5;

  Map<String, dynamic> toJson() => {
        'photoId': photoId,
        'levelCode': levelCode,
        'levelId': levelId,
        'ringName': ringNameForLevelCode(levelCode),
        'segmentIndex': segmentIndex,
        'verdict': verdict,
        'captureTimestampNs': captureTimestampNs,
        'quality': {
          'blurScore': blurScore,
          'meanLuminance': meanLuminance,
        },
        'orientation': {
          'yawDegrees': yawDegrees,
          'pitchDegrees': pitchDegrees,
        },
        'imagePath': imagePath,
        'sidecarPath': sidecarPath,
        // Manifest uses camelCase keys throughout (imagePath/photoId/…); the task's
        // snake_case (checksum_algorithm) is reconciled to that convention.
        if (checksumMd5 != null) 'checksum': checksumMd5,
        if (checksumMd5 != null) 'checksumAlgorithm': kChecksumAlgorithmMd5,
        'metadata': metadata?.toJson(),
      };
}

/// Assembles the deterministic `capture_manifest.json` map from already-aggregated
/// inputs. PURE: no IO, no recomputation of coverage/levels — it serializes and
/// joins. Same inputs → byte-identical output (stable level + photo ordering).
///
/// [levels] and [photos] may arrive in any order; the builder canonicalises both.
/// A photo whose [ManifestPhoto.levelId] matches no level is still emitted in the
/// top-level `photos` array (nothing is dropped) but contributes to no level's
/// counts — an orphan the backend can surface.
Map<String, dynamic> buildCaptureManifest({
  required ManifestSession session,
  required ManifestDevice device,
  required CaptureConfig config,
  required List<ManifestLevel> levels,
  required List<ManifestPhoto> photos,
  // The capture FLOW VARIANT id ('with_bottom' 3-ring / 'without_bottom'
  // 2-ring — CaptureFlowVariant.id). Additive: defaults to the legacy 3-ring
  // id so pre-variant callers emit an explicit, truthful value. Emitted as
  // `flowVariant` (this manifest's camelCase convention).
  String flowVariantId = 'with_bottom',
  // The capture SHAPE MODE id ('full' / 'meshy' — CaptureShapeMode.id). The
  // backend cross-checks this against the job's captureMode at finalize, so a
  // Meshy bundle must declare 'meshy'. Additive: defaults to 'full' so every
  // pre-Meshy caller emits an explicit, truthful value. Emitted as `captureMode`.
  String captureModeId = 'full',
}) {
  // Canonical ordering — deterministic regardless of input order.
  final orderedLevels = [...levels]
    ..sort((a, b) {
      final byOrder = levelOrderIndex(a.levelCode).compareTo(levelOrderIndex(b.levelCode));
      return byOrder != 0 ? byOrder : a.levelId.compareTo(b.levelId);
    });
  final orderedPhotos = [...photos]..sort(_comparePhotos);

  // Group photos by levelId once (preserves the sorted order within each group).
  final photosByLevel = <String, List<ManifestPhoto>>{};
  for (final p in orderedPhotos) {
    (photosByLevel[p.levelId] ??= <ManifestPhoto>[]).add(p);
  }

  // Per-level blocks + the backend-shaped summary levels (keyed by ring name).
  final levelBlocks = <Map<String, dynamic>>[];
  final summaryLevels = <String, dynamic>{};
  for (final lvl in orderedLevels) {
    final levelPhotos = photosByLevel[lvl.levelId] ?? const <ManifestPhoto>[];
    final photoCount = levelPhotos.length;
    final warningCount = levelPhotos.where((p) => p.verdict == 'warn').length;

    levelBlocks.add({
      'levelCode': lvl.levelCode,
      'levelId': lvl.levelId,
      'ringName': ringNameForLevelCode(lvl.levelCode),
      'pitchBand': (lvl.pitchBandMinDegrees == null && lvl.pitchBandMaxDegrees == null)
          ? null
          : {
              if (lvl.pitchBandMinDegrees != null) 'minDegrees': lvl.pitchBandMinDegrees,
              if (lvl.pitchBandMaxDegrees != null) 'maxDegrees': lvl.pitchBandMaxDegrees,
            },
      'segmentCount': lvl.segmentCount,
      'filledCount': lvl.filledCount,
      'coveragePct': lvl.coveragePct,
      'complete': lvl.complete,
      'photoCount': photoCount,
      'warningCount': warningCount,
      'photoIds': [for (final p in levelPhotos) p.photoId],
    });

    // Backend CaptureSummary.LevelSummary shape (photos/coverage/segmentCount/warnings).
    summaryLevels[ringNameForLevelCode(lvl.levelCode)] = {
      'photos': photoCount,
      'coverage': lvl.coveragePct,
      'segmentCount': lvl.segmentCount,
      'warnings': warningCount,
    };
  }

  final totalPhotos = orderedPhotos.length;
  final warningsCount = orderedPhotos.where((p) => p.verdict == 'warn').length;
  // overallComplete is the AND of the levels' progression-read verdicts — not a
  // recomputation of any gate. Empty levels → not complete (fail-safe).
  final overallComplete = orderedLevels.isNotEmpty && orderedLevels.every((l) => l.complete);

  return {
    'manifestVersion': kCaptureManifestVersion,
    'projectId': session.projectId,
    'jobId': session.jobId,
    'captureSessionId': session.captureSessionId,
    'flowVariant': flowVariantId,
    'captureMode': captureModeId,
    if (session.startedAtIso != null) 'startedAt': session.startedAtIso,
    if (session.completedAtIso != null) 'completedAt': session.completedAtIso,
    if (session.appVersion != null) 'appVersion': session.appVersion,
    'device': device.toJson(),
    'config': {
      'configVersion': config.version,
      if (session.objectSize != null) 'objectSize': session.objectSize,
      'thresholds': config.thresholds.toMap(),
      'completionThresholds': config.completionThresholds.toMap(),
      'uploadMinShots': config.uploadMinShots.toMap(),
      'segmentCounts': {
        for (final lvl in orderedLevels) lvl.levelCode: lvl.segmentCount,
      },
    },
    'levels': levelBlocks,
    'photos': [for (final p in orderedPhotos) p.toJson()],
    'summary': {
      'totalPhotos': totalPhotos,
      'warningsCount': warningsCount,
      'overallComplete': overallComplete,
      'levels': summaryLevels,
    },
  };
}

/// Deterministic photo order: level (A→B→C), then segment (nulls last), then
/// sensor timestamp, then photoId as the final tie-break.
int _comparePhotos(ManifestPhoto a, ManifestPhoto b) {
  final byLevel = levelOrderIndex(a.levelCode).compareTo(levelOrderIndex(b.levelCode));
  if (byLevel != 0) return byLevel;

  final as = a.segmentIndex, bs = b.segmentIndex;
  if (as != bs) {
    if (as == null) return 1; // nulls last
    if (bs == null) return -1;
    final bySeg = as.compareTo(bs);
    if (bySeg != 0) return bySeg;
  }

  final byTs = a.captureTimestampNs.compareTo(b.captureTimestampNs);
  if (byTs != 0) return byTs;

  return a.photoId.compareTo(b.photoId);
}
