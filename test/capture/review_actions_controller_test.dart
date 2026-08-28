// test/capture/review_actions_controller_test.dart
//
// Unit coverage for the Screen 7A bottom-action-bar logic, composed over fakes:
// the consistency guarantee (storage + metadata + coverage move together, partial
// failures kept consistent), confirm gating, selection exit, the in-flight guard,
// and retake = delete + navigate-to-freed-segment.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/ledger/captured_photo_record.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger.dart';
import 'package:recapture/application/capture/ledger/warned_photo_record.dart';
import 'package:recapture/application/capture/review_actions_controller.dart';
import 'package:recapture/domain/entities/confirm_kind.dart';
import 'package:recapture/domain/entities/retake_request.dart';
import 'package:recapture/domain/entities/segment_coverage.dart';

CapturedPhotoRecord _rec(String path, int? seg) => CapturedPhotoRecord(
      segmentIndex: seg,
      framePath: path,
      blurScore: 100,
      meanLuminance: 128,
      yawDegrees: 0,
      pitchDegrees: 45,
      sensorTimestampNs: 1,
    );

/// A test harness wiring the controller over a real ledger + SegmentCoverage and
/// configurable storage-delete behavior.
class _Harness {
  _Harness({
    required List<CapturedPhotoRecord> records,
    required int segmentCount,
    Set<String> failingPaths = const {},
    bool confirmResult = true,
  })  : ledger = LevelCaptureLedger(),
        _failing = failingPaths,
        _confirmResult = confirmResult {
    for (final r in records) {
      ledger.recordAccepted(r);
      coverage = coverage.recordCapture(r.segmentIndex ?? -1);
    }
    coverage = SegmentCoverage.of(
      segmentCount: segmentCount,
      fillCounts: _countsFrom(records, segmentCount),
    );
  }

  static List<int> _countsFrom(List<CapturedPhotoRecord> recs, int n) {
    final counts = List<int>.filled(n, 0);
    for (final r in recs) {
      final s = r.segmentIndex;
      if (s != null && s >= 0 && s < n) counts[s]++;
    }
    return counts;
  }

  final LevelCaptureLedger ledger;
  SegmentCoverage coverage = SegmentCoverage.of(segmentCount: 1);
  final Set<String> _failing;
  final bool _confirmResult;

  final List<String> deleteCalls = [];
  int confirmCalls = 0;
  ConfirmKind? lastConfirmKind;
  int? lastConfirmCount;
  int exitSelectionCalls = 0;
  final List<RetakeRequest?> navCalls = [];

  /// Optional hold for testing the in-flight guard.
  Completer<void>? deleteGate;

  ReviewActionsController build() => ReviewActionsController(
        deletePhotoFile: (path) async {
          deleteCalls.add(path);
          if (deleteGate != null) await deleteGate!.future;
          return !_failing.contains(path);
        },
        removeFromLedger: ledger.removeAccepted,
        decrementSegment: (i) {
          coverage = coverage.removeCapture(i);
          return coverage.missingSegments.contains(i);
        },
        confirm: (count, kind) async {
          confirmCalls++;
          lastConfirmCount = count;
          lastConfirmKind = kind;
          return _confirmResult;
        },
        navigateToCapture: navCalls.add,
        exitSelection: () => exitSelectionCalls++,
      );
}

