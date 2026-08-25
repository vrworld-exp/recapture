// test/capture/retake_targets_freed_segment_test.dart
//
// QA CONTRACT: retaking a photo from the review grid (Screen 7A) re-targets the
// capture guidance to the SEGMENT THAT WAS FREED by the retake — so the user
// re-shoots exactly what they removed — EVEN WHEN a different missing segment is
// nearer. Hermetic: no real camera, sensors, storage, or navigation; the REAL
// segment-state (SegmentCoverage), ring math (RingMath), capture ledger, and the
// REAL retake handler (ReviewActionsController) are exercised with fakes only for
// the IO seams (storage delete, navigation).
//
// HOW "TARGETED IN CAMERA" IS ASSERTED (grounded in this repo's wiring):
//   The capture screen does NOT read SegmentCoverage.currentTarget during a retake.
//   `ReviewActionsController.retakeSelected` navigates with an EXPLICIT forced
//   target — `RetakeRequest(ringIndex: freedSegments.first)` — which the capture
//   screen primes (via retakeSessionProvider) as THE segment to re-shoot,
//   OVERRIDING the segment-state's nearest-missing `currentTarget`. So:
//     • "targeted in camera"  == the captured RetakeRequest.ringIndex (forced).
//     • the naive bug          == navigating with `currentTarget` (nearest-missing).
//   The discriminating tests arrange freed != currentTarget and assert the forced
//   ringIndex is the FREED segment, NOT the nearer currentTarget — so the test
//   FAILS if the handler ever falls back to nearest-missing.
//
// This is a TEST ONLY — it changes no production code.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/ledger/captured_photo_record.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger.dart';
import 'package:recapture/application/capture/review_actions_controller.dart';
import 'package:recapture/domain/capture/ring_coverage_engine.dart' show RingMath;
import 'package:recapture/domain/entities/retake_request.dart';
import 'package:recapture/domain/entities/segment_coverage.dart';

CapturedPhotoRecord _rec(String path, int seg) => CapturedPhotoRecord(
      segmentIndex: seg,
      framePath: path,
      blurScore: 100,
      meanLuminance: 128,
      yawDegrees: 0,
      pitchDegrees: 45,
      sensorTimestampNs: 1,
    );

/// Wires the REAL [ReviewActionsController] over a REAL [LevelCaptureLedger] +
/// [SegmentCoverage], with fakes for the two IO seams (per-photo delete +
/// navigation). [photos] maps framePath → its filled segment index.
class _RetakeHarness {
  _RetakeHarness({
    required Map<String, int> photos,
    required this.segmentCount,
    int position = 0,
    Set<String> failingPaths = const {},
    bool confirmResult = true,
  })  : ledger = LevelCaptureLedger(),
        _failing = failingPaths,
        _confirmResult = confirmResult {
    final counts = List<int>.filled(segmentCount, 0);
    photos.forEach((path, seg) {
      ledger.recordAccepted(_rec(path, seg));
      if (seg >= 0 && seg < segmentCount) counts[seg]++;
    });
    coverage = SegmentCoverage.of(
      segmentCount: segmentCount,
      fillCounts: counts,
      position: position,
    );
  }

  final int segmentCount;
  final LevelCaptureLedger ledger;
  final Set<String> _failing;
  final bool _confirmResult;

  /// The live segment-state, mutated by the controller's decrement seam.
  late SegmentCoverage coverage;

  /// Fake storage: records each delete attempt; a path in [failingPaths] "fails"
  /// (file still present) so coverage/metadata for it stay intact.
  final List<String> deleteCalls = [];

  /// Fake navigation: records every navigate-to-capture call (null = resume).
  final List<RetakeRequest?> navCalls = [];

  ReviewActionsController build() => ReviewActionsController(
        deletePhotoFile: (path) async {
          deleteCalls.add(path);
          return !_failing.contains(path);
        },
        removeFromLedger: ledger.removeAccepted,
        decrementSegment: (i) {
          coverage = coverage.removeCapture(i);
          return coverage.missingSegments.contains(i);
        },
        confirm: (count, kind) async => _confirmResult,
        navigateToCapture: navCalls.add,
      );

