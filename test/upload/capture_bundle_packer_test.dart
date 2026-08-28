// test/upload/capture_bundle_packer_test.dart
//
// Integration tests for the packer against a real temp filesystem, with an
// in-process copier + fake sidecar reader (no isolate overhead, deterministic).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/ledger/captured_photo_record.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry.dart';
import 'package:recapture/application/capture/ledger/warned_photo_record.dart';
import 'package:recapture/application/capture/progression/level_progression.dart';
import 'package:recapture/application/upload/capture_bundle_packer.dart';
import 'package:recapture/application/upload/capture_manifest_assembler.dart'
    show CaptureSidecarReader, sidecarPathForFrame;
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/upload/capture_bundle.dart';
import 'package:recapture/domain/upload/capture_manifest.dart';
import 'package:recapture/utils/analytics.dart';

/// In-process copier that really copies bytes (so verification passes).
class _RealCopier implements BundleFileCopier {
  final List<String> copied = [];
  @override
  Future<int> copy(String src, String dst) async {
    final bytes = await File(src).readAsBytes();
    await File(dst).parent.create(recursive: true);
    await File(dst).writeAsBytes(bytes);
    copied.add(dst);
    return bytes.length;
  }
}

/// Copier that skips a chosen source (simulates a lost staged file → integrity).
class _DroppingCopier implements BundleFileCopier {
  _DroppingCopier(this.dropSourceEndingWith);
  final String dropSourceEndingWith;
  @override
  Future<int> copy(String src, String dst) async {
    if (src.endsWith(dropSourceEndingWith)) return 0; // pretend copied, write nothing
    final bytes = await File(src).readAsBytes();
    await File(dst).parent.create(recursive: true);
    await File(dst).writeAsBytes(bytes);
    return bytes.length;
  }
}

/// Copier that throws a disk-full error.
class _NoSpaceCopier implements BundleFileCopier {
  @override
  Future<int> copy(String src, String dst) async =>
      throw const FileSystemException('write failed: No space left on device');
}

class _MapSidecarReader implements CaptureSidecarReader {
  _MapSidecarReader(this.byPath);
  final Map<String, Map<String, dynamic>> byPath;
  @override
  Future<Map<String, dynamic>?> read(String p) async => byPath[p];
}

Map<String, dynamic> _sidecar(String frameId) => {
      'sessionId': 'sess1',
      'frameId': frameId,
      'frameIndex': 0,
      'captureTimestampNs': 1000,
      'wallClockIso': '2026-07-02T10:00:01.000Z',
      'device': {'manufacturer': 'S', 'model': 'M', 'osVersion': '13'},
      'resolution': {
        'width': 4032,
        'height': 3024,
        'aspectRatio': '4:3',
        'jpegQuality': 95,
        'fellBack': false,
      },
      'intrinsics': {'focalLengthMm': 4.7},
      'capture': {'afLocked': true, 'aeLocked': true, 'awbLocked': true},
      'orientationApplied': 'normal',
      'pose': null,
    };

const _session = ManifestSession(
  projectId: 'proj1',
  jobId: 'job1',
  captureSessionId: 'sess1',
);
const _device = ManifestDevice(platform: 'android');

late Directory _tmp;
late Directory _srcRoot;

/// Writes a source JPEG + returns its absolute path.
String _writeSource(String rel, List<int> bytes) {
  final f = File('${_srcRoot.path}/$rel');
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(bytes);
  return f.path;
}

