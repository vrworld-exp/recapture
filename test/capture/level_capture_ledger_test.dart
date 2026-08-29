// test/capture/level_capture_ledger_test.dart
//
// Tests the per-level capture ledger + registry: record construction/equality,
// list mutation + immutability, warned/accepted overlap, summary counts, reset,
// and per-level isolation. Grounded API: segment is an int index, angles are
// degrees, sensor time is ns, the registry is keyed by PitchBand.id string.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/capture/ledger/captured_photo_record.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger_registry.dart';
import 'package:recapture/application/capture/ledger/photo_rejection_reason.dart';
import 'package:recapture/application/capture/ledger/rejected_photo_record.dart';
import 'package:recapture/application/capture/ledger/warned_photo_record.dart';

CapturedPhotoRecord makeAccepted({
  int? segmentIndex = 0,
  String framePath = '/tmp/frame_001.jpg',
  double blurScore = 80.0,
  double meanLuminance = 128.0,
  double yawDegrees = 0.0,
  double pitchDegrees = 45.0,
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

WarnedPhotoRecord makeWarned({
  String framePath = '/tmp/frame_001.jpg',
  bool isUnderexposed = true,
  bool isOverexposed = false,
  double meanLuminance = 30.0,
  int sensorTimestampNs = 1000,
}) =>
    WarnedPhotoRecord(
      framePath: framePath,
      isUnderexposed: isUnderexposed,
      isOverexposed: isOverexposed,
      meanLuminance: meanLuminance,
      sensorTimestampNs: sensorTimestampNs,
    );

RejectedPhotoRecord makeRejected({
  PhotoRejectionReason reason = PhotoRejectionReason.blur,
  String? framePath,
  double? blurScore,
  double? stabilityScore,
  double yawDegrees = 0.0,
  int sensorTimestampNs = 1000,
}) =>
    RejectedPhotoRecord(
      reason: reason,
      framePath: framePath,
      blurScore: blurScore,
      stabilityScore: stabilityScore,
      yawDegrees: yawDegrees,
      sensorTimestampNs: sensorTimestampNs,
    );

void main() {
  group('Value type construction and equality', () {
    test('CapturedPhotoRecord — identical fields are ==', () {
      expect(makeAccepted(), equals(makeAccepted()));
      expect(makeAccepted().hashCode, makeAccepted().hashCode);
    });

    test('CapturedPhotoRecord — differing framePath are !=', () {
      expect(makeAccepted(framePath: 'a.jpg'),
          isNot(equals(makeAccepted(framePath: 'b.jpg'))));
    });

    test('WarnedPhotoRecord — identical fields are ==', () {
      expect(makeWarned(), equals(makeWarned()));
    });

    test('RejectedPhotoRecord — identical fields are ==', () {
      expect(makeRejected(), equals(makeRejected()));
    });

    test('RejectedPhotoRecord with null framePath constructs (overlap case)', () {
      const r = RejectedPhotoRecord(
        reason: PhotoRejectionReason.overlap,
        yawDegrees: 0.0,
        sensorTimestampNs: 0,
      );
      expect(r.framePath, isNull);
    });

    test('RejectedPhotoRecord with null blur+stability scores constructs', () {
      const r = RejectedPhotoRecord(
        reason: PhotoRejectionReason.overlap,
        yawDegrees: 0.0,
        sensorTimestampNs: 0,
      );
      expect(r.blurScore, isNull);
      expect(r.stabilityScore, isNull);
    });

    test('records are const-constructible', () {
      const a = CapturedPhotoRecord(
        segmentIndex: 0,
        framePath: '/x.jpg',
        blurScore: 80,
        meanLuminance: 128,
        yawDegrees: 0,
        pitchDegrees: 45,
        sensorTimestampNs: 1,
      );
      const w = WarnedPhotoRecord(
        framePath: '/x.jpg',
        isUnderexposed: true,
        isOverexposed: false,
        meanLuminance: 30,
        sensorTimestampNs: 1,
      );
      expect(a.segmentIndex, 0);
      expect(w.isUnderexposed, isTrue);
    });
  });

  group('LevelCaptureLedger — recording', () {
    test('new ledger has empty lists', () {
      final l = LevelCaptureLedger();
      expect(l.accepted, isEmpty);
      expect(l.warned, isEmpty);
      expect(l.rejected, isEmpty);
    });

    test('recordAccepted adds one to accepted', () {
      final l = LevelCaptureLedger()..recordAccepted(makeAccepted());
      expect(l.accepted.length, 1);
    });

    test('recordAccepted does not affect warned/rejected', () {
      final l = LevelCaptureLedger()..recordAccepted(makeAccepted());
      expect(l.warned, isEmpty);
      expect(l.rejected, isEmpty);
    });

    test('recordWarned adds one to warned', () {
      final l = LevelCaptureLedger()..recordWarned(makeWarned());
      expect(l.warned.length, 1);
    });

    test('recordWarned does not affect accepted/rejected', () {
      final l = LevelCaptureLedger()..recordWarned(makeWarned());
      expect(l.accepted, isEmpty);
      expect(l.rejected, isEmpty);
    });

    test('recordRejected adds one to rejected', () {
      final l = LevelCaptureLedger()..recordRejected(makeRejected());
      expect(l.rejected.length, 1);
    });

    test('recordRejected does not affect accepted/warned', () {
      final l = LevelCaptureLedger()..recordRejected(makeRejected());
      expect(l.accepted, isEmpty);
      expect(l.warned, isEmpty);
    });

    test('multiple recordAccepted preserve insertion order', () {
      final a = makeAccepted(framePath: 'a.jpg');
      final b = makeAccepted(framePath: 'b.jpg');
      final c = makeAccepted(framePath: 'c.jpg');
      final l = LevelCaptureLedger()
        ..recordAccepted(a)
        ..recordAccepted(b)
        ..recordAccepted(c);
      expect(l.accepted, [a, b, c]);
    });
  });

  group('LevelCaptureLedger — lists are unmodifiable', () {
    test('accepted getter is unmodifiable', () {
      final l = LevelCaptureLedger();
      expect(() => l.accepted.add(makeAccepted()), throwsUnsupportedError);
    });

    test('warned getter is unmodifiable', () {
      final l = LevelCaptureLedger();
      expect(() => l.warned.add(makeWarned()), throwsUnsupportedError);
    });

    test('rejected getter is unmodifiable', () {
      final l = LevelCaptureLedger();
      expect(() => l.rejected.add(makeRejected()), throwsUnsupportedError);
    });
  });

  group('LevelCaptureLedger — warned/accepted overlap', () {
    test('a photo can appear in both accepted and warned', () {
      final l = LevelCaptureLedger()
        ..recordAccepted(makeAccepted(framePath: 'f.jpg'))
        ..recordWarned(makeWarned(framePath: 'f.jpg'));
      expect(l.accepted.length, 1);
      expect(l.warned.length, 1);
    });

    test('hasAcceptedPhotosWithWarnings true when framePaths match', () {
      final l = LevelCaptureLedger()
        ..recordAccepted(makeAccepted(framePath: 'f.jpg'))
        ..recordWarned(makeWarned(framePath: 'f.jpg'));
      expect(l.hasAcceptedPhotosWithWarnings, isTrue);
    });

    test('false when no framePaths match', () {
      final l = LevelCaptureLedger()
        ..recordAccepted(makeAccepted(framePath: 'a.jpg'))
        ..recordWarned(makeWarned(framePath: 'b.jpg'));
      expect(l.hasAcceptedPhotosWithWarnings, isFalse);
    });

    test('false when accepted list is empty', () {
      final l = LevelCaptureLedger()..recordWarned(makeWarned());
      expect(l.hasAcceptedPhotosWithWarnings, isFalse);
    });
  });

  group('LevelCaptureLedger — summary queries', () {
    test('totalAttempts sums accepted + rejected, EXCLUDES warned', () {
      final l = LevelCaptureLedger()
        ..recordAccepted(makeAccepted(framePath: 'a.jpg'))
        ..recordAccepted(makeAccepted(framePath: 'b.jpg'))
        ..recordWarned(makeWarned())
        ..recordRejected(makeRejected())
        ..recordRejected(makeRejected(reason: PhotoRejectionReason.motion))
        ..recordRejected(makeRejected(reason: PhotoRejectionReason.overlap));
      // 2 accepted + 3 rejected = 5; the 1 warned is deliberately NOT counted.
      expect(l.totalAttempts, 5);
    });

    test('totalAttempts is 0 for a fresh ledger', () {
      expect(LevelCaptureLedger().totalAttempts, 0);
    });

    test('rejectedCountFor(blur) counts only blur rejections', () {
      final l = LevelCaptureLedger()
        ..recordRejected(makeRejected(reason: PhotoRejectionReason.blur))
        ..recordRejected(makeRejected(reason: PhotoRejectionReason.blur))
        ..recordRejected(makeRejected(reason: PhotoRejectionReason.motion));
      expect(l.rejectedCountFor(PhotoRejectionReason.blur), 2);
    });

    test('rejectedCountFor(motion) counts only motion rejections', () {
      final l = LevelCaptureLedger()
        ..recordRejected(makeRejected(reason: PhotoRejectionReason.motion))
        ..recordRejected(makeRejected(reason: PhotoRejectionReason.blur));
      expect(l.rejectedCountFor(PhotoRejectionReason.motion), 1);
    });

    test('rejectedCountFor(overlap) counts only overlap rejections', () {
      final l = LevelCaptureLedger()
        ..recordRejected(makeRejected(reason: PhotoRejectionReason.overlap))
        ..recordRejected(makeRejected(reason: PhotoRejectionReason.overlap));
      expect(l.rejectedCountFor(PhotoRejectionReason.overlap), 2);
    });

    test('rejectedCountFor returns 0 with no matching records', () {
      final l = LevelCaptureLedger()
        ..recordRejected(makeRejected(reason: PhotoRejectionReason.blur));
      expect(l.rejectedCountFor(PhotoRejectionReason.overlap), 0);
    });
  });

  group('LevelCaptureLedger — reset', () {
    test('reset clears all three lists', () {
      final l = LevelCaptureLedger()
        ..recordAccepted(makeAccepted())
        ..recordWarned(makeWarned())
        ..recordRejected(makeRejected())
        ..reset();
      expect(l.accepted, isEmpty);
      expect(l.warned, isEmpty);
      expect(l.rejected, isEmpty);
    });

    test('reset allows reuse without accumulating', () {
      final l = LevelCaptureLedger()
        ..recordAccepted(makeAccepted())
        ..reset()
        ..recordAccepted(makeAccepted());
      expect(l.accepted.length, 1);
    });
  });

  group('LevelCaptureLedgerRegistry', () {
    // Real PitchBand.ids: 'mid' = Level A (Eye Ring), 'low'/'high' = other bands.
    test('ledgerFor creates a ledger on first access', () {
      final r = LevelCaptureLedgerRegistry();
      expect(r.hasLedgerFor('mid'), isFalse);
      r.ledgerFor('mid');
      expect(r.hasLedgerFor('mid'), isTrue);
    });

    test('ledgerFor returns the same instance on repeated calls', () {
      final r = LevelCaptureLedgerRegistry();
      expect(identical(r.ledgerFor('mid'), r.ledgerFor('mid')), isTrue);
    });

    test('ledgers for different levels are independent', () {
      final r = LevelCaptureLedgerRegistry();
      r.ledgerFor('mid').recordAccepted(makeAccepted());
      expect(r.ledgerFor('high').accepted, isEmpty);
    });

    test('resetLevel only resets the specified level', () {
      final r = LevelCaptureLedgerRegistry();
      r.ledgerFor('mid').recordAccepted(makeAccepted());
      r.ledgerFor('high').recordAccepted(makeAccepted());
      r.resetLevel('mid');
      expect(r.ledgerFor('mid').accepted, isEmpty);
      expect(r.ledgerFor('high').accepted.length, 1);
    });

    test('resetAll resets every created ledger', () {
      final r = LevelCaptureLedgerRegistry();
      r.ledgerFor('mid').recordAccepted(makeAccepted());
      r.ledgerFor('high').recordAccepted(makeAccepted());
      r.ledgerFor('low').recordAccepted(makeAccepted());
      r.resetAll();
      expect(r.ledgerFor('mid').accepted, isEmpty);
      expect(r.ledgerFor('high').accepted, isEmpty);
      expect(r.ledgerFor('low').accepted, isEmpty);
    });

    test('clearLevel removes the ledger; ledgerFor recreates a fresh one', () {
      final r = LevelCaptureLedgerRegistry();
      r.ledgerFor('mid').recordAccepted(makeAccepted());
      r.clearLevel('mid');
      expect(r.hasLedgerFor('mid'), isFalse);
      expect(r.ledgerFor('mid').accepted, isEmpty);
    });

    test('resetLevel on an untouched level does not throw', () {
      final r = LevelCaptureLedgerRegistry();
      expect(() => r.resetLevel('mid'), returnsNormally);
    });

    test('resetAll on an empty registry does not throw', () {
      expect(() => LevelCaptureLedgerRegistry().resetAll(), returnsNormally);
    });
  });

  // The capture-run boundary: the ledgers are app-scoped, so a second capture
  // must not review the first object's frames alongside its own.
  group('LevelCaptureLedgerRegistry run ownership', () {
    test('a fresh registry is bound to no project', () {
      expect(LevelCaptureLedgerRegistry().projectId, isNull);
    });

    test('bindProject records the project without wiping on first bind', () {
      final r = LevelCaptureLedgerRegistry();
      expect(r.bindProject('p1'), isFalse);
      expect(r.projectId, 'p1');
    });

    test('re-binding the SAME project keeps the pass (resume)', () {
      final r = LevelCaptureLedgerRegistry();
      r.bindProject('p1');
      r.ledgerFor('mid').recordAccepted(makeAccepted());
      expect(r.bindProject('p1'), isFalse);
      expect(r.ledgerFor('mid').accepted.length, 1);
    });

    test('binding a DIFFERENT project wipes every level', () {
      final r = LevelCaptureLedgerRegistry();
      r.bindProject('p1');
      r.ledgerFor('mid').recordAccepted(makeAccepted());
      r.ledgerFor('high').recordAccepted(makeAccepted());
      r.ledgerFor('mid').recordWarned(makeWarned());
      r.ledgerFor('mid').recordRejected(makeRejected());

      expect(r.bindProject('p2'), isTrue);

      expect(r.projectId, 'p2');
      expect(r.ledgerFor('mid').accepted, isEmpty);
      expect(r.ledgerFor('mid').warned, isEmpty);
      expect(r.ledgerFor('mid').rejected, isEmpty);
      expect(r.ledgerFor('high').accepted, isEmpty);
    });

    test('an empty project id never wipes a bound run', () {
      final r = LevelCaptureLedgerRegistry();
      r.bindProject('p1');
      r.ledgerFor('mid').recordAccepted(makeAccepted());
      expect(r.bindProject(''), isFalse);
      expect(r.projectId, 'p1');
      expect(r.ledgerFor('mid').accepted.length, 1);
    });

    test('endRun resets every ledger and unbinds the project', () {
      final r = LevelCaptureLedgerRegistry();
      r.bindProject('p1');
      r.ledgerFor('mid').recordAccepted(makeAccepted());
      r.ledgerFor('high').recordAccepted(makeAccepted());

      r.endRun();

      expect(r.projectId, isNull);
      expect(r.ledgerFor('mid').accepted, isEmpty);
      expect(r.ledgerFor('high').accepted, isEmpty);
    });

    test('after endRun the same project rebinds without wiping', () {
      final r = LevelCaptureLedgerRegistry();
      r.bindProject('p1');
      r.endRun();
      expect(r.bindProject('p1'), isFalse);
      expect(r.projectId, 'p1');
    });

    test('endRun on an unbound registry does not throw', () {
      expect(() => LevelCaptureLedgerRegistry().endRun(), returnsNormally);
    });
  });
}
