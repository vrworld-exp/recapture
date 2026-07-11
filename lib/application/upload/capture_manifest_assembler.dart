// lib/application/upload/capture_manifest_assembler.dart
//
// The IO layer wrapped AROUND the pure [buildCaptureManifest] assembler. It:
//   1. reads the app's already-computed state — the level progression (levels +
//      coverage, READ, never recomputed) and the per-level capture ledgers
//      (accepted photos + exposure warnings),
//   2. reads each accepted photo's native JSON sidecar off disk (via an injectable
//      [CaptureSidecarReader] seam) and parses it into a [CapturePhotoMetadata], so
//      the manifest's per-photo `metadata` stays byte-consistent with the sidecar,
//   3. composes those into the pure builder's [ManifestLevel]/[ManifestPhoto]
//      inputs, calls [buildCaptureManifest], and (optionally) encodes + writes the
//      `capture_manifest.json` via an injectable [CaptureManifestWriter] seam.
//
// The COMPOSITION + IO live here; the deterministic assembly stays pure in
// capture_manifest.dart. Both seams are interfaces so the whole flow is unit-
// testable with in-memory fakes (no real filesystem).
//
// STORAGE-PATH REFERENCES: the manifest references images/sidecars by their
// PORTABLE storage path (`recapture/{projectId}/{jobId}/images/{level}/<file>`) via
// [captureImageStoragePath] / [captureSidecarStoragePath] — the single source the
// upload MUST also use so the backend can pair manifest entries ↔ uploaded files.
// The device-absolute `framePath` is used only to LOCATE the sidecar for reading.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/entities/capture_config.dart';
import '../../domain/entities/capture_photo_metadata.dart';
import '../../domain/upload/capture_manifest.dart';
import '../capture/ledger/level_capture_ledger_registry.dart';
import '../capture/progression/level_progression.dart';

/// Reads a per-frame sidecar JSON off disk. Injectable so the assembler is testable
/// with an in-memory fake. Returns the decoded map, or null when the sidecar is
/// missing/unreadable/not a JSON object (→ the photo entry keeps `metadata: null`,
/// never fabricated).
abstract interface class CaptureSidecarReader {
  Future<Map<String, dynamic>?> read(String absoluteSidecarPath);
}

/// Writes the assembled `capture_manifest.json` for a job. Injectable so tests can
/// assert the payload without touching the filesystem.
abstract interface class CaptureManifestWriter {
  Future<void> write({
    required String projectId,
    required String jobId,
    required String json,
  });
}

/// Manifest file name — the rich upload INDEX (NOT the native `_manifest.json`
/// job marker used for incomplete-job detection).
const String kCaptureManifestFileName = 'capture_manifest.json';

/// The portable storage-path reference for a captured image the upload sends:
/// `recapture/{projectId}/{jobId}/images/{levelSegment}/{fileName}`. This is the
/// SINGLE source for entry↔file pairing — the upload must reference files the same
/// way. Not the device-absolute path.
String captureImageStoragePath(
  String projectId,
  String jobId,
  String levelSegment,
  String fileName,
) =>
    'recapture/$projectId/$jobId/images/$levelSegment/$fileName';

/// The portable storage-path reference for an image's paired sidecar (same base
/// name, `.json`).
String captureSidecarStoragePath(
  String projectId,
  String jobId,
  String levelSegment,
  String fileName,
) =>
    captureImageStoragePath(
        projectId, jobId, levelSegment, _toSidecarName(fileName));

/// The absolute on-disk sidecar path for an accepted frame — the JPEG path with its
/// extension swapped to `.json` (the pairing the storage/EXIF tasks derive:
/// `<frame>.json` alongside `<frame>.jpg`). Used only to LOCATE the sidecar to read.
String sidecarPathForFrame(String absoluteFramePath) {
  final slash = absoluteFramePath.lastIndexOf(RegExp(r'[/\\]'));
  final dir = slash < 0 ? '' : absoluteFramePath.substring(0, slash + 1);
  final name =
      slash < 0 ? absoluteFramePath : absoluteFramePath.substring(slash + 1);
  return '$dir${_toSidecarName(name)}';
}

/// The file's base name (last path segment), handling both `/` and `\` separators.
String fileNameOf(String path) {
  final slash = path.lastIndexOf(RegExp(r'[/\\]'));
  return slash < 0 ? path : path.substring(slash + 1);
}

String _toSidecarName(String fileName) {
  final dot = fileName.lastIndexOf('.');
  return dot <= 0 ? '$fileName.json' : '${fileName.substring(0, dot)}.json';
}

/// The storage-path level segment for a level. Kept in ONE place (the upload must
/// agree) — the display code ("A"/"B"/"C").
String levelStorageSegment(LevelProgressState level) => level.levelCode;