/// A registry + progression for A/B/C with the given per-level source paths.
({LevelCaptureLedgerRegistry registry, LevelProgression progression}) _fixture({
  required List<String> eye,
  required List<String> top,
  required List<String> low,
  Set<String> warned = const {},
  Map<String, ({double blur, double luma, double yaw, double pitch})> quality =
      const {},
}) {
  final registry = LevelCaptureLedgerRegistry();
  void add(String levelId, List<String> paths) {
    for (var i = 0; i < paths.length; i++) {
      final q = quality[paths[i]];
      registry.ledgerFor(levelId).recordAccepted(CapturedPhotoRecord(
            segmentIndex: i,
            framePath: paths[i],
            blurScore: q?.blur ?? 120,
            meanLuminance: q?.luma ?? 128,
            yawDegrees: q?.yaw ?? 0,
            pitchDegrees: q?.pitch ?? 0,
            sensorTimestampNs: 1000 + i,
          ));
      if (warned.contains(paths[i])) {
        registry.ledgerFor(levelId).recordWarned(WarnedPhotoRecord(
              framePath: paths[i],
              isUnderexposed: true,
              isOverexposed: false,
              meanLuminance: 40,
              sensorTimestampNs: 1000 + i,
            ));
      }
    }
  }

  add('mid', eye);
  add('high', top);
  add('low', low);

  final progression = LevelProgression.of([
    LevelProgressState(
        levelId: 'mid', levelCode: 'A', segmentCount: 10, filledCount: eye.length, acceptedCount: eye.length),
    LevelProgressState(
        levelId: 'high', levelCode: 'B', segmentCount: 8, filledCount: top.length, acceptedCount: top.length),
    LevelProgressState(
        levelId: 'low', levelCode: 'C', segmentCount: 12, filledCount: low.length, acceptedCount: low.length),
  ]);
  return (registry: registry, progression: progression);
}