  // ── assertion helpers (segment-state reads) ───────────────────────────────
  bool isFilled(int i) => coverage.filled[i];
  bool isMissing(int i) => coverage.missingSegments.contains(i);
  int? get currentTarget => coverage.currentTarget;

  /// The forced retake target the capture screen would prime (last nav), or null.
  int? get forcedTarget => navCalls.isEmpty ? null : navCalls.last?.ringIndex;
  bool get ledgerHas => ledger.accepted.isNotEmpty;
  bool ledgerHasPath(String p) => ledger.accepted.any((r) => r.framePath == p);
}

void main() {
  group('single retake → freed segment becomes missing + is targeted', () {
    test('retaking p5 frees segment 5, deletes it, navigates targeting 5',
        () async {
      // {3,5,9} filled; user is at segment 5 (so nearest-missing also lands on 5).
      final h = _RetakeHarness(
        photos: {'p3': 3, 'p5': 5, 'p9': 9},
        segmentCount: 12,
        position: 5,
      );
      final controller = h.build();

      final result = await controller.retakeSelected({'p5'});

      // Segment 5 is now MISSING (unfilled); the photo is gone from storage + ledger.
      expect(h.isMissing(5), isTrue);
      expect(h.isFilled(5), isFalse);
      expect(h.deleteCalls, ['p5']);
      expect(h.ledgerHasPath('p5'), isFalse);
      expect(result.freedSegments, [5]);

      // Navigation happened, targeting the freed segment.
      expect(h.navCalls, hasLength(1));
      expect(h.forcedTarget, 5);
      // Here the nearest-missing default coincides with the freed segment.
      expect(h.currentTarget, 5);
    });
  });

  group('DISCRIMINATING: freed != nearest-missing → freed wins', () {
    test('retake segment 8 while segment 2 is the nearer gap → target is 8, not 2',
        () async {
      // Filled {0,1,8}; user at segment 1. After freeing 8, the NEAREST missing
      // gap from position 1 is segment 2 (distance 1) — segment 8 is distance 5.
      final h = _RetakeHarness(
        photos: {'p0': 0, 'p1': 1, 'p8': 8},
        segmentCount: 12,
        position: 1,
      );
      final controller = h.build();

      await controller.retakeSelected({'p8'});

      // The freed segment is the forced target...
      expect(h.forcedTarget, 8);
      expect(h.isMissing(8), isTrue);

      // ...even though the segment-state's nearest-missing default points elsewhere.
      expect(h.currentTarget, 2, reason: 'nearest gap from pos 1 is segment 2');
      expect(h.forcedTarget, isNot(equals(h.currentTarget)),
          reason: 'retake overrides nearest-missing with the freed segment');
      // The naive bug would target the nearer gap (2); prove 8 is genuinely farther.
      expect(
        RingMath.segmentDistance(1, 8, 12),
        greaterThan(RingMath.segmentDistance(1, 2, 12)),
      );
    });

    test('wraparound: freed segment across the 180° seam still wins over a '
        'wraparound-near gap', () async {
      // Filled {0,6}; user at segment 0. Segment 6 is the maximal distance (6) —
      // exactly across the seam — yet retaking it must target 6, not the nearest
      // gap (segment 1, or the wraparound neighbour 11).
      final h = _RetakeHarness(
        photos: {'p0': 0, 'p6': 6},
        segmentCount: 12,
        position: 0,
      );
      await h.build().retakeSelected({'p6'});

      expect(h.forcedTarget, 6);
      expect(h.isMissing(6), isTrue);
      expect(h.currentTarget, 1, reason: 'nearest gap from pos 0 is segment 1');
      // 6 is the farthest possible on a 12-ring (the seam); the engine's
      // wraparound-aware distance is what makes "nearest" well-defined here.
      expect(RingMath.segmentDistance(0, 6, 12), 6);
      expect(RingMath.segmentDistance(0, 1, 12), 1);
      expect(h.forcedTarget, isNot(equals(h.currentTarget)));
    });
  });

  group('multiple retake → all freed missing; first freed targeted', () {
    test('retake {p6,p10} frees both; targets the first (6), not a nearer gap',
        () async {
      // Filled {0,6,10}; user at segment 0 → nearest gap after retake is 1, but
      // the retake target must be the first freed segment (6), not 1.
      final h = _RetakeHarness(
        photos: {'p0': 0, 'p6': 6, 'p10': 10},
        segmentCount: 12,
        position: 0,
      );
      final result = await h.build().retakeSelected({'p6', 'p10'});

      expect(h.isMissing(6), isTrue);
      expect(h.isMissing(10), isTrue);
      expect(result.freedSegments, [6, 10]); // ascending
      expect(h.forcedTarget, 6, reason: 'first/defined freed segment');
      expect(h.currentTarget, 1, reason: 'an UNRELATED nearest gap');
      expect(h.forcedTarget, isNot(equals(h.currentTarget)));
    });

    test('partial delete failure → only actually-freed segments count; target '
        'among them', () async {
      // Retake {p6,p10} but p10 fails to delete → segment 10 stays filled, only 6
      // is freed; the target is among the actually-freed (6).
      final h = _RetakeHarness(
        photos: {'p6': 6, 'p10': 10},
        segmentCount: 12,
        position: 0,
        failingPaths: {'p10'},
      );
      final result = await h.build().retakeSelected({'p6', 'p10'});

      expect(result.freedSegments, [6]);
      expect(result.failed, ['p10']);
      expect(h.isMissing(6), isTrue);
      expect(h.isFilled(10), isTrue, reason: 'failed delete keeps it filled');
      expect(h.ledgerHasPath('p10'), isTrue, reason: 'metadata kept for the failure');
      expect(h.forcedTarget, 6);
    });
  });

  group('retake the only filled segment', () {
    test('frees it and targets it', () async {
      final h = _RetakeHarness(
        photos: {'p7': 7},
        segmentCount: 12,
        position: 7,
      );
      await h.build().retakeSelected({'p7'});

      expect(h.isMissing(7), isTrue);
      expect(h.coverage.filledCount, 0);
      expect(h.forcedTarget, 7);
      expect(h.currentTarget, 7); // at pos 7 the nearest gap is 7 itself
    });
  });

  group('confirm cancelled → no change', () {
    test('declined confirmation: no delete, no navigation, target unchanged',
        () async {
      final h = _RetakeHarness(
        photos: {'p3': 3, 'p5': 5, 'p9': 9},
        segmentCount: 12,
        position: 0,
        confirmResult: false,
      );
      final targetBefore = h.currentTarget;
      final filledBefore = h.coverage.filledCount;

      final result = await h.build().retakeSelected({'p5'});

      expect(result.cancelled, isTrue);
      expect(h.deleteCalls, isEmpty, reason: 'nothing deleted on cancel');
      expect(h.navCalls, isEmpty, reason: 'no navigation on cancel');
      expect(h.isFilled(5), isTrue, reason: 'segment 5 still filled');
      expect(h.ledgerHasPath('p5'), isTrue);
      expect(h.coverage.filledCount, filledBefore);
      expect(h.currentTarget, targetBefore, reason: 'target unchanged');
    });
  });

  group('re-fill after retake → fills + target advances', () {
    test('capturing the targeted freed segment fills it and advances the target',
        () async {
      final h = _RetakeHarness(
        photos: {'p3': 3, 'p5': 5, 'p9': 9},
        segmentCount: 12,
        position: 5,
      );
      await h.build().retakeSelected({'p5'});
      expect(h.forcedTarget, 5);
      expect(h.isMissing(5), isTrue);

      // Simulate an accepted capture at the targeted freed segment (the real
      // recordCapture path; the capture screen would do this on an accepted shot).
      h.coverage = h.coverage.recordCapture(5);

      expect(h.isFilled(5), isTrue, reason: 're-filled');
      // The nearest-missing target now advances past 5 to the next gap (6).
      expect(h.currentTarget, 6);
    });
  });
}