/// Composes app state + native sidecars into the `capture_manifest.json` document.
class CaptureManifestAssembler {
  const CaptureManifestAssembler({
    required CaptureSidecarReader sidecarReader,
    CaptureManifestWriter? writer,
  })  : _sidecarReader = sidecarReader,
        _writer = writer;

  final CaptureSidecarReader _sidecarReader;
  final CaptureManifestWriter? _writer;

  /// Reads sidecars + composes the deterministic manifest map. Coverage/levels come
  /// from [progression] (READ); per-photo records + warnings from [registry].
  Future<Map<String, dynamic>> assemble({
    required ManifestSession session,
    required ManifestDevice device,
    required CaptureConfig config,
    required LevelProgression progression,
    required LevelCaptureLedgerRegistry registry,
    String flowVariantId = 'with_bottom',
  }) async {
    final levels = <ManifestLevel>[];
    final photos = <ManifestPhoto>[];

    for (final state in progression.levels) {
      final band = _bandFor(config, state.levelId);
      final completion = state.completion;
      levels.add(ManifestLevel(
        levelCode: state.levelCode,
        levelId: state.levelId,
        segmentCount: state.segmentCount,
        filledCount: state.filledCount,
        coveragePct: (completion.coverageRatio * 100).round().clamp(0, 100),
        complete: state.isComplete,
        pitchBandMinDegrees: band?.minDegrees,
        pitchBandMaxDegrees: band?.maxDegrees,
      ));

      final ledger = registry.ledgerFor(state.levelId);
      final warnedPaths = ledger.warned.map((w) => w.framePath).toSet();
      final segment = levelStorageSegment(state);

      for (final rec in ledger.accepted) {
        final fileName = fileNameOf(rec.framePath);
        final metadata =
            await _readMetadata(sidecarPathForFrame(rec.framePath));
        // photoId prefers the sidecar's canonical frameId; falls back to the file
        // base name so an entry is never id-less when the sidecar is missing.
        final photoId = (metadata != null && metadata.frameId.isNotEmpty)
            ? metadata.frameId
            : _stemOf(fileName);

        photos.add(ManifestPhoto(
          photoId: photoId,
          levelCode: state.levelCode,
          levelId: state.levelId,
          imagePath: captureImageStoragePath(
              session.projectId, session.jobId, segment, fileName),
          sidecarPath: captureSidecarStoragePath(
              session.projectId, session.jobId, segment, fileName),
          verdict: warnedPaths.contains(rec.framePath) ? 'warn' : 'accepted',
          captureTimestampNs: rec.sensorTimestampNs,
          segmentIndex: rec.segmentIndex,
          blurScore: rec.blurScore,
          meanLuminance: rec.meanLuminance,
          yawDegrees: rec.yawDegrees,
          pitchDegrees: rec.pitchDegrees,
          metadata: metadata,
        ));
      }
    }

    return buildCaptureManifest(
      session: session,
      device: device,
      config: config,
      levels: levels,
      photos: photos,
      flowVariantId: flowVariantId,
    );
  }

  /// Assembles, encodes, and writes `capture_manifest.json`. Requires a
  /// [CaptureManifestWriter] (else a [StateError]). Returns the encoded JSON.
  Future<String> assembleAndWrite({
    required ManifestSession session,
    required ManifestDevice device,
    required CaptureConfig config,
    required LevelProgression progression,
    required LevelCaptureLedgerRegistry registry,
    String flowVariantId = 'with_bottom',
  }) async {
    final writer = _writer;
    if (writer == null) {
      throw StateError('CaptureManifestAssembler has no writer configured');
    }
    final manifest = await assemble(
      session: session,
      device: device,
      config: config,
      progression: progression,
      registry: registry,
      flowVariantId: flowVariantId,
    );
    final json = jsonEncode(manifest);
    await writer.write(
      projectId: session.projectId,
      jobId: session.jobId,
      json: json,
    );
    return json;
  }

  Future<CapturePhotoMetadata?> _readMetadata(String sidecarPath) async {
    final map = await _sidecarReader.read(sidecarPath);
    return map == null ? null : CapturePhotoMetadata.fromJson(map);
  }

  PitchBand? _bandFor(CaptureConfig config, String levelId) {
    for (final b in config.pitchBands) {
      if (b.id == levelId) return b;
    }
    return null;
  }

  static String _stemOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot <= 0 ? fileName : fileName.substring(0, dot);
  }
}

/// Default [CaptureSidecarReader] backed by `dart:io`. Reads + JSON-decodes the
/// sidecar; any IO/parse failure or non-object payload → null (the entry keeps
/// `metadata: null`; nothing is fabricated).
class FileCaptureSidecarReader implements CaptureSidecarReader {
  const FileCaptureSidecarReader();

  @override
  Future<Map<String, dynamic>?> read(String absoluteSidecarPath) async {
    try {
      final file = File(absoluteSidecarPath);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }
}
