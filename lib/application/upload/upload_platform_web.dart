// lib/application/upload/upload_platform_web.dart
//
// WEB half of the upload platform seam.
//
// The pack produces a virtual bundle (web_capture_bundle_packer.dart) indexed by
// web_bundle_registry.dart; sizes come from that index, and part bytes are
// sliced lazily out of the IndexedDB blob the capture already wrote. Nothing
// here ever holds a whole image, let alone a whole bundle — the same memory
// contract `FilePartByteSource` gives native, achieved with `Blob.slice()`
// instead of `File.openRead()`.
//
// There is no workspace directory: nothing is staged, so the "root" is a
// synthetic namespace the registry keys off.
import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import '../../domain/entities/capture_config.dart';
import '../../domain/upload/capture_bundle.dart';
import '../../domain/upload/capture_manifest.dart';
import '../../platform/capture_ports/web_capture_store.dart';
import '../capture/ledger/level_capture_ledger_registry.dart';
import '../capture/progression/level_progression.dart';
import 'bundle_cancel_token.dart';
import 'multipart_upload_api.dart';
import 'web_bundle_registry.dart';
import 'web_capture_bundle_packer.dart';

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
    WebCaptureBundlePacker().pack(
      session: session,
      device: device,
      config: config,
      progression: progression,
      registry: registry,
      flowVariantId: flowVariantId,
      captureModeId: captureModeId,
      cancelToken: cancelToken,
    );

int bundleFileSize(String path) => WebBundleRegistry.instance.sizeOf(path);

PartByteSource createBundlePartByteSource() => const IdbPartByteSource();

/// Synthetic: the web packer stages nothing, so there is no directory to make.
Future<String> resolveUploadWorkspaceRoot() async => kWebBundleRoot;

void releaseBundle(String bundlePath) =>
    WebBundleRegistry.instance.release(bundlePath);

/// Streams a byte range of a virtual bundle file.
///
/// An image entry slices the stored `Blob` — so a 4 MB photo is read one part at
/// a time, never whole — while the manifest, which is small and already in
/// memory, is served directly. A path the registry does not know yields an empty
/// stream, matching `FilePartByteSource`'s behaviour on a missing file: the
/// engine reports a short part rather than crashing.
class IdbPartByteSource implements PartByteSource {
  const IdbPartByteSource();

  @override
  int fileSize(String path) => WebBundleRegistry.instance.sizeOf(path);

  @override
  Stream<List<int>> read(String path, int offset, int length) {
    final entry = WebBundleRegistry.instance.entryFor(path);
    if (entry == null) return const Stream<List<int>>.empty();

    final inline = entry.inlineBytes;
    if (inline != null) {
      final start = offset.clamp(0, inline.length);
      final end = (offset + length).clamp(start, inline.length);
      return Stream<List<int>>.value(Uint8List.sublistView(inline, start, end));
    }

    final handle = entry.sourceHandle;
    if (handle == null) return const Stream<List<int>>.empty();
    return _readBlobRange(handle, offset, length);
  }

  static Stream<List<int>> _readBlobRange(
    String handle,
    int offset,
    int length,
  ) async* {
    final blob = await WebCaptureStore.instance.readBlob(handle);
    if (blob == null) return;
    final start = offset < 0 ? 0 : (offset > blob.size ? blob.size : offset);
    final rawEnd = offset + length;
    final end =
        rawEnd < start ? start : (rawEnd > blob.size ? blob.size : rawEnd);
    if (end <= start) return;
    final buffer = await blob.slice(start, end).arrayBuffer().toDart;
    yield buffer.toDart.asUint8List();
  }
}
