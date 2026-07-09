// test/capture/capture_flow_variant_test.dart
//
// The capture FLOW VARIANT domain type + its config plumbing:
//   - CaptureFlowVariant identity (wire ids), tolerant fromId, band lists, and
//     the application-layer `levels` view (2-ring is a PREFIX of 3-ring).
//   - VariantSegments: never-throw fromMap, per-entry fallback to the bundled
//     numbers, toMap round-trip, equality, and the sanitizer clamp.
//   - effectiveSegmentsFor precedence: variant override → bundled variant
//     default → legacy PitchBand.segments → 12.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/analytics/capture_level_events.dart';
import 'package:recapture/domain/capture/capture_flow_variant.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/capture_config_validator.dart';

void main() {
  group('CaptureFlowVariant identity', () {
    test('wire ids are stable', () {
      expect(CaptureFlowVariant.withBottom.id, 'with_bottom');
      expect(CaptureFlowVariant.withoutBottom.id, 'without_bottom');
    });

    test('fromId round-trips both ids and never throws on junk', () {
      for (final v in CaptureFlowVariant.values) {
        expect(CaptureFlowVariant.fromId(v.id), v);
      }
      expect(CaptureFlowVariant.fromId(null), CaptureFlowVariant.withBottom);
      expect(CaptureFlowVariant.fromId(''), CaptureFlowVariant.withBottom);
      expect(
          CaptureFlowVariant.fromId('4_rings'), CaptureFlowVariant.withBottom);
    });

    test('band lists: 2-ring is a prefix of 3-ring; includesBand agrees', () {
      expect(CaptureFlowVariant.withBottom.bandIds, ['mid', 'high', 'low']);
      expect(CaptureFlowVariant.withoutBottom.bandIds, ['mid', 'high']);
      expect(CaptureFlowVariant.withoutBottom.includesBand('low'), isFalse);
      expect(CaptureFlowVariant.withBottom.includesBand('low'), isTrue);
    });

    test('levels view mirrors bandIds through pitchBandIdForLevel', () {
      for (final variant in CaptureFlowVariant.values) {
        expect(
          variant.levels.map(pitchBandIdForLevel).toList(),
          variant.bandIds,
        );
      }
      // Prefix invariant — flow order never changes between variants.
      expect(
        CaptureFlowVariant.withoutBottom.levels,
        CaptureFlowVariant.withBottom.levels
            .sublist(0, CaptureFlowVariant.withoutBottom.levels.length),
      );
    });
  });

  group('VariantSegments', () {
    test('bundled defaults carry the product numbers', () {
      const v = VariantSegments.bundledDefault;
      expect(v.segmentsFor('with_bottom', 'mid'), 12);
      expect(v.segmentsFor('with_bottom', 'high'), 12);
      expect(v.segmentsFor('with_bottom', 'low'), 12);
      expect(v.segmentsFor('without_bottom', 'mid'), 18);
      expect(v.segmentsFor('without_bottom', 'high'), 18);
      // The 2-ring variant deliberately has NO 'low' entry.
      expect(v.segmentsFor('without_bottom', 'low'), isNull);
    });

    test('fromMap keeps valid entries, drops junk per-entry, never throws', () {
      final v = VariantSegments.fromMap({
        'with_bottom': {'mid': 14, 'high': 0, 'low': 'x'},
        'without_bottom': 'garbage',
        42: {'mid': 5},
      });
      expect(v.segmentsFor('with_bottom', 'mid'), 14); // override kept
      expect(v.segmentsFor('with_bottom', 'high'), 12); // dropped → bundled
      expect(v.segmentsFor('with_bottom', 'low'), 12); // dropped → bundled
      expect(v.segmentsFor('without_bottom', 'mid'), 18); // garbage → bundled
    });

    test('non-map input → bundled defaults', () {
      expect(VariantSegments.fromMap(null), VariantSegments.bundledDefault);
      expect(VariantSegments.fromMap('nope'), VariantSegments.bundledDefault);
      expect(VariantSegments.fromMap(7), VariantSegments.bundledDefault);
    });

    test('toMap → fromMap round-trips the stored overrides', () {
      final v = VariantSegments.fromMap({
        'with_bottom': {'mid': 14, 'low': 9},
      });
      expect(VariantSegments.fromMap(v.toMap()), v);
    });

    test('sanitizer clamps counts into [1, 64]', () {
      final cfg = CaptureConfig.bundledDefault.copyWith(
        variantSegments: VariantSegments.fromMap(const {
          'with_bottom': {'mid': 500, 'high': 2},
        }),
      );
      final safe = sanitizeCaptureConfig(cfg);
      expect(safe.variantSegments.segmentsFor('with_bottom', 'mid'), 64);
      expect(safe.variantSegments.segmentsFor('with_bottom', 'high'), 2);
    });

    test('config wire round-trip (guided_capture_variant_segments)', () {
      final cfg = CaptureConfig.bundledDefault.copyWith(
        variantSegments: VariantSegments.fromMap(const {
          'without_bottom': {'mid': 20, 'high': 16},
        }),
      );
      final back = CaptureConfig.fromMap(cfg.toMap());
      expect(back.variantSegments, cfg.variantSegments);
      expect(
        effectiveSegmentsFor(back, CaptureFlowVariant.withoutBottom, 'mid'),
        20,
      );
    });
  });

  group('effectiveSegmentsFor precedence', () {
    test('variant override wins over everything', () {
      final cfg = CaptureConfig.bundledDefault.copyWith(
        variantSegments: VariantSegments.fromMap(const {
          'with_bottom': {'mid': 15, 'high': 12, 'low': 12},
        }),
      );
      expect(
          effectiveSegmentsFor(cfg, CaptureFlowVariant.withBottom, 'mid'), 15);
    });

    test('bundled variant default beats the legacy band count', () {
      // Bundled pitchBands still carry the legacy mid=10 — the variant default
      // (12) must win so old cached configs can't shrink the new flow.
      expect(
        effectiveSegmentsFor(
            CaptureConfig.bundledDefault, CaptureFlowVariant.withBottom, 'mid'),
        12,
      );
    });

    test('unknown band falls back to the legacy band count, then 12', () {
      final cfg = CaptureConfig.bundledDefault.copyWith(pitchBands: const [
        PitchBand(id: 'custom', minDegrees: 0, maxDegrees: 45, segments: 7),
      ]);
      // 'custom' has no variant entry → legacy band count.
      expect(
        effectiveSegmentsFor(cfg, CaptureFlowVariant.withBottom, 'custom'),
        7,
      );
      // Completely unknown band → the final 12 floor.
      expect(
        effectiveSegmentsFor(cfg, CaptureFlowVariant.withBottom, 'nowhere'),
        12,
      );
    });

    test("without_bottom 'low' lookups resolve via legacy band (no variant "
        'entry), so even a stray Level C read stays sane', () {
      expect(
        effectiveSegmentsFor(
            CaptureConfig.bundledDefault, CaptureFlowVariant.withoutBottom, 'low'),
        12, // legacy 'low' band count — never 0/null
      );
    });
  });
}
