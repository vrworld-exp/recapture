// test/upload/capture_bundle_checksum_test.dart
//
// The bundle packer populates a per-file MD5 on every manifest entry (streamed),
// distinct from S3 ETags; a hashing failure aborts the pack.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/ledger/captured_photo_record.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry.dart';
import 'package:recapture/application/capture/progression/level_progression.dart';
import 'package:recapture/application/upload/capture_bundle_packer.dart';
import 'package:recapture/application/upload/capture_manifest_assembler.dart'
    show CaptureSidecarReader;
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/upload/capture_bundle.dart';
import 'package:recapture/domain/upload/capture_manifest.dart';
import 'package:recapture/domain/upload/file_checksum.dart';

class _RealCopier implements BundleFileCopier {
  @override
  Future<int> copy(String src, String dst) async {
    final bytes = await File(src).readAsBytes();
    await File(dst).parent.create(recursive: true);
    await File(dst).writeAsBytes(bytes);
    return bytes.length;
  }
}

class _NoSidecar implements CaptureSidecarReader {
  @override
  Future<Map<String, dynamic>?> read(String p) async => null;
}

/// Always fails — proves a hash error aborts the pack.
class _ThrowingChecksum implements FileChecksum {
  @override
  Future<String> md5Hex(String path) async =>
      throw const FileSystemException('cannot read');
}

const _session = ManifestSession(
  projectId: 'proj1',
  jobId: 'job1',
  captureSessionId: 'sess1',
);
const _device = ManifestDevice(platform: 'android');

late Directory _tmp;
late Directory _src;

String _write(String rel, List<int> bytes) {
  final f = File('${_src.path}/$rel');
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(bytes);
  return f.path;
}

({LevelCaptureLedgerRegistry registry, LevelProgression progression}) _fixture(
    List<String> eye) {
  final registry = LevelCaptureLedgerRegistry();
  for (var i = 0; i < eye.length; i++) {
    registry.ledgerFor('mid').recordAccepted(CapturedPhotoRecord(
          segmentIndex: i,
          framePath: eye[i],
          blurScore: 100,
          meanLuminance: 128,
          yawDegrees: 0,
          pitchDegrees: 0,
          sensorTimestampNs: 1000 + i,
        ));
  }
  final progression = LevelProgression.of([
    LevelProgressState(
        levelId: 'mid',
        levelCode: 'A',
        segmentCount: 10,
        filledCount: eye.length,
        acceptedCount: eye.length),
  ]);
  return (registry: registry, progression: progression);
}

void main() {
  setUp(() {
    _tmp = Directory.systemTemp.createTempSync('ck_ws_');
    _src = Directory.systemTemp.createTempSync('ck_src_');
  });
  tearDown(() {
    if (_tmp.existsSync()) _tmp.deleteSync(recursive: true);
    if (_src.existsSync()) _src.deleteSync(recursive: true);
  });

  test('every manifest entry carries a correct MD5 + algorithm; values differ',
      () async {
    final a = _write('A/a.jpg', utf8.encode('abc')); // known: 900150...
    final b = _write('A/b.jpg', utf8.encode('different content'));
    final fx = _fixture([a, b]);
    final packer = CaptureBundlePacker(
      workspaceRoot: _tmp.path,
      copier: _RealCopier(),
      sidecarReader: _NoSidecar(),
      // default StreamingMd5Checksum
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
    expect(photos.length, 2);
    for (final p in photos) {
      expect(p['checksum'], matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(p['checksumAlgorithm'], 'md5');
    }
    // Matches the reference MD5 of "abc" for that image, and differs across files.
    final byPath = {for (final p in photos) p['imagePath']: p['checksum']};
    expect(byPath['images/EYE/eye_0001.jpg'], '900150983cd24fb0d6963f7d28e17f72');
    expect(byPath.values.toSet().length, 2); // distinct content → distinct digests
    // The per-file MD5 is NOT an S3 ETag — it equals the source bytes' MD5.
    expect(byPath['images/EYE/eye_0002.jpg'],
        md5.convert(utf8.encode('different content')).toString());
  });

  test('a hashing failure aborts the pack (no bundle, no blank checksum)', () async {
    final a = _write('A/a.jpg', utf8.encode('abc'));
    final fx = _fixture([a]);
    final packer = CaptureBundlePacker(
      workspaceRoot: _tmp.path,
      copier: _RealCopier(),
      sidecarReader: _NoSidecar(),
      checksum: _ThrowingChecksum(),
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
          (e) => e.reason, 'reason', BundlePackFailureReason.checksumError)),
    );
    expect(Directory('${_tmp.path}/bundles/job1').existsSync(), isFalse);
    expect(Directory('${_tmp.path}/staging/job1').existsSync(), isFalse);
  });
}
