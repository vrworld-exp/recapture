// test/upload/capture_manifest_test.dart
//
// Pure unit tests for the deterministic capture_manifest builder.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/capture_photo_metadata.dart';
import 'package:recapture/domain/upload/capture_manifest.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

const _session = ManifestSession(
  projectId: 'proj1',
  jobId: 'job1',
  captureSessionId: 'sess1',
  startedAtIso: '2026-07-02T10:00:00.000Z',
  completedAtIso: '2026-07-02T10:05:00.000Z',
  appVersion: '1.0.3',
  objectSize: 'MEDIUM',
);

const _device = ManifestDevice(
  platform: 'android',
  manufacturer: 'Samsung',
  model: 'SM-A536E',
  osVersion: '13',
  appVersion: '1.0.3',
  intrinsics: CaptureIntrinsics(focalLengthMm: 4.7, focalLength35mm: 26),
);

CapturePhotoMetadata _meta(String frameId, {int index = 0, int ts = 1000}) =>
    CapturePhotoMetadata(
      sessionId: 'sess1',
      frameId: frameId,
      frameIndex: index,
      captureTimestampNs: ts,
      wallClockIso: '2026-07-02T10:00:01.000Z',
      device: const CaptureDeviceInfo(
        manufacturer: 'Samsung',
        model: 'SM-A536E',
        osVersion: '13',
      ),
      resolution: const CaptureResolutionMeta(
        width: 4032,
        height: 3024,
        aspectRatio: '4:3',
        jpegQuality: 95,
        fellBack: false,
      ),
      intrinsics: const CaptureIntrinsics(focalLengthMm: 4.7),
      conditions: const CaptureConditions(
        afLocked: true,
        aeLocked: true,
        awbLocked: true,
      ),
      orientationApplied: 'normal',
      // pose intentionally omitted → reserved null.
    );

ManifestPhoto _photo({
  required String id,
  required String levelCode,
  required String levelId,
  int? segment,
  int ts = 1000,
  String verdict = 'accepted',
  CapturePhotoMetadata? metadata,
}) =>
    ManifestPhoto(
      photoId: id,
      levelCode: levelCode,
      levelId: levelId,
      imagePath: 'recapture/proj1/job1/images/$levelCode/$id.jpg',
      sidecarPath: 'recapture/proj1/job1/images/$levelCode/$id.json',
      verdict: verdict,
      captureTimestampNs: ts,
      segmentIndex: segment,
      blurScore: 120.0,
      meanLuminance: 128.0,
      yawDegrees: 45.0,
      pitchDegrees: 40.0,
      metadata: metadata ?? _meta(id, ts: ts),
    );

const _levelA = ManifestLevel(
  levelCode: 'A',
  levelId: 'mid',
  segmentCount: 10,
  filledCount: 8,
  coveragePct: 80,
  complete: true,
  pitchBandMinDegrees: 30,
  pitchBandMaxDegrees: 60,
);

