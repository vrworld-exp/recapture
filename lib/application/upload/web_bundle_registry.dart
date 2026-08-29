// lib/application/upload/web_bundle_registry.dart
//
// WEB ONLY. The index a web-packed bundle hands to the upload engine.
//
// On native a bundle is a real directory: the engine asks the filesystem for a
// file's size and streams byte ranges out of it. A browser has neither, and —
// more importantly — must not COPY 48 photos into a second location just to
// have a directory-shaped thing to upload. Under a browser storage quota that
// doubling is the difference between a job that fits and one that does not.
//
// So the web "bundle" is virtual: this registry maps each bundle-relative path
// (`images/EYE/eye_01.jpg`, `capture_manifest.json`) onto either the `idb://`
// handle of the ALREADY-STORED capture frame or, for the manifest, its inline
// bytes. Sizes are captured at pack time, which is what lets
// `PartByteSource.fileSize` stay synchronous over an asynchronous store.
//
// Entries are dropped when the bundle is released, so a completed or abandoned
// upload leaves nothing behind but the frames themselves (which the capture
// storage port owns).
import 'dart:typed_data';

/// One addressable file inside a virtual web bundle.
class WebBundleEntry {
  const WebBundleEntry.frame({
    required this.sourceHandle,
    required this.size,
  }) : inlineBytes = null;

  const WebBundleEntry.inline(Uint8List bytes)
      : sourceHandle = null,
        inlineBytes = bytes,
        size = -1;

  /// The `idb://…` handle of the stored capture frame, for an image entry.
  final String? sourceHandle;

  /// The bytes themselves, for a small generated file (the manifest).
  final Uint8List? inlineBytes;

  final int size;

  int get byteLength => inlineBytes?.length ?? size;
}

/// Process-wide index of virtual web bundles, keyed by absolute bundle path.
class WebBundleRegistry {
  WebBundleRegistry._();

  static final WebBundleRegistry instance = WebBundleRegistry._();

  final Map<String, WebBundleEntry> _byPath = <String, WebBundleEntry>{};

  /// Registers one file at its absolute bundle path
  /// (`{bundlePath}/images/EYE/eye_01.jpg`).
  void put(String absolutePath, WebBundleEntry entry) =>
      _byPath[absolutePath] = entry;

  WebBundleEntry? entryFor(String absolutePath) => _byPath[absolutePath];

  /// Size in bytes, or 0 for an unknown path — the same answer
  /// `FilePartByteSource` gives for a missing file, so the engine's own length
  /// check (not a crash) decides the failure.
  int sizeOf(String absolutePath) => _byPath[absolutePath]?.byteLength ?? 0;

  /// Forgets every entry under [bundlePath] (upload finished, or abandoned).
  void release(String bundlePath) =>
      _byPath.removeWhere((path, _) => path.startsWith(bundlePath));

  /// Test seam: forget everything.
  void clear() => _byPath.clear();
}
