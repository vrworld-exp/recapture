// test/capture/full_capture_photo_counts_test.dart
//
// QA: a full Guided Capture produces the expected number of photos, per level
// and in total, for BOTH flow variants:
//
//   with_bottom    → A(mid) 12 + B(high) 12 + C(low) 12 = 36
//   without_bottom → A(mid) 18 + B(high) 18             = 36
//
// TESTS ONLY — this file asserts against the production sources of truth
// (CaptureFlowVariant.levels, VariantSegments.bundledDefault via
// effectiveSegmentsFor, and the machines built from them); it does NOT change
// any count target. If a target were edited, the matching case FAILS.
//
// The earlier object-size → segments derivation (Small 36 / Medium 30 / Large
// 24) was REMOVED — variant-based counts replaced it as the single source of
// segment counts.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/analytics/capture_level_events.dart';
import 'package:recapture/application/capture/progression/level_segment_machines.dart';
import 'package:recapture/domain/capture/capture_flow_variant.dart';
import 'package:recapture/domain/entities/capture_config.dart';

void main() {
  // The config the bundled (offline/first-launch) app runs on — the source of
  // truth for the per-variant counts. Read live; never hardcoded twice.
  const config = CaptureConfig.bundledDefault;

  // Each row: variant → (level → expected count). The documented product
  // targets; a bundled-default change here fails the matching row.
  const matrices = <({
    CaptureFlowVariant variant,
    Map<CaptureLevel, int> expected,
  })>[
    (
      variant: CaptureFlowVariant.withBottom,
      expected: {CaptureLevel.a: 12, CaptureLevel.b: 12, CaptureLevel.c: 12},
    ),
    (
      variant: CaptureFlowVariant.withoutBottom,
      expected: {CaptureLevel.a: 18, CaptureLevel.b: 18},
    ),
  ];

  for (final row in matrices) {
    group('variant ${row.variant.id}', () {
      test('active level list matches the variant (no Level C without bottom)',
          () {
        expect(row.variant.levels, row.expected.keys.toList());
        // The 2-ring flow is a PREFIX of the 3-ring one — order never changes.
        expect(
          CaptureFlowVariant.withoutBottom.levels,
          CaptureFlowVariant.withBottom.levels.sublist(0, 2),
        );
      });

      for (final entry in row.expected.entries) {
        test('Level ${entry.key.code} = ${entry.value} photos', () {
          final bandId = pitchBandIdForLevel(entry.key);
          // The resolver every flow layer shares…
          expect(
            effectiveSegmentsFor(config, row.variant, bandId),
            entry.value,
          );
          // …and the level's machine is sized from exactly that count.
          final machine = levelSegmentMachineFor(
            entry.key,
            config,
            variant: row.variant,
          );
          expect(machine.levelId, bandId);
          expect(machine.segmentCount, entry.value);
          expect(machine.segmentCount, greaterThan(0));
        });
      }

      test('total photos for a full capture = 36', () {
        // Total derived as the SUM of the per-level expectations within the
        // test — NOT a second independently hardcoded constant.
        final expectedTotal =
            row.expected.values.fold<int>(0, (sum, n) => sum + n);
        final machines =
            levelSegmentMachinesFromConfig(config, variant: row.variant);
        final builtTotal =
            machines.fold<int>(0, (sum, m) => sum + m.segmentCount);
        expect(builtTotal, expectedTotal);
        // Both variants land on the same 36-photo budget by design.
        expect(expectedTotal, 36);
      });

      test('a full simulated capture fills every segment of every level '
          '(produces exactly the per-level target count)', () {
        // Deterministic simulation seam: no camera/sensors/timers. Filling each
        // segment once (fillThreshold defaults to 1) models a complete orbit.
        final machines =
            levelSegmentMachinesFromConfig(config, variant: row.variant);
        var captured = 0;
        for (final m in machines) {
          m.begin(0); // baseline this ring's start heading
          for (var seg = 0; seg < m.segmentCount; seg++) {
            m.recordCapture(seg);
            captured++;
          }
          expect(m.isComplete, isTrue);
          expect(m.filledCount, m.segmentCount);
        }
        expect(captured, 36);
      });
    });
  }

  group('remote-config override retunes counts with no code change', () {
    test('a valid guided_capture_variant_segments override wins', () {
      final overridden = CaptureConfig.fromMap({
        'version': 9,
        'guided_capture_variant_segments': {
          'with_bottom': {'mid': 14, 'high': 10, 'low': 8},
          'without_bottom': {'mid': 20, 'high': 16},
        },
      });
      expect(
        effectiveSegmentsFor(overridden, CaptureFlowVariant.withBottom, 'mid'),
        14,
      );
      expect(
        effectiveSegmentsFor(
            overridden, CaptureFlowVariant.withoutBottom, 'high'),
        16,
      );
    });

    test('a malformed override falls back per-entry to the bundled numbers',
        () {
      final overridden = CaptureConfig.fromMap({
        'guided_capture_variant_segments': {
          'with_bottom': {'mid': 0, 'high': 'x', 'low': 14}, // only low valid
          'without_bottom': 'garbage',
        },
      });
      expect(
        effectiveSegmentsFor(overridden, CaptureFlowVariant.withBottom, 'mid'),
        12, // bundled variant default, NOT the legacy band count
      );
      expect(
        effectiveSegmentsFor(overridden, CaptureFlowVariant.withBottom, 'low'),
        14,
      );
      expect(
        effectiveSegmentsFor(
            overridden, CaptureFlowVariant.withoutBottom, 'mid'),
        18,
      );
    });
  });
}
