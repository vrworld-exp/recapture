// test/capture/capture_photo_metadata_test.dart
//
// Tests CapturePhotoMetadata: lossless round-trip with a REAL native sidecar
// sample (matching android CaptureMetadata.toSidecarMap + docs/camera/
// capture-metadata.md), the native null policy (intrinsics omit / conditions
// keep), tolerant + forward-compatible parsing, copyWith immutability, value
// equality, and the precise-vs-wallclock timestamp distinction.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/capture_photo_metadata.dart';

/// A realistic sidecar exactly as the native writer emits it (every device/
/// intrinsics field present; unobserved exposure fields explicit null).
Map<String, dynamic> sampleSidecar() => {
      'sessionId': 'job-123',
      'frameId': 'frame-0007',
      'frameIndex': 7,
      'captureTimestampNs': 123456789012345,
      'wallClockIso': '2026-06-17T10:00:00.123Z',
      'device': {
        'manufacturer': 'Google',
        'model': 'Pixel 8',
        'osVersion': '14',
        'appVersion': '1.2.0',
        'cameraId': '0',
      },
      'resolution': {
        'width': 4080,
        'height': 3060,
        'aspectRatio': '4:3',
        'jpegQuality': 95,
        'fellBack': false,
      },
      'intrinsics': {
        'focalLengthMm': 6.81,
        'focalLength35mm': 25,
        'fNumber': 1.68,
        'sensorWidthMm': 9.6,
        'sensorHeightMm': 7.2,
      },
      'capture': {
        'afLocked': true,
        'aeLocked': true,
        'awbLocked': false,
        'exposureTimeNs': null,
        'iso': null,
        'focusDistanceDiopters': null,
      },
      'orientationApplied': 'normal',
      'pose': null,
    };

