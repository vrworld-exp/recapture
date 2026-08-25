// test/upload/capture_manifest_assembler_test.dart
//
// Tests the IO composition around the pure builder with in-memory fakes (no real
// filesystem): sidecar reads merged, coverage/levels read from the progression,
// storage-path references, and the write seam.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/ledger/captured_photo_record.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry.dart';
import 'package:recapture/application/capture/ledger/warned_photo_record.dart';
import 'package:recapture/application/capture/progression/level_progression.dart';
import 'package:recapture/application/upload/capture_manifest_assembler.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/upload/capture_manifest.dart';

/// In-memory sidecar reader keyed by absolute sidecar path.
class _FakeSidecarReader implements CaptureSidecarReader {
  _FakeSidecarReader(this.byPath);
  final Map<String, Map<String, dynamic>> byPath;
  final List<String> reads = [];

  @override
  Future<Map<String, dynamic>?> read(String absoluteSidecarPath) async {
    reads.add(absoluteSidecarPath);
    return byPath[absoluteSidecarPath];
  }
}

class _CapturingWriter implements CaptureManifestWriter {
  String? json;
  String? projectId;
  String? jobId;

  @override
  Future<void> write({
    required String projectId,
    required String jobId,
    required String json,
  }) async {
    this.projectId = projectId;
    this.jobId = jobId;
    this.json = json;
  }
}

Map<String, dynamic> _sidecarJson(String frameId) => {
      'sessionId': 'sess1',
      'frameId': frameId,
      'frameIndex': 0,
      'captureTimestampNs': 1000,
      'wallClockIso': '2026-07-02T10:00:01.000Z',
      'device': {'manufacturer': 'Samsung', 'model': 'SM-A536E', 'osVersion': '13'},
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

LevelProgression _progression() => LevelProgression.of(const [
      LevelProgressState(
        levelId: 'mid',
        levelCode: 'A',
        segmentCount: 10,
        filledCount: 8,
        acceptedCount: 8,
      ),
    ]);

void main() {
  group('path helpers', () {
    test('sidecarPathForFrame swaps extension alongside the frame', () {
      expect(sidecarPathForFrame('/data/x/000001_f.jpg'), '/data/x/000001_f.json');
      expect(sidecarPathForFrame(r'C:\data\x\000001_f.jpg'), r'C:\data\x\000001_f.json');
    });

    test('storage refs are portable, not device-absolute', () {
      expect(captureImageStoragePath('p', 'j', 'A', 'f.jpg'),
          'recapture/p/j/images/A/f.jpg');
      expect(captureSidecarStoragePath('p', 'j', 'A', 'f.jpg'),
          'recapture/p/j/images/A/f.json');
    });
  });

  group('assemble', () {
    test('merges the sidecar and reads coverage from progression', () async {
      final registry = LevelCaptureLedgerRegistry();
      registry.ledgerFor('mid').recordAccepted(const CapturedPhotoRecord(
            segmentIndex: 0,
            framePath: '/abs/proj1/job1/images/A/000001_fa.jpg',
            blurScore: 120,
            meanLuminance: 128,
            yawDegrees: 45,
            pitchDegrees: 40,
            sensorTimestampNs: 1000,
          ));

      final reader = _FakeSidecarReader({
        '/abs/proj1/job1/images/A/000001_fa.json': _sidecarJson('frame-A-1'),
      });
      final assembler = CaptureManifestAssembler(sidecarReader: reader);

      final m = await assembler.assemble(
        session: _session,
        device: _device,
        config: CaptureConfig.bundledDefault,
        progression: _progression(),
        registry: registry,
      );

      // Sidecar was located via the absolute frame path.
      expect(reader.reads, ['/abs/proj1/job1/images/A/000001_fa.json']);

      final photo = (m['photos'] as List).single as Map<String, dynamic>;
      // photoId came from the sidecar's canonical frameId.
      expect(photo['photoId'], 'frame-A-1');
      // File references are the PORTABLE storage paths (basename preserved).
      expect(photo['imagePath'], 'recapture/proj1/job1/images/A/000001_fa.jpg');
      expect(photo['sidecarPath'], 'recapture/proj1/job1/images/A/000001_fa.json');
      // Native field merged from the sidecar (only present in the sidecar).
      expect((photo['metadata'] as Map)['wallClockIso'], '2026-07-02T10:00:01.000Z');

      // Coverage/levels READ from progression, not recomputed.
      final level = (m['levels'] as List).single as Map<String, dynamic>;
      expect(level['segmentCount'], 10);
      expect(level['filledCount'], 8);
      expect(level['coveragePct'], 80);
      expect(level['complete'], true);
    });

    test('warned-and-kept photo → verdict warn', () async {
      final registry = LevelCaptureLedgerRegistry();
      const path = '/abs/images/A/f.jpg';
      registry.ledgerFor('mid').recordAccepted(const CapturedPhotoRecord(
            segmentIndex: 0,
            framePath: path,
            blurScore: 120,
            meanLuminance: 40,
            yawDegrees: 0,
            pitchDegrees: 40,
            sensorTimestampNs: 1000,
          ));
      registry.ledgerFor('mid').recordWarned(const WarnedPhotoRecord(
            framePath: path,
            isUnderexposed: true,
            isOverexposed: false,
            meanLuminance: 40,
            sensorTimestampNs: 1000,
          ));

      final assembler =
          CaptureManifestAssembler(sidecarReader: _FakeSidecarReader({}));
      final m = await assembler.assemble(
        session: _session,
        device: _device,
        config: CaptureConfig.bundledDefault,
        progression: _progression(),
        registry: registry,
      );
      final photo = (m['photos'] as List).single as Map<String, dynamic>;
      expect(photo['verdict'], 'warn');
      // Sidecar absent → metadata null, entry kept, photoId falls back to stem.
      expect(photo['metadata'], isNull);
      expect(photo['photoId'], 'f');
    });

    test('assembleAndWrite encodes + writes via the writer seam', () async {
      final registry = LevelCaptureLedgerRegistry();
      final writer = _CapturingWriter();
      final assembler = CaptureManifestAssembler(
        sidecarReader: _FakeSidecarReader({}),
        writer: writer,
      );

      final json = await assembler.assembleAndWrite(
        session: _session,
        device: _device,
        config: CaptureConfig.bundledDefault,
        progression: _progression(),
        registry: registry,
      );

      expect(writer.projectId, 'proj1');
      expect(writer.jobId, 'job1');
      expect(writer.json, json);
      expect(json, contains('"manifestVersion":"$kCaptureManifestVersion"'));
    });

    test('assembleAndWrite without a writer throws', () async {
      final assembler =
          CaptureManifestAssembler(sidecarReader: _FakeSidecarReader({}));
      expect(
        () => assembler.assembleAndWrite(
          session: _session,
          device: _device,
          config: CaptureConfig.bundledDefault,
          progression: _progression(),
          registry: LevelCaptureLedgerRegistry(),
        ),
        throwsStateError,
      );
    });
  });
}
