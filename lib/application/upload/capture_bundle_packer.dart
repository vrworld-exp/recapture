// lib/application/upload/capture_bundle_packer.dart
//
// The BUNDLE PACKER: assembles a session's ACCEPTED images into the exact layout
// the upload engine consumes — per-ring image folders + the reconciled manifest —
// and hands back a finalized, verified bundle handle:
//
//   <bundle>/images/{EYE|TOP|LOW}/<name>.jpg
//   <bundle>/capture_manifest.json
//
// It READS accepted frames (never mutates capture/storage): the level progression
// (levels + coverage, READ) and the per-level ledgers (accepted records + exposure
// warnings). Copies are file-by-file and STREAMED (bounded memory, safe on low-end
// Android) and run OFF the main isolate via [BundleFileCopier] (default:
// [IsolateBundleFileCopier]). The manifest is generated from the SAME plan that
// writes the files (via the pure [buildCaptureManifest]) so files ↔ manifest can
// never diverge.
//
// PER-RING UPPER BOUND: [planBundleImages] collapses accepted records sharing a
// segment to the NEWEST one (retakes append a second ledger record for the same
// segment — see _handleRetakeCapture's replace TODO), so a segment-tracked ring
// stages at most `segments` images — the ceiling the backend's per-ring count
// range demands.
//
// ATOMICITY: everything is staged under `staging/<jobId>/`, integrity-verified
// (every manifest image exists on disk, and no unlisted .jpg exists), then the
// staging dir is RENAMED to the final location — the uploader only ever sees a
// complete, verified bundle. On ANY failure or cancellation, staging is deleted
// (guaranteed in `finally`) so no partial artifact is left behind.
//
// OUTPUT FORMAT = a directory (not an archive): the backend uploads files
// individually (UploadInfo.uploadMethod = S3_PRESIGNED_MULTIPART; expectedFilesCount
// = images + manifest), so no archive dependency is introduced.
//
// TELEMETRY: bundle_pack_started / _succeeded / _failed(reason) — pre-upload
// diagnostics the upload flow (and Screen 9F) categorize against.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../../domain/entities/capture_config.dart';
import '../../domain/entities/capture_photo_metadata.dart';
import '../../domain/upload/capture_bundle.dart';
import '../../domain/upload/capture_manifest.dart';
import '../../domain/upload/file_checksum.dart';
import '../../utils/analytics.dart';
import '../capture/ledger/level_capture_ledger_registry.dart';
import '../capture/progression/level_progression.dart';
import 'capture_manifest_assembler.dart'
    show
        CaptureSidecarReader,
        FileCaptureSidecarReader,
        fileNameOf,
        sidecarPathForFrame;

/// Cooperative cancellation for a pack. The packer checks [isCancelled] between
/// files and before each heavy stage, aborts promptly, and cleans up staging.
class BundleCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// Copies one file `src → dst`, returning the bytes written. Injectable so the
/// heavy work runs off the main isolate in production and in-process in tests. The
/// default [IsolateBundleFileCopier] streams in bounded chunks on a worker isolate.
abstract interface class BundleFileCopier {
  Future<int> copy(String src, String dst);
}

/// Streams `src → dst` in bounded chunks on a worker isolate ([Isolate.run]) so a
/// large image never sits fully in memory and the UI isolate is never blocked.
class IsolateBundleFileCopier implements BundleFileCopier {
  const IsolateBundleFileCopier();

  @override
  Future<int> copy(String src, String dst) =>
      Isolate.run(() => _isolateStreamCopy(src, dst));
}

/// Runs INSIDE the worker isolate: chunked synchronous copy, memory-bounded.
int _isolateStreamCopy(String src, String dst) {
  const chunkSize = 256 * 1024; // 256 KiB — bounded regardless of file size
  final reader = File(src).openSync(mode: FileMode.read);
  final writer = File(dst).openSync(mode: FileMode.write);
  try {
    var total = 0;
    while (true) {
      final bytes = reader.readSync(chunkSize);
      if (bytes.isEmpty) break;
      writer.writeFromSync(bytes);
      total += bytes.length;
    }
    return total;
  } finally {
    reader.closeSync();
    writer.closeSync();
  }
}

