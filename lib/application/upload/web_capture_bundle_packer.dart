// lib/application/upload/web_capture_bundle_packer.dart
//
// WEB ONLY. The browser's counterpart to CaptureBundlePacker.
//
// It produces the SAME artifact the native packer does — the same per-ring image
// layout (`images/{EYE|TOP|LOW}/<name>.jpg`), the same deterministic file names
// from the SAME `planBundleImages`, the same reconciled `capture_manifest.json`
// from the SAME `buildCaptureManifest`, and the same per-file streaming MD5 —
// so the server cannot tell which platform produced a job.
//
// It differs in exactly one way, deliberately: **it copies nothing**. The native
// packer stages copies under `staging/<jobId>/` and renames the directory into
// place, because a filesystem makes that atomic and cheap. A browser has neither
// property: duplicating 48 photos inside IndexedDB would double the storage a
// quota-limited origin has to hold, for no gain. Instead the bundle is an INDEX
// (web_bundle_registry.dart) pointing at the frames the capture already wrote,
// and "finalize" is the moment that index is complete and the manifest is built.
//
// Atomicity is preserved where it matters: the registry is populated into a
// local map and only published once every frame resolved and the manifest was
// generated. A failure or cancel publishes nothing, so the uploader can never
// see a half-assembled bundle.
//
// Integrity verification is likewise preserved in the form that is meaningful
// here: every planned image must resolve to a stored blob with a non-zero size,
// and the manifest's file set must equal the registry's — the "no missing, no
// orphans" check, minus the on-disk listing that has no analogue.
import 'dart:convert';
import 'dart:typed_data';

import '../../domain/entities/capture_config.dart';
import '../../domain/upload/capture_bundle.dart';
import '../../domain/upload/capture_manifest.dart';
import '../../domain/upload/file_checksum.dart';
import '../../platform/capture_ports/web_capture_store.dart';
import '../../utils/analytics.dart';
import '../../utils/platform_name.dart';
import '../capture/ledger/level_capture_ledger_registry.dart';
import '../capture/progression/level_progression.dart';
import 'bundle_cancel_token.dart';
import 'web_bundle_registry.dart';

/// The synthetic root every web bundle path hangs off. It is never a filesystem
/// path — only the registry and the manifest's relative paths give it meaning.
const String kWebBundleRoot = 'idb://bundles';

/// Packs a capture session into a virtual web bundle.
class WebCaptureBundlePacker {
  WebCaptureBundlePacker({FileChecksum? checksum})
      : _checksum = checksum ?? const StreamingMd5Checksum();

  final FileChecksum _checksum;

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

    // ── 1. Resolve inputs → deterministic plan (accepted frames only) ────────
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

    final bundlePath = '$kWebBundleRoot/${session.jobId}';
    final manifestPath = '$bundlePath/$kBundleManifestFileName';
    // Staged locally; published to the registry only on success.
    final staged = <String, WebBundleEntry>{};