void main() {
  group('buildCaptureManifest structure', () {
    test('carries version, session identity, device, config, summary', () {
      final m = buildCaptureManifest(
        session: _session,
        device: _device,
        config: CaptureConfig.bundledDefault,
        levels: const [_levelA],
        photos: [_photo(id: 'f1', levelCode: 'A', levelId: 'mid', segment: 0)],
      );

      expect(m['manifestVersion'], kCaptureManifestVersion);
      expect(m['projectId'], 'proj1');
      expect(m['jobId'], 'job1');
      expect(m['captureSessionId'], 'sess1');
      // Additive default: a caller that doesn't pass the flow variant emits the
      // legacy 3-ring id explicitly (never an absent key).
      expect(m['flowVariant'], 'with_bottom');
      expect(m['startedAt'], '2026-07-02T10:00:00.000Z');
      expect(m['completedAt'], '2026-07-02T10:05:00.000Z');
      expect(m['appVersion'], '1.0.3');

      final device = m['device'] as Map<String, dynamic>;
      expect(device['platform'], 'android');
      expect(device['model'], 'SM-A536E');
      expect((device['intrinsics'] as Map)['focalLengthMm'], 4.7);

      final config = m['config'] as Map<String, dynamic>;
      expect(config['objectSize'], 'MEDIUM');
      expect(config['thresholds'], isA<Map>());
      expect((config['segmentCounts'] as Map)['A'], 10);

      final summary = m['summary'] as Map<String, dynamic>;
      expect(summary['totalPhotos'], 1);
      expect(summary['overallComplete'], true);
    });

    test('flowVariant carries the passed variant id', () {
      final m = buildCaptureManifest(
        session: _session,
        device: _device,
        config: CaptureConfig.bundledDefault,
        levels: const [_levelA],
        photos: const [],
        flowVariantId: 'without_bottom',
      );
      expect(m['flowVariant'], 'without_bottom');
    });

    test('summary.levels mirror the backend EYE/TOP/LOW LevelSummary shape', () {
      final m = buildCaptureManifest(
        session: _session,
        device: _device,
        config: CaptureConfig.bundledDefault,
        levels: const [
          _levelA,
          ManifestLevel(
            levelCode: 'B',
            levelId: 'high',
            segmentCount: 8,
            filledCount: 4,
            coveragePct: 50,
            complete: false,
          ),
        ],
        photos: [
          _photo(id: 'a1', levelCode: 'A', levelId: 'mid', segment: 0),
          _photo(id: 'b1', levelCode: 'B', levelId: 'high', segment: 0, verdict: 'warn'),
        ],
      );

      final levels = (m['summary'] as Map)['levels'] as Map<String, dynamic>;
      expect(levels.keys, containsAll(<String>['EYE', 'TOP']));
      final eye = levels['EYE'] as Map<String, dynamic>;
      expect(eye.keys, unorderedEquals(<String>['photos', 'coverage', 'segmentCount', 'warnings']));
      expect(eye['photos'], 1);
      expect(eye['coverage'], 80);
      expect(eye['segmentCount'], 10);
      expect(eye['warnings'], 0);

      final top = levels['TOP'] as Map<String, dynamic>;
      expect(top['warnings'], 1);
      expect((m['summary'] as Map)['overallComplete'], false); // B incomplete
    });
  });

  group('per-photo consistency (sidecar round-trip)', () {
    test('metadata embeds the sidecar losslessly', () {
      final original = _meta('f1', index: 3, ts: 5000);
      final m = buildCaptureManifest(
        session: _session,
        device: _device,
        config: CaptureConfig.bundledDefault,
        levels: const [_levelA],
        photos: [
          _photo(id: 'f1', levelCode: 'A', levelId: 'mid', segment: 2, metadata: original),
        ],
      );

      final photo = (m['photos'] as List).single as Map<String, dynamic>;
      final roundTripped =
          CapturePhotoMetadata.fromJson(photo['metadata'] as Map<String, dynamic>);
      expect(roundTripped, original);
      // Guided context rides alongside (not inside the sidecar).
      expect(photo['segmentIndex'], 2);
      expect(photo['ringName'], 'EYE');
      expect((photo['quality'] as Map)['blurScore'], 120.0);
    });

    test('null pose stays a reserved null in the embedded metadata', () {
      final m = buildCaptureManifest(
        session: _session,
        device: _device,
        config: CaptureConfig.bundledDefault,
        levels: const [_levelA],
        photos: [_photo(id: 'f1', levelCode: 'A', levelId: 'mid', segment: 0)],
      );
      final photo = (m['photos'] as List).single as Map<String, dynamic>;
      final metadata = photo['metadata'] as Map<String, dynamic>;
      expect(metadata.containsKey('pose'), isTrue);
      expect(metadata['pose'], isNull);
    });

    test('missing sidecar → metadata null, entry still present (not fabricated)', () {
      final m = buildCaptureManifest(
        session: _session,
        device: _device,
        config: CaptureConfig.bundledDefault,
        levels: const [_levelA],
        photos: [
          ManifestPhoto(
            photoId: 'f1',
            levelCode: 'A',
            levelId: 'mid',
            imagePath: 'recapture/proj1/job1/images/A/f1.jpg',
            sidecarPath: 'recapture/proj1/job1/images/A/f1.json',
            verdict: 'accepted',
            captureTimestampNs: 1000,
            segmentIndex: 0,
            metadata: null, // sidecar unreadable
          ),
        ],
      );
      final photo = (m['photos'] as List).single as Map<String, dynamic>;
      expect(photo['photoId'], 'f1');
      expect(photo['metadata'], isNull);
    });
  });

  group('file references', () {
    test('reference the storage paths, not absolute device paths', () {
      final m = buildCaptureManifest(
        session: _session,
        device: _device,
        config: CaptureConfig.bundledDefault,
        levels: const [_levelA],
        photos: [_photo(id: 'f1', levelCode: 'A', levelId: 'mid', segment: 0)],
      );
      final photo = (m['photos'] as List).single as Map<String, dynamic>;
      expect(photo['imagePath'], 'recapture/proj1/job1/images/A/f1.jpg');
      expect(photo['sidecarPath'], 'recapture/proj1/job1/images/A/f1.json');
    });
  });

  group('determinism', () {
    test('same inputs → byte-identical JSON regardless of input order', () {
      final levels = const [
        ManifestLevel(
            levelCode: 'B', levelId: 'high', segmentCount: 8, filledCount: 8, coveragePct: 100, complete: true),
        _levelA,
      ];
      final photos = [
        _photo(id: 'a2', levelCode: 'A', levelId: 'mid', segment: 5, ts: 2000),
        _photo(id: 'b1', levelCode: 'B', levelId: 'high', segment: 0, ts: 500),
        _photo(id: 'a1', levelCode: 'A', levelId: 'mid', segment: 1, ts: 100),
      ];

      final first = jsonEncode(buildCaptureManifest(
        session: _session,
        device: _device,
        config: CaptureConfig.bundledDefault,
        levels: levels,
        photos: photos,
      ));
      // Rebuild with the SAME data but shuffled input order.
      final second = jsonEncode(buildCaptureManifest(
        session: _session,
        device: _device,
        config: CaptureConfig.bundledDefault,
        levels: levels.reversed.toList(),
        photos: photos.reversed.toList(),
      ));

      expect(first, second);
    });

    test('photos ordered by level, segment, timestamp', () {
      final m = buildCaptureManifest(
        session: _session,
        device: _device,
        config: CaptureConfig.bundledDefault,
        levels: const [
          _levelA,
          ManifestLevel(
              levelCode: 'B', levelId: 'high', segmentCount: 8, filledCount: 8, coveragePct: 100, complete: true),
        ],
        photos: [
          _photo(id: 'b1', levelCode: 'B', levelId: 'high', segment: 0, ts: 500),
          _photo(id: 'a2', levelCode: 'A', levelId: 'mid', segment: 5, ts: 2000),
          _photo(id: 'a1', levelCode: 'A', levelId: 'mid', segment: 1, ts: 100),
        ],
      );
      final ids = [
        for (final p in m['photos'] as List) (p as Map)['photoId'] as String,
      ];
      expect(ids, ['a1', 'a2', 'b1']);
    });

    test('null segmentIndex sorts after numbered segments within a level', () {
      final m = buildCaptureManifest(
        session: _session,
        device: _device,
        config: CaptureConfig.bundledDefault,
        levels: const [_levelA],
        photos: [
          _photo(id: 'none', levelCode: 'A', levelId: 'mid', segment: null, ts: 1),
          _photo(id: 'seg0', levelCode: 'A', levelId: 'mid', segment: 0, ts: 9),
        ],
      );
      final ids = [
        for (final p in m['photos'] as List) (p as Map)['photoId'] as String,
      ];
      expect(ids, ['seg0', 'none']);
    });
  });

  group('partial / edge handling', () {
    test('incomplete capture reflects partial coverage + overallComplete false', () {
      final m = buildCaptureManifest(
        session: _session,
        device: _device,
        config: CaptureConfig.bundledDefault,
        levels: const [
          ManifestLevel(
              levelCode: 'A', levelId: 'mid', segmentCount: 10, filledCount: 3, coveragePct: 30, complete: false),
        ],
        photos: [_photo(id: 'a1', levelCode: 'A', levelId: 'mid', segment: 0)],
      );
      final level = (m['levels'] as List).single as Map<String, dynamic>;
      expect(level['coveragePct'], 30);
      expect(level['filledCount'], 3);
      expect(level['complete'], false);
      expect((m['summary'] as Map)['overallComplete'], false);
    });

    test('no levels → overallComplete false (fail-safe)', () {
      final m = buildCaptureManifest(
        session: _session,
        device: _device,
        config: CaptureConfig.bundledDefault,
        levels: const [],
        photos: const [],
      );
      expect((m['summary'] as Map)['overallComplete'], false);
      expect((m['summary'] as Map)['totalPhotos'], 0);
    });

    test('missing device fields are omitted, not fabricated', () {
      final m = buildCaptureManifest(
        session: const ManifestSession(
          projectId: 'p',
          jobId: 'j',
          captureSessionId: 's',
        ),
        device: const ManifestDevice(platform: 'ios'),
        config: CaptureConfig.bundledDefault,
        levels: const [_levelA],
        photos: const [],
      );
      final device = m['device'] as Map<String, dynamic>;
      expect(device['platform'], 'ios');
      expect(device.containsKey('model'), isFalse);
      expect(device.containsKey('manufacturer'), isFalse);
      // intrinsics present but empty (all null fields omitted inside).
      expect(device['intrinsics'], <String, dynamic>{});
      // Optional session fields omitted, not null-keyed.
      expect(m.containsKey('startedAt'), isFalse);
      expect(m.containsKey('appVersion'), isFalse);
      expect((m['config'] as Map).containsKey('objectSize'), isFalse);
    });
  });
}