void main() {
  group('deleteSelected', () {
    test('removes file + metadata + coverage consistently for each photo',
        () async {
      final h = _Harness(
        records: [_rec('a.jpg', 0), _rec('b.jpg', 1)],
        segmentCount: 6,
      );
      final controller = h.build();

      final result = await controller.deleteSelected({'a.jpg', 'b.jpg'});

      expect(result.deleted, containsAll(['a.jpg', 'b.jpg']));
      expect(result.failed, isEmpty);
      expect(h.ledger.accepted, isEmpty, reason: 'metadata removed');
      expect(h.coverage.fillCounts[0], 0);
      expect(h.coverage.fillCounts[1], 0);
      expect(h.confirmCalls, 1);
      expect(h.lastConfirmCount, 2);
      expect(h.lastConfirmKind, ConfirmKind.delete);
      expect(h.exitSelectionCalls, 1);
    });

    test('cancelled confirm is a no-op (nothing removed)', () async {
      final h = _Harness(
        records: [_rec('a.jpg', 0)],
        segmentCount: 6,
        confirmResult: false,
      );
      final controller = h.build();

      final result = await controller.deleteSelected({'a.jpg'});

      expect(result.cancelled, isTrue);
      expect(h.deleteCalls, isEmpty, reason: 'no file touched after cancel');
      expect(h.ledger.accepted, hasLength(1));
      expect(h.coverage.fillCounts[0], 1);
      expect(h.exitSelectionCalls, 0);
    });

    test('a file that fails to delete keeps its metadata + coverage (consistent)',
        () async {
      final h = _Harness(
        records: [_rec('a.jpg', 0), _rec('b.jpg', 1)],
        segmentCount: 6,
        failingPaths: {'b.jpg'},
      );
      final controller = h.build();

      final result = await controller.deleteSelected({'a.jpg', 'b.jpg'});

      expect(result.deleted, ['a.jpg']);
      expect(result.failed, ['b.jpg']);
      // b survived on disk → its metadata + coverage must remain (no lie).
      expect(h.ledger.accepted.map((r) => r.framePath), ['b.jpg']);
      expect(h.coverage.fillCounts[0], 0); // a removed
      expect(h.coverage.fillCounts[1], 1); // b retained
    });

    test('deleting the last photo of a segment frees it (becomes missing)',
        () async {
      final h = _Harness(records: [_rec('a.jpg', 2)], segmentCount: 6);
      final controller = h.build();

      final result = await controller.deleteSelected({'a.jpg'});

      expect(result.freedSegments, [2]);
      expect(h.coverage.missingSegments, contains(2));
    });

    test('a segment with another photo left is NOT freed', () async {
      final h = _Harness(
        records: [_rec('a.jpg', 3), _rec('b.jpg', 3)],
        segmentCount: 6,
      );
      final controller = h.build();

      final result = await controller.deleteSelected({'a.jpg'});

      expect(result.freedSegments, isEmpty);
      expect(h.coverage.fillCounts[3], 1, reason: 'still filled by b');
    });

    test('empty selection is a no-op (no confirm)', () async {
      final h = _Harness(records: [_rec('a.jpg', 0)], segmentCount: 6);
      final controller = h.build();

      final result = await controller.deleteSelected({});

      expect(result.anyDeleted, isFalse);
      expect(h.confirmCalls, 0);
    });

    test('in-flight guard: a second call while one is running is a no-op',
        () async {
      final h = _Harness(records: [_rec('a.jpg', 0)], segmentCount: 6)
        ..deleteGate = Completer<void>();
      final controller = h.build();

      final first = controller.deleteSelected({'a.jpg'}); // hangs on the gate
      await Future<void>.delayed(Duration.zero);
      final second = await controller.deleteSelected({'a.jpg'});

      expect(second.anyDeleted, isFalse, reason: 'guarded against double-delete');
      expect(second.cancelled, isFalse);

      h.deleteGate!.complete();
      final firstResult = await first;
      expect(firstResult.deleted, ['a.jpg']);
      expect(h.deleteCalls, ['a.jpg'], reason: 'file deleted exactly once');
    });
  });

  group('retakeSelected', () {
    test('deletes then navigates to capture targeting the freed segment',
        () async {
      final h = _Harness(records: [_rec('a.jpg', 4)], segmentCount: 6);
      final controller = h.build();

      final result = await controller.retakeSelected({'a.jpg'});

      expect(result.deleted, ['a.jpg']);
      expect(h.lastConfirmKind, ConfirmKind.retake);
      expect(h.navCalls, hasLength(1));
      final request = h.navCalls.single;
      expect(request, isNotNull);
      expect(request!.ringIndex, 4);
      expect(request.returnToReviewAfter, isFalse, reason: 'resume capture');
    });

    test('cancelled retake does not navigate', () async {
      final h = _Harness(
        records: [_rec('a.jpg', 4)],
        segmentCount: 6,
        confirmResult: false,
      );
      final controller = h.build();

      final result = await controller.retakeSelected({'a.jpg'});

      expect(result.cancelled, isTrue);
      expect(h.navCalls, isEmpty);
    });

    test('a fully-failed retake does not navigate', () async {
      final h = _Harness(
        records: [_rec('a.jpg', 4)],
        segmentCount: 6,
        failingPaths: {'a.jpg'},
      );
      final controller = h.build();

      final result = await controller.retakeSelected({'a.jpg'});

      expect(result.anyDeleted, isFalse);
      expect(h.navCalls, isEmpty);
    });
  });

  group('backToCapture', () {
    test('exits selection then navigates to resume (no retake request)', () {
      final h = _Harness(records: const [], segmentCount: 6);
      final controller = h.build();

      controller.backToCapture();

      expect(h.exitSelectionCalls, 1);
      expect(h.navCalls, [null]);
    });
  });

  group('ledger.removeAccepted (used by the controller)', () {
    test('drops the accepted record + its warning, returns the removed record',
        () {
      final ledger = LevelCaptureLedger()
        ..recordAccepted(_rec('a.jpg', 0))
        ..recordWarned(const WarnedPhotoRecord(
          framePath: 'a.jpg',
          isUnderexposed: true,
          isOverexposed: false,
          meanLuminance: 30,
          sensorTimestampNs: 1,
        ));

      final removed = ledger.removeAccepted('a.jpg');

      expect(removed, hasLength(1));
      expect(removed.single.segmentIndex, 0);
      expect(ledger.accepted, isEmpty);
      expect(ledger.warned, isEmpty, reason: 'warning belongs to the gone frame');
    });

    test('removing an unknown framePath is a no-op', () {
      final ledger = LevelCaptureLedger()..recordAccepted(_rec('a.jpg', 0));
      expect(ledger.removeAccepted('zzz.jpg'), isEmpty);
      expect(ledger.accepted, hasLength(1));
    });
  });
}