/// Packs a capture session into the upload bundle.
class CaptureBundlePacker {
  CaptureBundlePacker({
    required String workspaceRoot,
    BundleFileCopier? copier,
    CaptureSidecarReader? sidecarReader,
    FileChecksum? checksum,
  })  : _workspaceRoot = workspaceRoot,
        _copier = copier ?? const IsolateBundleFileCopier(),
        _sidecarReader = sidecarReader ?? const FileCaptureSidecarReader(),
        _checksum = checksum ?? const StreamingMd5Checksum();

  /// App-scoped base holding `staging/` and `bundles/` (same filesystem, so the
  /// finalize rename is atomic). Supplied by the caller (a real app-scoped dir on
  /// device; a temp dir in tests).
  final String _workspaceRoot;
  final BundleFileCopier _copier;
  final CaptureSidecarReader _sidecarReader;
  final FileChecksum _checksum;

  String get _deviceType =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  /// Packs [session]'s accepted frames into a finalized bundle. Reports progress
  /// (`done`, `total`) and honours [cancelToken]. Throws [BundlePackException] on
  /// failure/cancel (never releasing a partial bundle, never leaving staging).
  Future<CaptureBundle> pack({
    required ManifestSession session,
    required ManifestDevice device,
    required CaptureConfig config,
    required LevelProgression progression,
    required LevelCaptureLedgerRegistry registry,
    String flowVariantId = 'with_bottom',
    String captureModeId = 'full',
    void Function(int done, int total)? onProgress,
    BundleCancelToken? cancelToken,
  }) async {
    final startedAt = DateTime.now();

    // ── 1. Resolve inputs → deterministic plan (accepted frames only) ──────────
    final levelSources = <BundleLevelSources>[];
    for (final state in progression.levels) {
      final ledger = registry.ledgerFor(state.levelId);
      final warnedPaths = ledger.warned.map((w) => w.framePath).toSet();
      levelSources.add(BundleLevelSources(
        levelCode: state.levelCode,
        levelId: state.levelId,
        images: [
          for (final rec in ledger.accepted)
            BundleSourceImage(
              sourcePath: rec.framePath,
              captureTimestampNs: rec.sensorTimestampNs,
              // Quality + orientation ride ALL the way to the manifest: the
              // backend's automatic model generation skips any photo without a
              // finite blurScore, so dropping these here declines every capture.
              blurScore: rec.blurScore,
              meanLuminance: rec.meanLuminance,
              yawDegrees: rec.yawDegrees,
              pitchDegrees: rec.pitchDegrees,
              segmentIndex: rec.segmentIndex,
              warned: warnedPaths.contains(rec.framePath),
            ),
        ],
      ));
    }
    final plan = planBundleImages(levelSources);
    final total = plan.length;

    final perLevelCounts = <String, int>{};
    for (final state in progression.levels) {
      final ring = ringNameForLevelCode(state.levelCode);
      perLevelCounts[ring] =
          plan.where((p) => p.levelId == state.levelId).length;
    }

    _emitStarted(session, total, perLevelCounts);

    final staging = Directory('$_workspaceRoot/staging/${session.jobId}');
    final finalDir = Directory('$_workspaceRoot/bundles/${session.jobId}');

    try {
      // Fresh staging (re-pack determinism — no leftovers from a prior attempt).
      if (staging.existsSync()) staging.deleteSync(recursive: true);
      staging.createSync(recursive: true);
      // Create every ring folder up front (incl. levels with zero accepted frames).
      for (final state in progression.levels) {
        Directory(
          '${staging.path}/${bundleImageDir(ringNameForLevelCode(state.levelCode))}',
        ).createSync(recursive: true);
      }

      // ── 2. Stage images (off-isolate copy, file-by-file, memory-bounded) ─────
      var done = 0;
      var totalBytes = 0;
      onProgress?.call(0, total);
      for (final img in plan) {
        _checkCancel(cancelToken, 'stage');
        if (!File(img.sourcePath).existsSync()) {
          throw BundlePackException(
            BundlePackFailureReason.missingSourceFile,
            stage: 'stage',
            detail: img.fileName,
          );
        }
        final dst = '${staging.path}/${img.relPath}';
        try {
          totalBytes += await _copier.copy(img.sourcePath, dst);
        } on BundlePackException {
          rethrow;
        } catch (e) {
          throw BundlePackException(
            _classifyCopyError(e),
            stage: 'stage',
            detail: img.fileName,
          );
        }
        onProgress?.call(++done, total);
      }

      // ── 3. Generate the manifest from the SAME plan ──────────────────────────
      _checkCancel(cancelToken, 'manifest');
      final photos = <ManifestPhoto>[];
      for (final img in plan) {
        final meta = await _readMetadata(sidecarPathForFrame(img.sourcePath));
        // Per-file MD5 for backend integrity verification — streamed from disk
        // (bounded memory). A hash failure ABORTS the pack (never emit a manifest
        // with a missing/blank checksum). DISTINCT from the S3 part ETags.
        final String checksum;
        try {
          checksum = await _checksum.md5Hex(img.sourcePath);
        } catch (e) {
          throw BundlePackException(
            BundlePackFailureReason.checksumError,
            stage: 'manifest',
            detail: img.fileName,
          );
        }
        photos.add(ManifestPhoto(
          photoId: (meta != null && meta.frameId.isNotEmpty)
              ? meta.frameId
              : _stemOf(fileNameOf(img.sourcePath)),
          levelCode: img.levelCode,
          levelId: img.levelId,
          imagePath: img.relPath,
          // Self-contained bundle: the sidecar is embedded under `metadata`, no
          // separate sidecar file ships → no sidecarPath reference.
          verdict: img.warned ? 'warn' : 'accepted',
          captureTimestampNs: img.captureTimestampNs,
          segmentIndex: img.segmentIndex,
          blurScore: img.blurScore,
          meanLuminance: img.meanLuminance,
          yawDegrees: img.yawDegrees,
          pitchDegrees: img.pitchDegrees,
          metadata: meta,
          checksumMd5: checksum,
        ));
      }
      final levels = <ManifestLevel>[
        for (final state in progression.levels)
          () {
            final band = _bandFor(config, state.levelId);
            return ManifestLevel(
              levelCode: state.levelCode,
              levelId: state.levelId,
              segmentCount: state.segmentCount,
              filledCount: state.filledCount,
              coveragePct:
                  (state.completion.coverageRatio * 100).round().clamp(0, 100),
              complete: state.isComplete,
              pitchBandMinDegrees: band?.minDegrees,
              pitchBandMaxDegrees: band?.maxDegrees,
            );
          }(),
      ];
      final manifest = buildCaptureManifest(
        session: session,
        device: device,
        config: config,
        levels: levels,
        photos: photos,
        flowVariantId: flowVariantId,
        captureModeId: captureModeId,
      );
      File('${staging.path}/$kBundleManifestFileName')
          .writeAsStringSync(jsonEncode(manifest), flush: true);

      // ── 4. Integrity verification (files ↔ manifest) ─────────────────────────
      _checkCancel(cancelToken, 'verify');
      _verifyIntegrity(staging, plan);

      // ── 5. Finalize atomically (rename staging → final) ──────────────────────
      _checkCancel(cancelToken, 'finalize');
      if (finalDir.existsSync()) finalDir.deleteSync(recursive: true);
      finalDir.parent.createSync(recursive: true);
      staging.renameSync(finalDir.path);

      _emitSucceeded(
        session,
        total,
        totalBytes,
        DateTime.now().difference(startedAt).inMilliseconds,
      );
      return CaptureBundle(
        path: finalDir.path,
        manifestPath: '${finalDir.path}/$kBundleManifestFileName',
        totalImages: total,
        totalBytes: totalBytes,
        perLevelCounts: perLevelCounts,
      );
    } catch (e) {
      final ex = e is BundlePackException
          ? e
          : BundlePackException(
              BundlePackFailureReason.unknown,
              detail: e.toString(),
            );
      _emitFailed(session, ex);
      throw ex;
    } finally {
      // Success renamed staging away (existsSync == false → no-op); failure/cancel
      // leaves it → delete so no partial artifact remains.
      if (staging.existsSync()) {
        try {
          staging.deleteSync(recursive: true);
        } catch (_) {
          // Best-effort cleanup — never mask the original failure.
        }
      }
    }
  }