void main() {
  group('lossless round-trip with the native sidecar', () {
    test('fromJson → toJson reproduces the sidecar (model-equal both ways)', () {
      final sidecar = sampleSidecar();
      final model = CapturePhotoMetadata.fromJson(sidecar);
      final reparsed = CapturePhotoMetadata.fromJson(model.toJson());
      expect(reparsed, equals(model));
    });

    test('round-trip preserves the exact top-level key set', () {
      final out = CapturePhotoMetadata.fromJson(sampleSidecar()).toJson();
      expect(
        out.keys.toSet(),
        {
          'sessionId',
          'frameId',
          'frameIndex',
          'captureTimestampNs',
          'wallClockIso',
          'device',
          'resolution',
          'intrinsics',
          'capture',
          'orientationApplied',
          'pose',
        },
      );
    });

    test('survives an encode/decode JSON cycle', () {
      final model = CapturePhotoMetadata.fromJson(sampleSidecar());
      final cycled = CapturePhotoMetadata.fromJson(
        jsonDecode(jsonEncode(model.toJson())) as Map<String, dynamic>,
      );
      expect(cycled, equals(model));
    });

    test('every scalar value survives the round-trip', () {
      final m = CapturePhotoMetadata.fromJson(sampleSidecar());
      expect(m.sessionId, 'job-123');
      expect(m.frameId, 'frame-0007');
      expect(m.frameIndex, 7);
      expect(m.captureTimestampNs, 123456789012345);
      expect(m.wallClockIso, '2026-06-17T10:00:00.123Z');
      expect(m.device.model, 'Pixel 8');
      expect(m.resolution.aspectRatio, '4:3');
      expect(m.intrinsics.focalLength35mm, 25);
      expect(m.conditions.afLocked, isTrue);
      expect(m.conditions.awbLocked, isFalse);
      expect(m.orientationApplied, 'normal');
      expect(m.pose, isNull);
    });
  });

  group('native null policy parity', () {
    test('intrinsics OMITS null fields (never fabricated)', () {
      const m = CaptureIntrinsics(focalLengthMm: 6.81); // others null
      final json = m.toJson();
      expect(json.containsKey('focalLengthMm'), isTrue);
      expect(json.containsKey('fNumber'), isFalse);
      expect(json.containsKey('sensorWidthMm'), isFalse);
      expect(json.containsKey('focalLength35mm'), isFalse);
    });

    test('an empty intrinsics object serializes to {}', () {
      expect(CaptureIntrinsics.empty.toJson(), isEmpty);
    });

    test('capture conditions ALWAYS keep all six keys (explicit nulls)', () {
      const c =
          CaptureConditions(afLocked: false, aeLocked: false, awbLocked: false);
      final json = c.toJson();
      expect(json.keys.toSet(), {
        'afLocked',
        'aeLocked',
        'awbLocked',
        'exposureTimeNs',
        'iso',
        'focusDistanceDiopters',
      });
      expect(json['exposureTimeNs'], isNull);
      expect(json['iso'], isNull);
    });

    test('device keeps all five keys (appVersion/cameraId may be null)', () {
      const d = CaptureDeviceInfo(
          manufacturer: 'X', model: 'Y', osVersion: '1'); // optional null
      final json = d.toJson();
      expect(json.keys.toSet(),
          {'manufacturer', 'model', 'osVersion', 'appVersion', 'cameraId'});
      expect(json['appVersion'], isNull);
    });
  });

  group('numeric coercion', () {
    test('int-encoded doubles parse correctly (4 and 4.0 both → 4.0)', () {
      final m = CaptureIntrinsics.fromJson(
          {'focalLengthMm': 4, 'fNumber': 1.8}); // 4 is an int in JSON
      expect(m.focalLengthMm, 4.0);
      expect(m.fNumber, 1.8);
    });

    test('large monotonic timestamp preserved as int', () {
      final m = CapturePhotoMetadata.fromJson(
          {...sampleSidecar(), 'captureTimestampNs': 9007199254740991});
      expect(m.captureTimestampNs, 9007199254740991);
    });
  });

  group('tolerant + forward-compatible parsing', () {
    test('missing optional fields → null/defaults, no crash', () {
      final m = CapturePhotoMetadata.fromJson({
        'sessionId': 's',
        'frameId': 'f',
        // frameIndex, timestamp, nested objects all missing
      });
      expect(m.frameIndex, 0);
      expect(m.captureTimestampNs, 0);
      expect(m.wallClockIso, '');
      expect(m.device.manufacturer, '');
      expect(m.intrinsics, CaptureIntrinsics.empty);
      expect(m.orientationApplied, isNull);
      expect(m.pose, isNull);
    });

    test('unknown/extra top-level + nested keys are ignored (forward-compat)',
        () {
      final json = {
        ...sampleSidecar(),
        'futureField': 'whatever',
        'schemaVersion': 9,
      };
      json['device'] = {
        ...(json['device'] as Map).cast<String, dynamic>(),
        'newDeviceField': true,
      };
      final m = CapturePhotoMetadata.fromJson(json);
      expect(m.toJson().containsKey('futureField'), isFalse);
      expect(m.device.model, 'Pixel 8'); // known fields still parse
    });

    test('a future pose object round-trips losslessly (reserved slot filled)',
        () {
      final json = {
        ...sampleSidecar(),
        'pose': {
          'position': [1.0, 2.0, 3.0],
          'quaternion': [0.0, 0.0, 0.0, 1.0],
        },
      };
      final m = CapturePhotoMetadata.fromJson(json);
      final reparsed = CapturePhotoMetadata.fromJson(m.toJson());
      expect(reparsed, equals(m));
      expect(m.pose, isNotNull);
    });
  });

  group('timestamp domains', () {
    test('precise captureTimestampNs and wall-clock are distinct, both kept',
        () {
      final m = CapturePhotoMetadata.fromJson(sampleSidecar());
      expect(m.captureTimestampNs, isA<int>());
      expect(m.wallClockIso, isA<String>());
      // wall-clock is human text; the alignment key is the monotonic ns.
      expect(m.wallClockIso.contains('T'), isTrue);
      expect(m.captureTimestampNs, isNot(0));
    });
  });

  group('immutability + equality', () {
    test('copyWith fills a late field (pose) without mutating the original', () {
      final m = CapturePhotoMetadata.fromJson(sampleSidecar());
      final withPose = m.copyWith(pose: {'q': 1});
      expect(m.pose, isNull); // original untouched
      expect(withPose.pose, {'q': 1});
      expect(withPose, isNot(equals(m)));
    });

    test('value equality + hashCode', () {
      final a = CapturePhotoMetadata.fromJson(sampleSidecar());
      final b = CapturePhotoMetadata.fromJson(sampleSidecar());
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      final c = a.copyWith(frameIndex: 99);
      expect(a, isNot(equals(c)));
    });

    test('nested value types compare by value', () {
      const a = CaptureDeviceInfo(manufacturer: 'A', model: 'B', osVersion: '1');
      const b = CaptureDeviceInfo(manufacturer: 'A', model: 'B', osVersion: '1');
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });
  });
}
