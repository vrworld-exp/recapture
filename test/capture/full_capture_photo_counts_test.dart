// test/capture/full_capture_photo_counts_test.dart
//
// QA: a full three-level (A→B→C) Guided Capture produces the expected number of
// photos, per level and in total, AND the object-size → frame-target derivation
// matches the documented targets for every supported size class.
//
// TESTS ONLY — this file asserts against the production sources of truth; it does
// NOT change any count target. If a target were edited, the matching case FAILS
// (see the sabotage notes in docs/qa/full-capture-photo-counts-qa.md).
//
// ── Convention reconciliation (read docs/qa/full-capture-photo-counts-qa.md) ──
// The task brief assumes object size drives the per-level (A/B/C) targets for all
// three levels, and that LARGER objects need MORE photos. This codebase does NOT
// work that way, so the assertions encode the REAL contract, not the brief's:
//
//  1. The per-level A/B/C target a full capture must hit comes from each level's
//     PitchBand.segments in CaptureConfig (A→'mid'=10, B→'high'=8, C→'low'=12,
//     total 30) — via the single level→band map pitchBandIdForLevel. These band
//     counts are INDEPENDENT of object size.
//  2. The ONLY object-size-dependent count is the Level A Eye Ring density,
//     eyeRingSegmentCount(size): Small 36 / Medium 30 / Large 24. The product
//     rule is INVERTED vs the brief — SMALLER objects get MORE segments (finer
//     coverage at a closer orbit; see object_size_segments.dart). This derivation
//     is the design source of truth for size→density; its wiring into the live
//     capture screen is deferred (the screen currently uses the 'mid' band count).
//
// So the monotonic-scaling guard asserts the ACTUAL direction (size↑ ⇒ count↓ or
// equal), and the per-size matrix combines the size-driven Level A density with
// the size-invariant B/C band counts. All counts are read from the production
// sources of truth so an unintended change to either fails a case here.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/analytics/capture_level_events.dart';
import 'package:recapture/application/capture/progression/level_segment_machines.dart';
import 'package:recapture/domain/capture/object_size_segments.dart';
import 'package:recapture/domain/entities/capture_config.dart';
import 'package:recapture/domain/entities/create_project_options.dart';