void main() {
  setUp(() {
    _tmp = Directory.systemTemp.createTempSync('bundle_ws_');
    _srcRoot = Directory.systemTemp.createTempSync('bundle_src_');
  });
  tearDown(() {
    Analytics.testSink = null;
    if (_tmp.existsSync()) _tmp.deleteSync(recursive: true);
    if (_srcRoot.existsSync()) _srcRoot.deleteSync(recursive: true);
  });

  test('happy path: correct layout, level mapping, manifest, sources untouched', () async {
    final a = _writeSource('A/a.jpg', [1, 2, 3]);
    final b = _writeSource('B/b.jpg', [4, 5, 6, 7]);
    final c = _writeSource('C/c.jpg', [8, 9]);
    final fx = _fixture(eye: [a], top: [b], low: [c]);

    final reader = _MapSidecarReader({
      sidecarPathForFrame(a): _sidecar('fa'),
      sidecarPathForFrame(b): _sidecar('fb'),
      sidecarPathForFrame(c): _sidecar('fc'),
    });
    final copier = _RealCopier();
    final packer = CaptureBundlePacker(
      workspaceRoot: _tmp.path,
      copier: copier,
      sidecarReader: reader,
    );

    final progress = <int>[];
    final bundle = await packer.pack(
      session: _session,
      device: _device,
      config: CaptureConfig.bundledDefault,
      progression: fx.progression,
      registry: fx.registry,
      onProgress: (done, total) => progress.add(done),
    );

    // Layout + level mapping (B→TOP, C→LOW, A→EYE).
    expect(File('${bundle.path}/images/EYE/eye_0001.jpg').existsSync(), isTrue);
    expect(File('${bundle.path}/images/TOP/top_0001.jpg').existsSync(), isTrue);
    expect(File('${bundle.path}/images/LOW/low_0001.jpg').existsSync(), isTrue);
    expect(File(bundle.manifestPath).existsSync(), isTrue);
    expect(bundle.totalImages, 3);
    expect(bundle.totalBytes, 3 + 4 + 2);
    expect(bundle.perLevelCounts, {'EYE': 1, 'TOP': 1, 'LOW': 1});
    expect(progress.last, 3);

    // Manifest enumerates exactly the packed images, bundle-relative paths.
    final manifest =
        jsonDecode(File(bundle.manifestPath).readAsStringSync()) as Map<String, dynamic>;
    final photos = manifest['photos'] as List;
    expect(photos.length, 3);
    final paths = photos.map((p) => (p as Map)['imagePath']).toSet();
    expect(paths, {
      'images/EYE/eye_0001.jpg',
      'images/TOP/top_0001.jpg',
      'images/LOW/low_0001.jpg',
    });
    // photoId came from the sidecar; native field merged.
    final eyePhoto = photos.firstWhere((p) => (p as Map)['ringName'] == 'EYE') as Map;
    expect(eyePhoto['photoId'], 'fa');
    expect((eyePhoto['metadata'] as Map)['wallClockIso'], '2026-07-02T10:00:01.000Z');

    // Sources untouched.
    expect(File(a).readAsBytesSync(), [1, 2, 3]);
    expect(File(b).existsSync(), isTrue);

    // No leftover staging.
    expect(Directory('${_tmp.path}/staging/job1').existsSync(), isFalse);
  });

  test('manifest JSON carries per-photo quality + orientation (never null)', () async {
    // THE regression guard for the bug that shipped: the packer dropped the
    // ledger's blurScore/yaw, so every uploaded manifest wrote
    // `quality: {blurScore: null}` and the backend's automatic model generation
    // declined 100% of real captures with NO_USABLE_PHOTOS. Asserted against the
    // EMITTED JSON — the intermediate Dart structs would not have caught it.
    final a1 = _writeSource('A/a1.jpg', [1]);
    final a2 = _writeSource('A/a2.jpg', [2]);
    final b1 = _writeSource('B/b1.jpg', [3]);
    final fx = _fixture(
      eye: [a1, a2],
      top: [b1],
      low: [],
      quality: {
        a1: (blur: 132.5, luma: 118.25, yaw: 12.5, pitch: 88.5),
        a2: (blur: 61.75, luma: 90.5, yaw: 190.25, pitch: 91.5),
        b1: (blur: 45.5, luma: 77.25, yaw: 275.75, pitch: 130.5),
      },
    );
    final packer = CaptureBundlePacker(
      workspaceRoot: _tmp.path,
      copier: _RealCopier(),
      sidecarReader: _MapSidecarReader({}),
    );
    final bundle = await packer.pack(
      session: _session,
      device: _device,
      config: CaptureConfig.bundledDefault,
      progression: fx.progression,
      registry: fx.registry,
    );

    final manifest =
        jsonDecode(File(bundle.manifestPath).readAsStringSync()) as Map<String, dynamic>;
    final photos = (manifest['photos'] as List).cast<Map<String, dynamic>>();
    expect(photos.length, 3);

    // The regression guard: NOT ONE photo may ship without a blur score.
    for (final photo in photos) {
      expect((photo['quality'] as Map)['blurScore'], isNotNull,
          reason: 'photo ${photo['imagePath']} has a null blurScore');
      expect((photo['orientation'] as Map)['yawDegrees'], isNotNull);
    }

    Map<String, dynamic> byPath(String p) =>
        photos.firstWhere((photo) => photo['imagePath'] == p);

    final eye1 = byPath('images/EYE/eye_0001.jpg');
    expect((eye1['quality'] as Map)['blurScore'], 132.5);
    expect((eye1['quality'] as Map)['meanLuminance'], 118.25);
    expect((eye1['orientation'] as Map)['yawDegrees'], 12.5);
    expect((eye1['orientation'] as Map)['pitchDegrees'], 88.5);

    final eye2 = byPath('images/EYE/eye_0002.jpg');
    expect((eye2['quality'] as Map)['blurScore'], 61.75);
    expect((eye2['orientation'] as Map)['yawDegrees'], 190.25);

    final top1 = byPath('images/TOP/top_0001.jpg');
    expect((top1['quality'] as Map)['blurScore'], 45.5);
    expect((top1['orientation'] as Map)['yawDegrees'], 275.75);
  });

  test('deterministic: packing twice yields identical filenames + manifest bytes', () async {
    final a1 = _writeSource('A/x.jpg', [1]);
    final a2 = _writeSource('A/y.jpg', [2]);
    final fx = _fixture(eye: [a1, a2], top: [], low: []);
    final reader = _MapSidecarReader({
      sidecarPathForFrame(a1): _sidecar('f1'),
      sidecarPathForFrame(a2): _sidecar('f2'),
    });
    final packer = CaptureBundlePacker(
      workspaceRoot: _tmp.path,
      copier: _RealCopier(),
      sidecarReader: reader,
    );

    final first = await packer.pack(
      session: _session,
      device: _device,
      config: CaptureConfig.bundledDefault,
      progression: fx.progression,
      registry: fx.registry,
    );
    final firstManifest = File(first.manifestPath).readAsStringSync();

    final second = await packer.pack(
      session: _session,
      device: _device,
      config: CaptureConfig.bundledDefault,
      progression: fx.progression,
      registry: fx.registry,
    );
    final secondManifest = File(second.manifestPath).readAsStringSync();

    expect(secondManifest, firstManifest);
    expect(File('${second.path}/images/EYE/eye_0001.jpg').existsSync(), isTrue);
    expect(File('${second.path}/images/EYE/eye_0002.jpg').existsSync(), isTrue);
  });

  test('warned frame → verdict warn in manifest', () async {
    final a = _writeSource('A/w.jpg', [1]);
    final fx = _fixture(eye: [a], top: [], low: [], warned: {a});
    final packer = CaptureBundlePacker(
      workspaceRoot: _tmp.path,
      copier: _RealCopier(),
      sidecarReader: _MapSidecarReader({}),
    );
    final bundle = await packer.pack(
      session: _session,
      device: _device,
      config: CaptureConfig.bundledDefault,
      progression: fx.progression,
      registry: fx.registry,
    );
    final manifest =
        jsonDecode(File(bundle.manifestPath).readAsStringSync()) as Map<String, dynamic>;
    expect(((manifest['photos'] as List).single as Map)['verdict'], 'warn');
    // Sidecar absent → metadata null, photoId falls back to source stem.
    expect(((manifest['photos'] as List).single as Map)['photoId'], 'w');
    expect(((manifest['photos'] as List).single as Map)['metadata'], isNull);
  });

  test('missing source file → missing_source_file, no bundle, staging cleaned', () async {
    final a = _writeSource('A/a.jpg', [1]);
    final fx = _fixture(eye: [a, '${_srcRoot.path}/A/gone.jpg'], top: [], low: []);
    final events = <String>[];
    Analytics.testSink = (name, _) => events.add(name);

    final packer = CaptureBundlePacker(
      workspaceRoot: _tmp.path,
      copier: _RealCopier(),
      sidecarReader: _MapSidecarReader({}),
    );

    await expectLater(
      packer.pack(
        session: _session,
        device: _device,
        config: CaptureConfig.bundledDefault,
        progression: fx.progression,
        registry: fx.registry,
      ),
      throwsA(isA<BundlePackException>().having(
          (e) => e.reason, 'reason', BundlePackFailureReason.missingSourceFile)),
    );
    expect(Directory('${_tmp.path}/bundles/job1').existsSync(), isFalse);
    expect(Directory('${_tmp.path}/staging/job1').existsSync(), isFalse);
    expect(events, containsAll(['bundle_pack_started', 'bundle_pack_failed']));
  });

  test('integrity mismatch when a staged file is lost → no bundle', () async {
    final a = _writeSource('A/a.jpg', [1]);
    final b = _writeSource('A/b.jpg', [2]);
    final fx = _fixture(eye: [a, b], top: [], low: []);
    final packer = CaptureBundlePacker(
      workspaceRoot: _tmp.path,
      copier: _DroppingCopier('b.jpg'), // second file never actually written
      sidecarReader: _MapSidecarReader({}),
    );

    await expectLater(
      packer.pack(
        session: _session,
        device: _device,
        config: CaptureConfig.bundledDefault,
        progression: fx.progression,
        registry: fx.registry,
      ),
      throwsA(isA<BundlePackException>().having(
          (e) => e.reason, 'reason', BundlePackFailureReason.integrityMismatch)),
    );
    expect(Directory('${_tmp.path}/bundles/job1').existsSync(), isFalse);
    expect(Directory('${_tmp.path}/staging/job1').existsSync(), isFalse);
  });

  test('insufficient storage classified from copy error', () async {
    final a = _writeSource('A/a.jpg', [1]);
    final fx = _fixture(eye: [a], top: [], low: []);
    final packer = CaptureBundlePacker(
      workspaceRoot: _tmp.path,
      copier: _NoSpaceCopier(),
      sidecarReader: _MapSidecarReader({}),
    );
    await expectLater(
      packer.pack(
        session: _session,
        device: _device,
        config: CaptureConfig.bundledDefault,
        progression: fx.progression,
        registry: fx.registry,
      ),
      throwsA(isA<BundlePackException>().having(
          (e) => e.reason, 'reason', BundlePackFailureReason.insufficientStorage)),
    );
  });

  test('cancellation → cancelled, staging cleaned, no bundle', () async {
    final a = _writeSource('A/a.jpg', [1]);
    final fx = _fixture(eye: [a], top: [], low: []);
    final token = BundleCancelToken()..cancel();
    final packer = CaptureBundlePacker(
      workspaceRoot: _tmp.path,
      copier: _RealCopier(),
      sidecarReader: _MapSidecarReader({}),
    );
    await expectLater(
      packer.pack(
        session: _session,
        device: _device,
        config: CaptureConfig.bundledDefault,
        progression: fx.progression,
        registry: fx.registry,
        cancelToken: token,
      ),
      throwsA(isA<BundlePackException>()
          .having((e) => e.reason, 'reason', BundlePackFailureReason.cancelled)),
    );
    expect(Directory('${_tmp.path}/staging/job1').existsSync(), isFalse);
    expect(Directory('${_tmp.path}/bundles/job1').existsSync(), isFalse);
  });

  test('empty level still gets a ring folder, count 0', () async {
    final a = _writeSource('A/a.jpg', [1]);
    final fx = _fixture(eye: [a], top: [], low: []);
    final packer = CaptureBundlePacker(
      workspaceRoot: _tmp.path,
      copier: _RealCopier(),
      sidecarReader: _MapSidecarReader({}),
    );
    final bundle = await packer.pack(
      session: _session,
      device: _device,
      config: CaptureConfig.bundledDefault,
      progression: fx.progression,
      registry: fx.registry,
    );
    expect(Directory('${bundle.path}/images/TOP').existsSync(), isTrue);
    expect(Directory('${bundle.path}/images/LOW').existsSync(), isTrue);
    expect(bundle.perLevelCounts, {'EYE': 1, 'TOP': 0, 'LOW': 0});
  });

  test('succeeded telemetry carries totals + duration', () async {
    final a = _writeSource('A/a.jpg', [1, 2, 3]);
    final fx = _fixture(eye: [a], top: [], low: []);
    final props = <String, Map<String, Object?>>{};
    Analytics.testSink = (name, p) => props[name] = p;

    final packer = CaptureBundlePacker(
      workspaceRoot: _tmp.path,
      copier: _RealCopier(),
      sidecarReader: _MapSidecarReader({}),
    );
    await packer.pack(
      session: _session,
      device: _device,
      config: CaptureConfig.bundledDefault,
      progression: fx.progression,
      registry: fx.registry,
    );
    expect(props['bundle_pack_started']!['total_images'], 1);
    final ok = props['bundle_pack_succeeded']!;
    expect(ok['total_images'], 1);
    expect(ok['total_bytes'], 3);
    expect(ok['duration_ms'], isA<int>());
  });

  test('IsolateBundleFileCopier copies bytes off-isolate', () async {
    final src = _writeSource('iso/in.jpg', List.filled(1000, 7));
    final dst = '${_tmp.path}/iso_out.jpg';
    final bytes = await const IsolateBundleFileCopier().copy(src, dst);
    expect(bytes, 1000);
    expect(File(dst).readAsBytesSync().length, 1000);
  });
}
