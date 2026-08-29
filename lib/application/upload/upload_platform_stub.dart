// lib/application/upload/upload_platform_stub.dart
//
// Compile-time fallback for the upload platform seam. Only reachable on a target
// with neither `dart:io` nor `dart:js_interop`; packing fails loudly rather than
// producing an empty bundle that would upload as a valid-looking zero-photo job.
import '../../domain/entities/capture_config.dart';
import '../../domain/upload/capture_bundle.dart';
import '../../domain/upload/capture_manifest.dart';
import '../capture/ledger/level_capture_ledger_registry.dart';
import '../capture/progression/level_progression.dart';
import 'bundle_cancel_token.dart';
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
    throw const BundlePackException(
      BundlePackFailureReason.unknown,
      stage: 'stage',
      detail: 'bundle packing is not supported on this platform',
    );

int bundleFileSize(String path) => 0;

PartByteSource createBundlePartByteSource() => const _EmptyPartByteSource();

Future<String> resolveUploadWorkspaceRoot() async => 'unsupported://workspace';

void releaseBundle(String bundlePath) {}

class _EmptyPartByteSource implements PartByteSource {
  const _EmptyPartByteSource();

  @override
  int fileSize(String path) => 0;

  @override
  Stream<List<int>> read(String path, int offset, int length) =>
      const Stream<List<int>>.empty();
}