void main() {
  // The config the bundled (offline/first-launch) app runs on — the source of
  // truth for the per-level band counts. Read live; never hardcoded twice.
  const config = CaptureConfig.bundledDefault;

  int bandSegments(String id) =>
      config.pitchBands.firstWhere((b) => b.id == id).segments;

  group('full A→B→C frame targets per level (band config, size-independent)', () {
    // Each row: the level, its expected band id, and its expected target count.
    // Counts are the documented bundled defaults; a config-default change here
    // fails the matching row (that is the guard, per the acceptance criteria).
    const rows = <({CaptureLevel level, String bandId, int expected})>[
      (level: CaptureLevel.a, bandId: 'mid', expected: 10),
      (level: CaptureLevel.b, bandId: 'high', expected: 8),
      (level: CaptureLevel.c, bandId: 'low', expected: 12),
    ];

    for (final row in rows) {
      test('Level ${row.level.code} → band "${row.bandId}" = ${row.expected} '
          'photos', () {
        // Band → level wiring is the single source of truth.
        expect(pitchBandIdForLevel(row.level), row.bandId);
        // The target = that band's segment count, read from config.
        expect(bandSegments(row.bandId), row.expected);

        // …and the level's machine is sized from exactly that band.
        final machine = levelSegmentMachineFor(row.level, config);
        expect(machine.levelId, row.bandId);
        expect(machine.segmentCount, row.expected);

        // No level targets 0 photos (the completion gate would be meaningless).
        expect(machine.segmentCount, greaterThan(0));
      });
    }

    test('total photos for a full A→B→C capture = sum of per-level targets', () {
      // Total derived as the SUM of the per-level expectations within the test —
      // NOT a second independently hardcoded constant (acceptance criterion).
      final expectedTotal =
          rows.fold<int>(0, (sum, r) => sum + r.expected); // 10 + 8 + 12

      // The machines actually built for the flow must sum to the same total…
      final machines = levelSegmentMachinesFromConfig(config);
      final builtTotal =
          machines.fold<int>(0, (sum, m) => sum + m.segmentCount);
      expect(builtTotal, expectedTotal);

      // …and that equals the config's own totalSegments accessor.
      expect(config.totalSegments, expectedTotal);
      expect(expectedTotal, 30);
    });

    test('a full simulated capture fills every segment of every level '
        '(produces exactly the per-level target count)', () {
      // Deterministic simulation seam: no camera/sensors/timers. Filling each
      // segment once (fillThreshold defaults to 1) models a complete ring orbit.
      final machines = levelSegmentMachinesFromConfig(config);
      var captured = 0;
      for (final m in machines) {
        m.begin(0); // baseline this ring's start heading
        for (var seg = 0; seg < m.segmentCount; seg++) {
          m.recordCapture(seg);
        }
        captured += m.filledCount;
        expect(m.filledCount, m.segmentCount);
        expect(m.isComplete, isTrue,
            reason: 'Level ${m.levelCode} should be complete after a full orbit');
      }
      // Full three-level capture ⇒ the summed per-level targets, end to end.
      expect(captured, config.totalSegments);
      expect(captured, 30);
    });
  });

  group('object size → Level A Eye Ring frame target (the size-driven count)', () {
    // Per-size rows. expectedA is the documented default (36/30/24) read back via
    // eyeRingSegmentCount; B and C are the size-INVARIANT band counts. The total
    // for that size is derived in-test as expectedA + B + C.
    final highCount = bandSegments('high'); // Level B, size-invariant (8)
    final lowCount = bandSegments('low'); // Level C, size-invariant (12)

    const sizeRows = <({ObjectSize size, int expectedA})>[
      (size: ObjectSize.small, expectedA: 36),
      (size: ObjectSize.medium, expectedA: 30),
      (size: ObjectSize.large, expectedA: 24),
    ];

    for (final row in sizeRows) {
      test('${row.size.apiValue}: Level A=${row.expectedA}, '
          'B=$highCount, C=$lowCount', () {
        // Level A density IS size-driven — the guarded number.
        expect(eyeRingSegmentCount(row.size), row.expectedA);

        // Per-size total = A(size) + B + C, summed in-test (not a second const).
        final expectedTotal = row.expectedA + highCount + lowCount;
        expect(expectedTotal, row.expectedA + 8 + 12);

        // No level returns 0 for any size.
        expect(row.expectedA, greaterThan(0));
        expect(highCount, greaterThan(0));
        expect(lowCount, greaterThan(0));
      });
    }

    test('smallest size → highest Level A count; largest → lowest', () {
      // Edge rows of the matrix, asserted explicitly.
      expect(eyeRingSegmentCount(ObjectSize.small), 36); // smallest ⇒ most
      expect(eyeRingSegmentCount(ObjectSize.large), 24); // largest ⇒ fewest
    });

    test('Level A count is NON-INCREASING as object size grows '
        '(documented product rule — smaller ⇒ more; INVERTED vs the brief)', () {
      // Scaling guard: a regression that swapped/inverted the size→count mapping
      // (e.g. made it "bigger ⇒ more") would break this even if each number still
      // looked plausible. ObjectSize.values is the ordered class set small→large.
      final counts = [
        for (final s in ObjectSize.values) eyeRingSegmentCount(s),
      ];
      for (var i = 0; i + 1 < counts.length; i++) {
        expect(counts[i], greaterThanOrEqualTo(counts[i + 1]),
            reason: '${ObjectSize.values[i].apiValue} should target >= '
                '${ObjectSize.values[i + 1].apiValue}');
      }
      // And strictly decreasing for the bundled defaults (36 > 30 > 24).
      expect(counts.first, greaterThan(counts.last));
    });

    test('per-size TOTAL is non-increasing with size (only A varies; B/C fixed)',
        () {
      // Because B and C are size-invariant and A shrinks with size, the full
      // per-size target total moves in the same (inverted) direction.
      final totals = [
        for (final s in ObjectSize.values)
          eyeRingSegmentCount(s) + highCount + lowCount,
      ];
      for (var i = 0; i + 1 < totals.length; i++) {
        expect(totals[i], greaterThanOrEqualTo(totals[i + 1]));
      }
      // small 36+8+12=56, medium 50, large 44.
      expect(totals, [56, 50, 44]);
    });

    test('B and C targets are identical across all object sizes (size-invariant)',
        () {
      for (final s in ObjectSize.values) {
        expect(bandSegments('high'), highCount);
        expect(bandSegments('low'), lowCount);
        // (referencing s keeps the loop meaningful per size)
        expect(eyeRingSegmentCount(s), greaterThan(0));
      }
    });
  });

  group('unknown / unset object size', () {
    test('null size → documented Medium default (30), no throw', () {
      expect(() => eyeRingSegmentCount(null), returnsNormally);
      expect(eyeRingSegmentCount(null), eyeRingSegmentCount(ObjectSize.medium));
      expect(eyeRingSegmentCount(null), 30);
      expect(kDefaultObjectSize, ObjectSize.medium);
    });
  });
}
