// lib/application/upload/pending_capture_saver.dart
//
// Turns the capture that just FINISHED (the one on the Capture Summary) into a
// durable [PendingCapture]: packs it into its upload bundle, writes the record,
// and frees the single-slot [ActiveSession] so the user can start the next
// capture.
//
// WHY PACK AT SAVE TIME. The upload flow packs from the per-level photo ledger,
// and that ledger lives in memory only — after an app kill or a phone restart
// there is nothing left to pack from. Packing here, while the capture is still
// in memory, produces a self-contained folder the upload can use days later:
//
//   <app documents>/upload_workspace/bundles/<localId>/images/{EYE|TOP|LOW}/…
//                                                      /capture_manifest.json
//
// WHERE THE FILES LIVE (Step A2). App DOCUMENTS — `getApplicationDocumentsDirectory`
// (Android: the app's private files dir; iOS: Documents). Never a cache or temp
// directory, which the OS empties under storage pressure. The bundle is a COPY,
// so it does not depend on where the native camera wrote the raw frames
// (Android `getExternalFilesDir/captures/<sessionId>`, iOS
// `Application Support/captures/<sessionId>` — both app-scoped and not purged
// by the OS either). The record stores the bundle path RELATIVE to documents:
// the iOS container path changes across app updates.
//
// ONE SLOT FREED (Step A3). [ActiveSession] keeps its meaning — the pointer to a
// capture still being shot — and its key and JSON are unchanged. Once the
// record is saved the slot is cleared, but only if it still points at THIS
// capture's project.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/local/storage_providers.dart';
import '../../domain/upload/capture_bundle.dart';
import '../../domain/upload/capture_manifest.dart';
import '../../domain/upload/pending_capture.dart';
import 'capture_bundle_packer.dart';
import 'offline_capture_capability.dart';
import 'pending_captures_notifier.dart';
import 'upload_flow.dart';

/// Why a capture could not be saved for later. The Summary screen maps each to
/// copy; [BundlePackException]s from the pack itself pass through unchanged.
enum PendingCaptureSaveFailure {
  /// This build does not support offline capture (web).
  unsupported,

  /// Nobody is signed in — a capture is never stored without an owner.
  notSignedIn,

  /// The capture is not attached to any project (neither a server id nor an
  /// offline `pending_…` id), so there is nothing to upload it into.
  noProject,
}

class PendingCaptureSaveException implements Exception {
  const PendingCaptureSaveException(this.reason);

  final PendingCaptureSaveFailure reason;

  @override
  String toString() => 'PendingCaptureSaveException(${reason.name})';
}

/// Packs a bundle for [context] under [workspaceRoot] (production:
/// [CaptureBundlePacker]). Injectable so the saver is testable without the
/// isolate copier or real frames.
typedef PendingBundlePackFn = Future<CaptureBundle> Function({
  required UploadFlowContext context,
  required ManifestSession session,
  required ManifestDevice device,
  void Function(int done, int total)? onProgress,
  BundleCancelToken? cancelToken,
});

class PendingCaptureSaver {
  PendingCaptureSaver(
    this._ref, {
    Future<UploadFlowContext> Function()? resolveContext,
    PendingBundlePackFn? pack,
    String Function()? uuid,
    DateTime Function()? now,
  })  : _resolveContextOverride = resolveContext,
        _packOverride = pack,
        _uuid = uuid ?? randomUuidV4,
        _now = now ?? DateTime.now;

  final Ref _ref;
  final Future<UploadFlowContext> Function()? _resolveContextOverride;
  final PendingBundlePackFn? _packOverride;
  final String Function() _uuid;
  final DateTime Function() _now;

