// test/capture/session/capture_session_codec_test.dart
//
// Pure codec tests: capture() from live SegmentCoverage + LevelCaptureLedger,
// toJson/fromJson round-trip fidelity, error handling, and restore() back into a
// rebuilt SegmentCoverage + reset-and-replayed ledger. No Hive needed.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/ledger/captured_photo_record.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger.dart';
import 'package:recapture/application/capture/ledger/photo_rejection_reason.dart';
import 'package:recapture/application/capture/ledger/rejected_photo_record.dart';
import 'package:recapture/application/capture/ledger/warned_photo_record.dart';
import 'package:recapture/application/capture/session/capture_session_codec.dart';
import 'package:recapture/application/capture/session/capture_session_keys.dart';
import 'package:recapture/application/capture/session/capture_session_state.dart';
import 'package:recapture/domain/entities/segment_coverage.dart';

CapturedPhotoRecord makeAccepted({
  int? segmentIndex = 0,
  String framePath = '/tmp/f1.jpg',
  double blurScore = 80,
  double meanLuminance = 128,
  double yawDegrees = 0,
  double pitchDegrees = 45,
  int sensorTimestampNs = 1000,
}) =>
    CapturedPhotoRecord(
      segmentIndex: segmentIndex,
      framePath: framePath,
      blurScore: blurScore,
      meanLuminance: meanLuminance,
      yawDegrees: yawDegrees,
      pitchDegrees: pitchDegrees,
      sensorTimestampNs: sensorTimestampNs,
    );

WarnedPhotoRecord makeWarned({String framePath = '/tmp/f1.jpg'}) =>
    WarnedPhotoRecord(
      framePath: framePath,
      isUnderexposed: true,
      isOverexposed: false,
      meanLuminance: 30,
      sensorTimestampNs: 1000,
    );

RejectedPhotoRecord makeRejected({
  PhotoRejectionReason reason = PhotoRejectionReason.blur,
  String? framePath,
  double? blurScore,
  double? stabilityScore,
}) =>
    RejectedPhotoRecord(
      reason: reason,
      framePath: framePath,
      blurScore: blurScore,
      stabilityScore: stabilityScore,
      yawDegrees: 0,
      sensorTimestampNs: 1000,
    );

CaptureSessionState sampleState({
  String projectId = 'p1',
  String levelId = 'mid',
  int segmentCount = 12,
  int fillThreshold = 1,
  List<int>? fillCounts,
  int position = 0,
  List<CapturedPhotoRecord>? accepted,
  List<WarnedPhotoRecord>? warned,
  List<RejectedPhotoRecord>? rejected,
  int savedAtMs = 1700000000000,
}) =>
    CaptureSessionState(
      projectId: projectId,
      levelId: levelId,
      segmentCount: segmentCount,
      fillThreshold: fillThreshold,
      fillCounts: fillCounts ?? List<int>.filled(segmentCount, 0),
      position: position,
      accepted: accepted ?? const [],
      warned: warned ?? const [],
      rejected: rejected ?? const [],
      savedAtMs: savedAtMs,
    );