    try {
      // ── 2. Resolve each planned frame + hash it (streamed, bounded memory) ──
      var done = 0;
      var totalBytes = 0;
      final photos = <ManifestPhoto>[];
      onProgress?.call(0, total);

      for (final img in plan) {
        _checkCancel(cancelToken, 'stage');
        final blob = await WebCaptureStore.instance.readBlob(img.sourcePath);
        if (blob == null || blob.size == 0) {
          throw BundlePackException(
            BundlePackFailureReason.missingSourceFile,
            stage: 'stage',
            detail: img.fileName,
          );
        }
        final size = blob.size;
        totalBytes += size;
        staged['$bundlePath/${img.relPath}'] = WebBundleEntry.frame(
          sourceHandle: img.sourcePath,
          size: size,
        );

        _checkCancel(cancelToken, 'manifest');
        final String checksum;
        try {
          checksum = await _checksum.md5Hex(img.sourcePath);
        } catch (_) {
          throw BundlePackException(
            BundlePackFailureReason.checksumError,
            stage: 'manifest',
            detail: img.fileName,
          );
        }

        photos.add(ManifestPhoto(
          photoId: _stemOf(_fileNameOf(img.sourcePath)),
          levelCode: img.levelCode,
          levelId: img.levelId,
          imagePath: img.relPath,
          verdict: img.warned ? 'warn' : 'accepted',
          captureTimestampNs: img.captureTimestampNs,
          segmentIndex: img.segmentIndex,
          blurScore: img.blurScore,
          meanLuminance: img.meanLuminance,
          yawDegrees: img.yawDegrees,
          pitchDegrees: img.pitchDegrees,
          // No sidecar exists on web: the native EXIF/JSON sidecar writer is
          // part of the native capture pipeline. The manifest field is
          // explicitly nullable for exactly this case ("kept, never
          // fabricated"), so the backend can see the gap rather than trust
          // invented values.
          metadata: null,
          checksumMd5: checksum,
        ));
        onProgress?.call(++done, total);
      }

      // ── 3. Generate the manifest from the SAME plan ──────────────────────────
      _checkCancel(cancelToken, 'manifest');
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
      final manifestBytes =
          Uint8List.fromList(utf8.encode(jsonEncode(manifest)));
      staged[manifestPath] = WebBundleEntry.inline(manifestBytes);

      // ── 4. Integrity verification (index ↔ manifest) ─────────────────────────
      _checkCancel(cancelToken, 'verify');
      _verifyIntegrity(bundlePath, staged, plan);

      // ── 5. Finalize (publish the index atomically) ───────────────────────────
      _checkCancel(cancelToken, 'finalize');
      WebBundleRegistry.instance.release(bundlePath);
      staged.forEach(WebBundleRegistry.instance.put);
      // The job now has a manifest, so it stops being an "incomplete job" and
      // stops guarding deletes — the same transition the native manifest marker
      // performs.
      await WebCaptureStore.instance
          .markJobComplete(session.projectId, session.jobId);

      _emitSucceeded(
        session,
        total,
        totalBytes,
        DateTime.now().difference(startedAt).inMilliseconds,
      );
      return CaptureBundle(
        path: bundlePath,
        manifestPath: manifestPath,
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
      // Nothing was published, so there is nothing partial to clean up beyond a
      // stale index from a previous attempt at the same job.
      WebBundleRegistry.instance.release(bundlePath);
      _emitFailed(session, ex);
      throw ex;
    }
  }

  void _checkCancel(BundleCancelToken? token, String stage) {
    if (token != null && token.isCancelled) {
      throw BundlePackException(
        BundlePackFailureReason.cancelled,
        stage: stage,
      );
    }
  }

  /// Every planned image is indexed with a non-zero size, and the index holds
  /// nothing beyond the plan plus the manifest — the "no missing, no orphans"
  /// guarantee the native packer gets from listing the staging directory.
  void _verifyIntegrity(
    String bundlePath,
    Map<String, WebBundleEntry> staged,
    List<PlannedBundleImage> plan,
  ) {
    final expected = {for (final p in plan) '$bundlePath/${p.relPath}'};
    for (final path in expected) {
      final entry = staged[path];
      if (entry == null || entry.byteLength <= 0) {
        throw BundlePackException(
          BundlePackFailureReason.integrityMismatch,
          stage: 'verify',
          detail: 'missing ${path.substring(bundlePath.length + 1)}',
        );
      }
    }
    final actual = staged.keys
        .where((p) => p != '$bundlePath/$kBundleManifestFileName')
        .toSet();
    if (actual.length != expected.length || !actual.every(expected.contains)) {
      throw BundlePackException(
        BundlePackFailureReason.integrityMismatch,
        stage: 'verify',
        detail: 'file set mismatch (${actual.length} indexed, '
            '${expected.length} listed)',
      );
    }
  }

  PitchBand? _bandFor(CaptureConfig config, String levelId) {
    for (final b in config.pitchBands) {
      if (b.id == levelId) return b;
    }
    return null;
  }

  static String _fileNameOf(String path) {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }

  static String _stemOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot <= 0 ? fileName : fileName.substring(0, dot);
  }

  // ── telemetry (identical event names/props to the native packer) ───────────

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
      'device_type': appPlatformName,
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
      'device_type': appPlatformName,
    });
  }

  void _emitFailed(ManifestSession session, BundlePackException ex) {
    Analytics.logEvent(AnalyticsEvents.bundlePackFailed, {
      'session_id': session.captureSessionId,
      'phase': 'upload',
      'reason': ex.reason.wireName,
      'stage': ex.stage,
      'device_type': appPlatformName,
    });
  }
}