  void _checkCancel(BundleCancelToken? token, String stage) {
    if (token != null && token.isCancelled) {
      throw BundlePackException(BundlePackFailureReason.cancelled,
          stage: stage);
    }
  }

  /// Verifies every planned image exists in staging AND that no unlisted `.jpg`
  /// exists under `images/` (no orphans, no missing). Mismatch → integrity failure.
  void _verifyIntegrity(Directory staging, List<PlannedBundleImage> plan) {
    final expected = {for (final p in plan) p.relPath};

    for (final rel in expected) {
      if (!File('${staging.path}/$rel').existsSync()) {
        throw BundlePackException(
          BundlePackFailureReason.integrityMismatch,
          stage: 'verify',
          detail: 'missing $rel',
        );
      }
    }

    final actual = <String>{};
    final imagesRoot = Directory('${staging.path}/$kBundleImagesDir');
    if (imagesRoot.existsSync()) {
      for (final e in imagesRoot.listSync(recursive: true)) {
        if (e is File && e.path.toLowerCase().endsWith('.jpg')) {
          var rel = e.path.substring(staging.path.length).replaceAll(r'\', '/');
          if (rel.startsWith('/')) rel = rel.substring(1);
          actual.add(rel);
        }
      }
    }
    if (!setEquals(actual, expected)) {
      throw BundlePackException(
        BundlePackFailureReason.integrityMismatch,
        stage: 'verify',
        detail:
            'file set mismatch (${actual.length} on disk, ${expected.length} listed)',
      );
    }
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

  static BundlePackFailureReason _classifyCopyError(Object e) {
    final s = e.toString().toLowerCase();
    if (s.contains('space') ||
        s.contains('enospc') ||
        s.contains('disk full')) {
      return BundlePackFailureReason.insufficientStorage;
    }
    return BundlePackFailureReason.unknown;
  }

  // ── telemetry ──────────────────────────────────────────────────────────────

  void _emitStarted(
    ManifestSession session,
    int total,
    Map<String, int> perLevelCounts,
  ) {
    Analytics.logEvent(AnalyticsEvents.bundlePackStarted, {
      'session_id': session.captureSessionId,
      'phase': 'upload',
      'total_images': total,
      'eye_count': perLevelCounts['EYE'] ?? 0,
      'top_count': perLevelCounts['TOP'] ?? 0,
      'low_count': perLevelCounts['LOW'] ?? 0,
      'device_type': _deviceType,
    });
  }

  void _emitSucceeded(
    ManifestSession session,
    int total,
    int totalBytes,
    int durationMs,
  ) {
    Analytics.logEvent(AnalyticsEvents.bundlePackSucceeded, {
      'session_id': session.captureSessionId,
      'phase': 'upload',
      'total_images': total,
      'total_bytes': totalBytes,
      'duration_ms': durationMs,
      'device_type': _deviceType,
    });
  }

  void _emitFailed(ManifestSession session, BundlePackException ex) {
    Analytics.logEvent(AnalyticsEvents.bundlePackFailed, {
      'session_id': session.captureSessionId,
      'phase': 'upload',
      'reason': ex.reason.wireName,
      'stage': ex.stage,
      'device_type': _deviceType,
    });
  }
}
