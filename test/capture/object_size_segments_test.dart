// test/capture/object_size_segments_test.dart
//
// Pure unit tests for the object-size → eye-ring segment-count mapping: defaults
// (36/30/24), remote-config overrides (partial, invalid, full), the null/unknown
// default, validation, and that the result feeds the ring engine / segment-state
// model cleanly.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/capture/object_size_segments.dart';
import 'package:recapture/domain/capture/ring_coverage_engine.dart';
import 'package:recapture/domain/entities/create_project_options.dart';
import 'package:recapture/domain/entities/segment_coverage.dart';

void main() {
  group('defaults', () {
    test('small/medium/large → 36/30/24', () {
      expect(eyeRingSegmentCount(ObjectSize.small), 36);
      expect(eyeRingSegmentCount(ObjectSize.medium), 30);
      expect(eyeRingSegmentCount(ObjectSize.large), 24);
    });

    test('smaller object → more segments (product rule)', () {
      expect(
        eyeRingSegmentCount(ObjectSize.small) >
            eyeRingSegmentCount(ObjectSize.medium),
        isTrue,
      );
      expect(
        eyeRingSegmentCount(ObjectSize.medium) >
            eyeRingSegmentCount(ObjectSize.large),
        isTrue,
      );
    });
  });

  group('unknown / null size', () {
    test('null → documented default (Medium → 30), no crash', () {
      expect(eyeRingSegmentCount(null), 30);
      expect(kDefaultObjectSize, ObjectSize.medium);
    });
  });

  group('remote overrides', () {
    test('partial map overrides only specified sizes', () {
      final overrides = {ObjectSize.small: 40, ObjectSize.large: 20};
      expect(eyeRingSegmentCount(ObjectSize.small, remoteOverrides: overrides), 40);
      expect(eyeRingSegmentCount(ObjectSize.large, remoteOverrides: overrides), 20);
      // medium not specified → default
      expect(eyeRingSegmentCount(ObjectSize.medium, remoteOverrides: overrides), 30);
    });

    test('full map overrides all', () {
      final overrides = {
        ObjectSize.small: 48,
        ObjectSize.medium: 36,
        ObjectSize.large: 18,
      };
      expect(eyeRingSegmentCount(ObjectSize.small, remoteOverrides: overrides), 48);
      expect(eyeRingSegmentCount(ObjectSize.medium, remoteOverrides: overrides), 36);
      expect(eyeRingSegmentCount(ObjectSize.large, remoteOverrides: overrides), 18);
    });

    test('invalid override (< 1) falls back to default; never < 1', () {
      expect(
        eyeRingSegmentCount(ObjectSize.medium, remoteOverrides: {ObjectSize.medium: 0}),
        30,
      );
      expect(
        eyeRingSegmentCount(ObjectSize.small, remoteOverrides: {ObjectSize.small: -5}),
        36,
      );
    });

    test('absurdly large override falls back to default', () {
      expect(
        eyeRingSegmentCount(ObjectSize.large,
            remoteOverrides: {ObjectSize.large: 99999}),
        24,
      );
    });

    test('empty override map → all defaults', () {
      expect(eyeRingSegmentCount(ObjectSize.small, remoteOverrides: const {}), 36);
    });
  });

  group('parseEyeRingSegmentCounts (remote-config wire shape)', () {
    test('reads api-keyed flat map (small/medium/large)', () {
      final parsed = parseEyeRingSegmentCounts({
        'small': 40,
        'medium': 28,
        'large': 20,
      });
      expect(parsed, {
        ObjectSize.small: 40,
        ObjectSize.medium: 28,
        ObjectSize.large: 20,
      });
    });

    test('drops invalid / non-numeric / out-of-range entries (partial result)',
        () {
      final parsed = parseEyeRingSegmentCounts({
        'small': 40, // ok
        'medium': 0, // < 1 → dropped
        'large': 'oops', // non-numeric → dropped
      });
      expect(parsed, {ObjectSize.small: 40});
    });

    test('coerces doubles via toInt', () {
      final parsed = parseEyeRingSegmentCounts({'small': 36.0});
      expect(parsed[ObjectSize.small], 36);
    });

    test('null / non-map input → empty map (pure defaults)', () {
      expect(parseEyeRingSegmentCounts(null), isEmpty);
      expect(parseEyeRingSegmentCounts('nope'), isEmpty);
      expect(parseEyeRingSegmentCounts(42), isEmpty);
    });

    test('round-trips through eyeRingSegmentCount end-to-end', () {
      final overrides = parseEyeRingSegmentCounts({'small': 40});
      expect(eyeRingSegmentCount(ObjectSize.small, remoteOverrides: overrides), 40);
      expect(eyeRingSegmentCount(ObjectSize.medium, remoteOverrides: overrides), 30);
    });
  });

  group('feeds the ring pipeline', () {
    test('result plugs into the ring engine as segmentCount', () {
      final n = eyeRingSegmentCount(ObjectSize.small); // 36
      final engine = RingCoverageEngine()..start(0, n);
      expect(engine.segmentCount, 36);
      expect(engine.updateYaw(95), 9); // 95 / 10° = 9.5 → segment 9
    });

    test('result plugs into SegmentCoverage as segmentCount', () {
      final n = eyeRingSegmentCount(ObjectSize.large); // 24
      final s = SegmentCoverage.initial(segmentCount: n);
      expect(s.segmentCount, 24);
      expect(s.missingSegments.length, 24);
    });
  });

  group('enum parity with P1 create-project', () {
    test('ObjectSize api values match the backend (small/medium/large)', () {
      expect(ObjectSize.small.apiValue, 'small');
      expect(ObjectSize.medium.apiValue, 'medium');
      expect(ObjectSize.large.apiValue, 'large');
      // round-trip via P1's inverse parser
      for (final size in ObjectSize.values) {
        expect(objectSizeFromApi(size.apiValue), size);
      }
    });
  });

  group('validation helper', () {
    test('isValidSegmentCount bounds', () {
      expect(isValidSegmentCount(1), isTrue);
      expect(isValidSegmentCount(0), isFalse);
      expect(isValidSegmentCount(360), isTrue);
      expect(isValidSegmentCount(361), isFalse);
    });
  });
}