  /// Saves the finished capture as a [PendingCapture] in [initialState]
  /// (`savedLocal` for "Save — upload when online"; `uploading` when the
  /// Summary's online Upload writes the record before the flow starts).
  ///
  /// Throws [PendingCaptureSaveException] or the packer's
  /// [BundlePackException] (e.g. insufficient storage). Nothing is persisted
  /// on failure — the capture stays where it was, still uploadable or saveable.
  Future<PendingCapture> saveFinishedCapture({
    PendingCaptureState initialState = PendingCaptureState.savedLocal,
    void Function(int done, int total)? onProgress,
    BundleCancelToken? cancelToken,
  }) async {
    _checkCanSave();
    final ctx = await (_resolveContextOverride?.call() ??
        resolveLiveUploadContext(_ref));
    final (record, _) = await packAndRecord(
      context: ctx,
      localId: _uuid(),
      initialState: initialState,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
    return record;
  }

  /// Throws when this build/session cannot save a capture for later.
  void _checkCanSave() {
    if (!_ref.read(offlineCaptureCapabilityProvider)) {
      throw const PendingCaptureSaveException(
          PendingCaptureSaveFailure.unsupported);
    }
    if (_ref.read(currentUserIdProvider) == null) {
      throw const PendingCaptureSaveException(
          PendingCaptureSaveFailure.notSignedIn);
    }
  }

  /// The pack + record half of [saveFinishedCapture], for a caller that has
  /// already resolved [context] and chosen [localId] — the online Summary
  /// Upload runs this as its flow's pack step, so the record exists BEFORE the
  /// transfer starts and an app kill mid-upload still leaves something to
  /// resume. Returns the record and the packed bundle.
  Future<(PendingCapture, CaptureBundle)> packAndRecord({
    required UploadFlowContext context,
    required String localId,
    PendingCaptureState initialState = PendingCaptureState.savedLocal,
    void Function(int done, int total)? onProgress,
    BundleCancelToken? cancelToken,
  }) async {
    _checkCanSave();
    final owner = _ref.read(currentUserIdProvider)!;
    final ctx = context;
    if (ctx.localProjectId.isEmpty) {
      throw const PendingCaptureSaveException(
          PendingCaptureSaveFailure.noProject);
    }

    final capturedAt = _now().toUtc();
    final bundle = await (_packOverride ?? _packWithPacker)(
      context: ctx,
      session: ManifestSession(
        projectId: ctx.localProjectId,
        // The bundle folder is named by the job id → `bundles/<localId>`,
        // which is exactly [pendingBundleRelPathFor].
        jobId: localId,
        captureSessionId: ctx.captureSessionId,
        completedAtIso: capturedAt.toIso8601String(),
      ),
      device: ManifestDevice(
        platform:
            defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
      ),
      onProgress: onProgress,
      cancelToken: cancelToken,
    );

    final record = PendingCapture(
      localId: localId,
      projectId: ctx.localProjectId,
      ownerUserId: owner,
      projectName: ctx.projectName,
      objectSize: ctx.objectSize,
      captureMode: ctx.mode.id,
      flowVariant: ctx.variant.id,
      frameCount: bundle.totalImages,
      byteCount: bundle.totalBytes + _sizeOf(bundle.manifestPath),
      state: initialState,
      capturedAt: capturedAt,
      updatedAt: capturedAt,
      bundleRelPath: pendingBundleRelPathFor(localId),
      perLevelCounts: Map.unmodifiable(bundle.perLevelCounts),
    );

    try {
      await _ref.read(pendingCapturesProvider.notifier).upsert(record);
    } catch (_) {
      // The record is what makes the bundle findable. Without it the folder is
      // an orphan — remove it rather than leak a capture-sized directory.
      _deleteQuietly(bundle.path);
      rethrow;
    }

    await _releaseActiveSessionSlot(ctx.localProjectId);
    return (record, bundle);
  }

  Future<CaptureBundle> _packWithPacker({
    required UploadFlowContext context,
    required ManifestSession session,
    required ManifestDevice device,
    void Function(int done, int total)? onProgress,
    BundleCancelToken? cancelToken,
  }) =>
      CaptureBundlePacker(workspaceRoot: context.workspaceRoot).pack(
        session: session,
        device: device,
        config: context.config,
        progression: context.progression,
        registry: context.registry,
        flowVariantId: context.variant.id,
        captureModeId: context.mode.id,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );

  /// Step A3: the finished capture no longer needs the single draft slot.
  /// Cleared only when the slot still points at this capture's project, so a
  /// different in-progress capture is never dropped. Best-effort: a failure
  /// here leaves a stale draft pointer, never a lost capture.
  Future<void> _releaseActiveSessionSlot(String projectId) async {
    try {
      final box = _ref.read(activeSessionBoxProvider);
      final slot = await box.read();
      if (slot == null || slot.projectId == projectId) await box.clear();
    } catch (_) {/* best-effort */}
  }

  static int _sizeOf(String path) {
    try {
      final f = File(path);
      return f.existsSync() ? f.lengthSync() : 0;
    } catch (_) {
      return 0;
    }
  }

  static void _deleteQuietly(String dir) {
    try {
      final d = Directory(dir);
      if (d.existsSync()) d.deleteSync(recursive: true);
    } catch (_) {/* best-effort */}
  }
}

/// Resolves a pending capture's bundle folder to an absolute path for THIS
/// install (the documents directory is looked up fresh, never persisted).
Future<String> resolvePendingBundleDir(PendingCapture capture) async {
  final docs = await getApplicationDocumentsDirectory();
  return '${docs.path}/${capture.bundleRelPath}';
}

/// The saver the Summary screen calls. Overridden in tests.
final pendingCaptureSaverProvider =
    Provider<PendingCaptureSaver>(PendingCaptureSaver.new);