void main() {
  group('capture() from live state', () {
    test('reflects SegmentCoverage fill state', () {
      var cov = SegmentCoverage.initial(segmentCount: 4);
      cov = cov.recordCapture(0).recordCapture(2);
      final snap = CaptureSessionCodec.capture(
        projectId: 'p1',
        levelId: 'mid',
        coverage: cov,
        ledger: LevelCaptureLedger(),
        savedAtMs: 123,
      );
      expect(snap.segmentCount, 4);
      expect(snap.fillCounts, [1, 0, 1, 0]);
    });

    test('reflects ledger accepted/warned/rejected', () {
      final ledger = LevelCaptureLedger()
        ..recordAccepted(makeAccepted())
        ..recordWarned(makeWarned())
        ..recordRejected(makeRejected());
      final snap = CaptureSessionCodec.capture(
        projectId: 'p1',
        levelId: 'mid',
        coverage: SegmentCoverage.initial(segmentCount: 4),
        ledger: ledger,
        savedAtMs: 1,
      );
      expect(snap.accepted.length, 1);
      expect(snap.warned.length, 1);
      expect(snap.rejected.length, 1);
    });

    test('does not mutate the source coverage or ledger', () {
      var cov = SegmentCoverage.initial(segmentCount: 4).recordCapture(0);
      final ledger = LevelCaptureLedger()..recordAccepted(makeAccepted());
      CaptureSessionCodec.capture(
          projectId: 'p1', levelId: 'mid', coverage: cov, ledger: ledger, savedAtMs: 1);
      CaptureSessionCodec.capture(
          projectId: 'p1', levelId: 'mid', coverage: cov, ledger: ledger, savedAtMs: 1);
      expect(cov.fillCounts, [1, 0, 0, 0]);
      expect(ledger.accepted.length, 1);
    });
  });

  group('toJson / fromJson round-trip', () {
    test('preserves scalars (projectId, levelId, counts, savedAtMs)', () {
      final s = sampleState(
          projectId: 'proj', levelId: 'mid', segmentCount: 12, savedAtMs: 999);
      final back = CaptureSessionCodec.fromJson(CaptureSessionCodec.toJson(s));
      expect(back.projectId, 'proj');
      expect(back.levelId, 'mid');
      expect(back.segmentCount, 12);
      expect(back.savedAtMs, 999);
    });

    test('preserves the fill pattern exactly (incl fillThreshold/position)', () {
      final counts = [3, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 0];
      final s = sampleState(
          segmentCount: 12, fillThreshold: 3, fillCounts: counts, position: 7);
      final back = CaptureSessionCodec.fromJson(CaptureSessionCodec.toJson(s));
      expect(back.fillCounts, counts);
      expect(back.fillThreshold, 3);
      expect(back.position, 7);
    });

    test('preserves accepted list contents AND order (incl segmentIndex)', () {
      final s = sampleState(accepted: [
        makeAccepted(segmentIndex: 5, framePath: 'a.jpg'),
        makeAccepted(segmentIndex: 6, framePath: 'b.jpg'),
        makeAccepted(segmentIndex: 7, framePath: 'c.jpg'),
      ]);
      final back = CaptureSessionCodec.fromJson(CaptureSessionCodec.toJson(s));
      expect(back.accepted, s.accepted); // value equality, order preserved
      // Grounded: segmentIndex survives (the brief had to null it out).
      expect(back.accepted.first.segmentIndex, 5);
    });

    test('preserves warned list exactly', () {
      final s = sampleState(warned: [makeWarned(framePath: 'w.jpg')]);
      final back = CaptureSessionCodec.fromJson(CaptureSessionCodec.toJson(s));
      expect(back.warned, s.warned);
    });

    test('preserves rejected with null framePath/blur/stability (overlap)', () {
      final s = sampleState(rejected: [
        makeRejected(reason: PhotoRejectionReason.overlap),
      ]);
      final back = CaptureSessionCodec.fromJson(CaptureSessionCodec.toJson(s));
      expect(back.rejected.first.framePath, isNull);
      expect(back.rejected.first.blurScore, isNull);
      expect(back.rejected.first.stabilityScore, isNull);
      expect(back.rejected, s.rejected);
    });

    test('preserves a blur rejection non-null blurScore', () {
      final s = sampleState(rejected: [
        makeRejected(
            reason: PhotoRejectionReason.blur, framePath: 'r.jpg', blurScore: 12.5),
      ]);
      final back = CaptureSessionCodec.fromJson(CaptureSessionCodec.toJson(s));
      expect(back.rejected.first.blurScore, 12.5);
    });

    test('preserves a motion rejection non-null stabilityScore', () {
      final s = sampleState(rejected: [
        makeRejected(reason: PhotoRejectionReason.motion, stabilityScore: 0.3),
      ]);
      final back = CaptureSessionCodec.fromJson(CaptureSessionCodec.toJson(s));
      expect(back.rejected.first.stabilityScore, 0.3);
    });

    test('empty lists round-trip without throwing', () {
      final back = CaptureSessionCodec.fromJson(
          CaptureSessionCodec.toJson(sampleState()));
      expect(back.accepted, isEmpty);
      expect(back.warned, isEmpty);
      expect(back.rejected, isEmpty);
    });

    test('all three PhotoRejectionReason values survive', () {
      for (final reason in PhotoRejectionReason.values) {
        final s = sampleState(rejected: [makeRejected(reason: reason)]);
        final back =
            CaptureSessionCodec.fromJson(CaptureSessionCodec.toJson(s));
        expect(back.rejected.first.reason, reason);
      }
    });

    test('whole snapshot is value-equal after round-trip', () {
      final s = sampleState(
        segmentCount: 12,
        fillThreshold: 2,
        fillCounts: [2, 0, 1, 2, 0, 0, 0, 0, 0, 0, 0, 2],
        position: 3,
        accepted: [makeAccepted(segmentIndex: 0), makeAccepted(segmentIndex: 3)],
        warned: [makeWarned()],
        rejected: [makeRejected(reason: PhotoRejectionReason.overlap)],
      );
      expect(CaptureSessionCodec.fromJson(CaptureSessionCodec.toJson(s)), s);
    });
  });

  group('fromJson error handling', () {
    Map<String, dynamic> validMap() => CaptureSessionCodec.toJson(sampleState());

    test('missing project_id throws', () {
      final m = validMap()..remove(CaptureSessionKeys.projectId);
      expect(() => CaptureSessionCodec.fromJson(m),
          throwsA(isA<CaptureSessionParseException>()));
    });

    test('missing fill_counts throws', () {
      final m = validMap()..remove(CaptureSessionKeys.fillCounts);
      expect(() => CaptureSessionCodec.fromJson(m),
          throwsA(isA<CaptureSessionParseException>()));
    });

    test('non-string level_id throws', () {
      final m = validMap()..[CaptureSessionKeys.levelId] = 42;
      expect(() => CaptureSessionCodec.fromJson(m),
          throwsA(isA<CaptureSessionParseException>()));
    });

    test('unknown PhotoRejectionReason throws', () {
      final m = validMap();
      m[CaptureSessionKeys.rejected] = [
        {
          CaptureSessionKeys.reason: 'not_a_reason',
          CaptureSessionKeys.framePath: null,
          CaptureSessionKeys.blurScore: null,
          CaptureSessionKeys.stabilityScore: null,
          CaptureSessionKeys.yawDegrees: 0.0,
          CaptureSessionKeys.sensorTimestampNs: 1,
        }
      ];
      expect(
        () => CaptureSessionCodec.fromJson(m),
        throwsA(predicate((e) =>
            e is CaptureSessionParseException &&
            e.message.contains('Unknown PhotoRejectionReason'))),
      );
    });

    test('non-List fill_counts throws', () {
      final m = validMap()..[CaptureSessionKeys.fillCounts] = 'nope';
      expect(() => CaptureSessionCodec.fromJson(m),
          throwsA(isA<CaptureSessionParseException>()));
    });

    test('wrong type for segment_count (String) throws', () {
      final m = validMap()..[CaptureSessionKeys.segmentCount] = 'twelve';
      expect(() => CaptureSessionCodec.fromJson(m),
          throwsA(isA<CaptureSessionParseException>()));
    });

    test('int values for double fields are coerced without throwing', () {
      final m = CaptureSessionCodec.toJson(
          sampleState(accepted: [makeAccepted()]));
      // Force an int in a double slot (JSON may store 80 not 80.0).
      (m[CaptureSessionKeys.accepted] as List).first[CaptureSessionKeys.blurScore] =
          80;
      final back = CaptureSessionCodec.fromJson(m);
      expect(back.accepted.first.blurScore, 80.0);
    });
  });

  group('restoreCoverage / restoreLedger', () {
    test('restoreCoverage rebuilds exact fill state', () {
      final s = sampleState(
          segmentCount: 4, fillThreshold: 2, fillCounts: [2, 0, 1, 2], position: 3);
      final cov = CaptureSessionCodec.restoreCoverage(s);
      expect(cov.fillCounts, [2, 0, 1, 2]);
      expect(cov.fillThreshold, 2);
      expect(cov.position, 3);
      expect(cov.filledCount, 2); // segments 0 and 3 reached threshold 2
    });

    test('restoreLedger resets then replays (no stale state survives)', () {
      final ledger = LevelCaptureLedger()
        ..recordAccepted(makeAccepted(framePath: 'stale.jpg'));
      final s = sampleState(accepted: [makeAccepted(framePath: 'fresh.jpg')]);
      CaptureSessionCodec.restoreLedger(s, ledger);
      expect(ledger.accepted.length, 1);
      expect(ledger.accepted.first.framePath, 'fresh.jpg');
    });

    test('restoreLedger populates all three lists', () {
      final ledger = LevelCaptureLedger();
      final s = sampleState(
        accepted: [makeAccepted()],
        warned: [makeWarned()],
        rejected: [makeRejected()],
      );
      CaptureSessionCodec.restoreLedger(s, ledger);
      expect(ledger.accepted.length, 1);
      expect(ledger.warned.length, 1);
      expect(ledger.rejected.length, 1);
    });

    test('restoreCoverage throws on segmentCount mismatch when expected given', () {
      final s = sampleState(segmentCount: 12);
      expect(
        () => CaptureSessionCodec.restoreCoverage(s, expectedSegmentCount: 8),
        throwsA(predicate((e) =>
            e is CaptureSessionParseException &&
            e.message.contains('segmentCount mismatch'))),
      );
    });

    test('restoreCoverage succeeds when expected matches', () {
      final s = sampleState(segmentCount: 12);
      final cov = CaptureSessionCodec.restoreCoverage(s, expectedSegmentCount: 12);
      expect(cov.segmentCount, 12);
    });
  });

  group('full cycle: capture → toJson → fromJson → restore', () {
    test('reproduces equivalent fill state and ledger contents', () {
      // Live: 4 of 12 segments filled, 4 accepted, 2 warned, 1 rejected.
      var cov = SegmentCoverage.initial(segmentCount: 12);
      for (final i in [0, 3, 6, 9]) {
        cov = cov.recordCapture(i);
      }
      final ledger = LevelCaptureLedger()
        ..recordAccepted(makeAccepted(segmentIndex: 0, framePath: 'a.jpg'))
        ..recordAccepted(makeAccepted(segmentIndex: 3, framePath: 'b.jpg'))
        ..recordAccepted(makeAccepted(segmentIndex: 6, framePath: 'c.jpg'))
        ..recordAccepted(makeAccepted(segmentIndex: 9, framePath: 'd.jpg'))
        ..recordWarned(makeWarned(framePath: 'a.jpg'))
        ..recordWarned(makeWarned(framePath: 'b.jpg'))
        ..recordRejected(makeRejected(reason: PhotoRejectionReason.overlap));

      final snap = CaptureSessionCodec.capture(
          projectId: 'p1', levelId: 'mid', coverage: cov, ledger: ledger, savedAtMs: 7);
      final decoded =
          CaptureSessionCodec.fromJson(CaptureSessionCodec.toJson(snap));

      final restoredCov = CaptureSessionCodec.restoreCoverage(decoded);
      final restoredLedger = LevelCaptureLedger();
      CaptureSessionCodec.restoreLedger(decoded, restoredLedger);

      expect(restoredCov.fillCounts, cov.fillCounts);
      expect(restoredCov.filledCount, 4);
      expect(restoredLedger.accepted, ledger.accepted);
      expect(restoredLedger.warned, ledger.warned);
      expect(restoredLedger.rejected, ledger.rejected);
    });
  });
}
