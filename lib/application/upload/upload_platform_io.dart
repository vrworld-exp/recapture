// lib/application/upload/upload_platform_io.dart
//
// NATIVE half of the upload platform seam. Every function here is exactly what
// upload_flow.dart did inline before the split: the real `CaptureBundlePacker`,
// `File.lengthSync` for the plan's file sizes, `FilePartByteSource` for the
// engine's lazy range reads, and `getApplicationDocumentsDirectory()` for the
// pack workspace. Android and iOS behaviour is unchanged.
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../domain/entities/capture_config.dart';
import '../../domain/upload/capture_bundle.dart';
import '../../domain/upload/capture_manifest.dart';
import '../capture/ledger/level_capture_ledger_registry.dart';
import '../capture/progression/level_progression.dart';
import 'capture_bundle_packer.dart';
import 'multipart_upload_api.dart';

Future<CaptureBundle> packCaptureBundle({
  required String workspaceRoot,
  required ManifestSession session,
  required ManifestDevice device,
  required CaptureConfig config,
  required LevelProgression progression,
  required LevelCaptureLedgerRegistry registry,
  required String flowVariantId,
  required String captureModeId,
  BundleCancelToken? cancelToken,
}) =>
    CaptureBundlePacker(workspaceRoot: workspaceRoot).pack(
      session: session,
      device: device,
      config: config,
      progression: progression,
      registry: registry,
      flowVariantId: flowVariantId,
      captureModeId: captureModeId,
      cancelToken: cancelToken,
    );

int bundleFileSize(String path) {
  final f = File(path);
  return f.existsSync() ? f.lengthSync() : 0;
}

/// Re-reads each part's range off disk, so a 48-photo bundle never sits in RAM.
PartByteSource createBundlePartByteSource() => const FilePartByteSource();

Future<String> resolveUploadWorkspaceRoot() async {
  final docs = await getApplicationDocumentsDirectory();
  return '${docs.path}/upload_workspace';
}

/// Nothing to release: the native bundle is a real directory the packer
/// finalized, and its lifetime is the filesystem's.
void releaseBundle(String bundlePath) {}
