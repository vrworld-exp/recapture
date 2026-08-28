// lib/dev/dev_probe/bundle_disk_store.dart
//
// Disk seam for the upload smoke test (dev flavors only — see
// dev_probe_service.dart for the module header). Writes one generated bundle
// to a dedicated on-device folder, mirroring the real post-capture layout:
//
//   <app-docs>/dev_probe_bundles/<runId>/images/{RING}/{ring}_0001.jpg …
//   <app-docs>/dev_probe_bundles/<runId>/capture_manifest.json
//
// so the pipeline uploads REAL files read back from disk (like the capture
// flow does), and reads/clears them for the "Clear test files" affordance.
// Everything lives under the single dev_probe_bundles root, so deleting it
// removes every test artifact. Not usable on Flutter web (dart:io) — the
// service falls back to its in-memory bundle when no store is provided.
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'dummy_bundle.dart';

/// One bundle written to disk: the run folder plus each file's absolute path,
/// still addressed by its S3 object key.
class WrittenBundle {
  const WrittenBundle({required this.directory, required this.pathsByKey});

  /// Absolute path of this run's folder (under the dev_probe_bundles root).
  final String directory;
  final Map<String, String> pathsByKey;

  String pathFor(String key) {
    final path = pathsByKey[key];
    if (path == null) {
      throw StateError('No file was written for key: $key');
    }
    return path;
  }
}

class BundleDiskStore {
  BundleDiskStore({Future<Directory> Function()? rootProvider})
      : _rootProvider = rootProvider ?? _defaultRoot;

  /// Overridable for tests (no path_provider plugin there).
  final Future<Directory> Function() _rootProvider;

  /// Tiebreaker so two writes within one millisecond get distinct run folders.
  static int _runSeq = 0;

  static Future<Directory> _defaultRoot() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}${Platform.pathSeparator}dev_probe_bundles');
  }

  /// Writes every bundle file under a fresh `<root>/<runId>/` folder. The
  /// on-disk relative path is the object key with [keyPrefix] stripped
  /// (`images/EYE/eye_0001.jpg`, `capture_manifest.json`), matching how a
  /// real capture stages its bundle before upload.
  Future<WrittenBundle> write(
    DummyBundle bundle, {
    required String keyPrefix,
  }) async {
    final root = await _rootProvider();
    final runId = 'run_${DateTime.now().millisecondsSinceEpoch}_${_runSeq++}';
    final runDir = Directory('${root.path}${Platform.pathSeparator}$runId');
    await runDir.create(recursive: true);

    final pathsByKey = <String, String>{};
    for (final file in bundle.files) {
      final relative = file.key.startsWith(keyPrefix)
          ? file.key.substring(keyPrefix.length)
          : file.key.split('/').last;
      final target = File(
        '${runDir.path}${Platform.pathSeparator}'
        '${relative.replaceAll('/', Platform.pathSeparator)}',
      );
      await target.parent.create(recursive: true);
      await target.writeAsBytes(file.bytes, flush: true);
      pathsByKey[file.key] = target.path;
    }
    return WrittenBundle(directory: runDir.path, pathsByKey: pathsByKey);
  }

  Future<Uint8List> read(String path) => File(path).readAsBytes();

  /// Total bytes currently held under the dev_probe_bundles root (all runs).
  /// 0 when the root doesn't exist yet.
  Future<int> totalSizeBytes() async {
    final root = await _rootProvider();
    if (!await root.exists()) return 0;
    var total = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  /// Deletes the whole dev_probe_bundles root — every run's files at once.
  Future<void> clear() async {
    final root = await _rootProvider();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  }
}
