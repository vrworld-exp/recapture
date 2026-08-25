// test/capture/session/save_exit_resume_test.dart
//
// QA INVARIANT: Save & Exit → Resume is LOSSLESS. After saving a partially-
// completed Level A session and exiting, resuming restores the EXACT capture
// state — filled segment indices, per-segment verdicts, photo references, ring
// coverage %, and the active/next target — so the user continues precisely where
// they left off. Discard & Exit, by contrast, restores nothing (negative control).
//
// HERMETIC: the REAL persistence is exercised — `CaptureSessionStore` against a
// temp Hive dir (NOT faked, per the task) + the real `CaptureSessionCodec` that
// captures from / restores into the real `SegmentCoverage` + `LevelCaptureLedger`.
// No camera, sensors, or real files; the HUD widgets (ring map + progress meter)
// are pumped with the restored state with deterministic fake photo refs.
//
// ─────────────────────────────────────────────────────────────────────────────
// FLAGGED GAP (no production change made): the capture screen's exit handler
// (`CaptureScreen._handleExitChoice`) currently has `// TODO(capture): persist...`
// / `discard...` — it does NOT yet call the store on Save/Discard, and resume is
// not wired into the screen. This test pins the lossless-resume CONTRACT against
// the real persistence layer that already exists (store + codec), driven by the
// real `SaveExitChoice`, via a small `_applyExit` / `_resume` harness that encodes
// exactly what that screen wiring must do. When the wiring lands, these assertions
// are what an end-to-end CaptureScreen test should also hold.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:recapture/application/capture/ledger/captured_photo_record.dart';
import 'package:recapture/application/capture/ledger/level_capture_ledger.dart';
import 'package:recapture/application/capture/ledger/photo_rejection_reason.dart';
import 'package:recapture/application/capture/ledger/rejected_photo_record.dart';
import 'package:recapture/application/capture/ledger/warned_photo_record.dart';
import 'package:recapture/application/capture/session/capture_session_codec.dart';
import 'package:recapture/application/capture/session/capture_session_store.dart';
import 'package:recapture/data/local/box_names.dart';
import 'package:recapture/domain/entities/capture_progress.dart';
import 'package:recapture/domain/entities/ring_coverage.dart';
import 'package:recapture/domain/entities/save_exit_decision.dart';
import 'package:recapture/domain/entities/segment_coverage.dart';
import 'package:recapture/presentation/widgets/progress_meter.dart';
import 'package:recapture/presentation/widgets/ring_coverage_map.dart';

const _projectId = 'proj-1';
const _levelId = 'mid'; // Level A Eye Ring
const _n = 6; // small fixed ring
const _savedAtMs = 1700000000000;

/// A segment's restored verdict, derived from the ledger: a warned-but-kept photo
/// (its framePath also appears in `warned`) vs a clean accept.
enum _SegmentVerdict { accepted, warned }

CapturedPhotoRecord _acc(int seg, String path) => CapturedPhotoRecord(
      segmentIndex: seg,
      framePath: path,
      blurScore: 90,
      meanLuminance: 128,
      yawDegrees: seg * 60.0,
      pitchDegrees: 45,
      sensorTimestampNs: 1000 + seg,
    );

WarnedPhotoRecord _warn(String path) => WarnedPhotoRecord(
      framePath: path,
      isUnderexposed: true,
      isOverexposed: false,
      meanLuminance: 30,
      sensorTimestampNs: 2000,
    );

/// A faithful partial Level A session: filled {0,1,3} of 6 (NON-CONTIGUOUS),
/// user at segment 1; segment 1's photo is warn-kept (mixed verdicts); plus one
/// rejected attempt (telemetry that must also survive).
({SegmentCoverage coverage, LevelCaptureLedger ledger}) _buildPartial() {
  var coverage = SegmentCoverage.initial(segmentCount: _n)
      .recordCapture(0)
      .recordCapture(1)
      .recordCapture(3)
      .updatePosition(1);
  final ledger = LevelCaptureLedger()
    ..recordAccepted(_acc(0, 'p0.jpg'))
    ..recordAccepted(_acc(1, 'p1.jpg'))
    ..recordAccepted(_acc(3, 'p3.jpg'))
    ..recordWarned(_warn('p1.jpg')) // segment 1 = warn-kept
    ..recordRejected(const RejectedPhotoRecord(
      reason: PhotoRejectionReason.blur,
      framePath: 'r.jpg',
      blurScore: 12,
      stabilityScore: null,
      yawDegrees: 120,
      sensorTimestampNs: 3000,
    ));
  return (coverage: coverage, ledger: ledger);
}

/// What the capture screen's exit handler MUST do per choice (the wiring this test
/// pins): Save&Exit persists the snapshot; Discard&Exit clears any resumable
/// session; Cancel leaves persistence untouched.
Future<void> _applyExit(
  SaveExitChoice choice,
  CaptureSessionStore store, {
  required SegmentCoverage coverage,
  required LevelCaptureLedger ledger,
}) async {
  switch (choice) {
    case SaveExitChoice.saveExit:
      await store.save(CaptureSessionCodec.capture(
        projectId: _projectId,
        levelId: _levelId,
        coverage: coverage,
        ledger: ledger,
        savedAtMs: _savedAtMs,
      ));
    case SaveExitChoice.discardExit:
      await store.clear(_projectId, _levelId);
    case SaveExitChoice.cancel:
      break; // stay; nothing persisted/cleared
  }
}

/// What Resume MUST do: load the snapshot and rebuild the runtime state; absent or
/// corrupt → a FRESH empty session (never a crash).
Future<({SegmentCoverage coverage, LevelCaptureLedger ledger})> _resume(
  CaptureSessionStore store, {
  int expectedSegmentCount = _n,
}) async {
  final snap = await store.load(_projectId, _levelId);
  if (snap == null) {
    return (
      coverage: SegmentCoverage.initial(segmentCount: expectedSegmentCount),
      ledger: LevelCaptureLedger(),
    );
  }
  final coverage = CaptureSessionCodec.restoreCoverage(snap,
      expectedSegmentCount: expectedSegmentCount);
  final ledger = LevelCaptureLedger();
  CaptureSessionCodec.restoreLedger(snap, ledger);
  return (coverage: coverage, ledger: ledger);
}

Set<int> _filledIndices(SegmentCoverage c) => {
      for (var i = 0; i < c.segmentCount; i++)
        if (c.filled[i]) i,
    };

Map<int, _SegmentVerdict> _verdictBySegment(LevelCaptureLedger l) {
  final warnedPaths = l.warned.map((w) => w.framePath).toSet();
  return {
    for (final a in l.accepted)
      if (a.segmentIndex != null)
        a.segmentIndex!: warnedPaths.contains(a.framePath)
            ? _SegmentVerdict.warned
            : _SegmentVerdict.accepted,
  };
}

void main() {
  late Directory tempDir;
  late CaptureSessionStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('save_exit_resume_hive_');
    Hive.init(tempDir.path);
    store = CaptureSessionStore();
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('Save & Exit → Resume restores the exact state', () {
    test('filled indices, verdicts, photo refs, coverage %, and target', () async {
      final partial = _buildPartial();
      // Snapshot the pre-exit truth.
      final expectedFilled = _filledIndices(partial.coverage); // {0,1,3}
      final expectedTarget = partial.coverage.currentTarget; // 2
      final expectedProgress = partial.coverage.progress; // 0.5

      await _applyExit(SaveExitChoice.saveExit, store,
          coverage: partial.coverage, ledger: partial.ledger);
      expect(await store.hasSession(_projectId, _levelId), isTrue,
          reason: 'a resumable session was persisted');

      final resumed = await _resume(store);

      // Ring coverage — exact filled set + counts + position.
      expect(_filledIndices(resumed.coverage), {0, 1, 3});
      expect(_filledIndices(resumed.coverage), expectedFilled);
      expect(resumed.coverage.fillCounts, partial.coverage.fillCounts);
      expect(resumed.coverage.missingSegments, [2, 4, 5],
          reason: 'gaps preserved');
      // Coverage % consistent with pre-exit.
      expect(resumed.coverage.progress, expectedProgress);
      expect((resumed.coverage.progress * 100).round(), 50);
      // Active/next target preserved (so guidance continues correctly).
      expect(resumed.coverage.currentTarget, 2);
      expect(resumed.coverage.currentTarget, expectedTarget);

      // Photo references — same ids/paths, same count, order preserved, no dupes.
      expect(resumed.ledger.accepted, partial.ledger.accepted);
      expect(resumed.ledger.accepted.map((r) => r.framePath).toList(),
          ['p0.jpg', 'p1.jpg', 'p3.jpg']);
      expect(resumed.ledger.warned, partial.ledger.warned);
      expect(resumed.ledger.rejected, partial.ledger.rejected,
          reason: 'rejected telemetry survives too');

      // Per-segment verdicts (mixed: seg 1 warn-kept, seg 0/3 clean accept).
      expect(_verdictBySegment(resumed.ledger), {
        0: _SegmentVerdict.accepted,
        1: _SegmentVerdict.warned,
        3: _SegmentVerdict.accepted,
      });
    });

    testWidgets('ring map + progress meter reflect the restored state',
        (tester) async {
      // Hive IO must run OUTSIDE the widget fake-async zone (real file IO never
      // resolves under pump()) — drive the store round-trip via runAsync, then
      // pump the HUD with the restored state.
      late RingCoverage ring;
      late CaptureProgress progress;
      await tester.runAsync(() async {
        final p = _buildPartial();
        await _applyExit(SaveExitChoice.saveExit, store,
            coverage: p.coverage, ledger: p.ledger);
        final resumed = await _resume(store);
        ring = resumed.coverage.toRingCoverage(); // filled {0,1,3}, target 2
        progress = CaptureProgress.fromCoverage(ring, completeAtPct: 80);
      });

      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: Stack(children: [
              RingCoverageMap(coverage: ring),
              ProgressMeter(progress: progress),
            ]),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // Ring map readout = filled/total; per-segment state faithful (the painter
      // consumes RingCoverage.stateOf directly).
      expect(find.text('3/6'), findsOneWidget);
      for (final i in [0, 1, 3]) {
        expect(ring.stateOf(i), SegmentState.filled);
      }
      expect(ring.stateOf(2), SegmentState.target);
      expect(ring.stateOf(4), SegmentState.missing);
      expect(ring.stateOf(5), SegmentState.missing);

      // Progress meter numbers match the ring (single source of truth).
      // Substring matches avoid any bullet-glyph encoding fragility.
      expect(find.textContaining('Accepted: 3/6'), findsOneWidget);
      expect(find.textContaining('Coverage: 50%'), findsOneWidget);
    });

    test('non-contiguous fill with a different gap pattern restores correctly',
        () async {
      // {0,2,5} of 6, user at segment 4 → nearest gap (target) wraps to 3 vs 4.
      var coverage = SegmentCoverage.initial(segmentCount: _n)
          .recordCapture(0)
          .recordCapture(2)
          .recordCapture(5)
          .updatePosition(4);
      final ledger = LevelCaptureLedger()
        ..recordAccepted(_acc(0, 'a.jpg'))
        ..recordAccepted(_acc(2, 'b.jpg'))
        ..recordAccepted(_acc(5, 'c.jpg'));
      final targetBefore = coverage.currentTarget;

      await _applyExit(SaveExitChoice.saveExit, store,
          coverage: coverage, ledger: ledger);
      final resumed = await _resume(store);

      expect(_filledIndices(resumed.coverage), {0, 2, 5});
      expect(resumed.coverage.missingSegments, [1, 3, 4]);
      expect(resumed.coverage.currentTarget, targetBefore,
          reason: 'active target preserved across a non-contiguous restore');
    });
  });

  group('Discard & Exit (negative control)', () {
    test('clears the resumable session; resume restores nothing + cleaned up',
        () async {
      final partial = _buildPartial();
      // Simulate a prior autosaved draft existing, then the user discards.
      await _applyExit(SaveExitChoice.saveExit, store,
          coverage: partial.coverage, ledger: partial.ledger);
      expect(await store.hasSession(_projectId, _levelId), isTrue);

      await _applyExit(SaveExitChoice.discardExit, store,
          coverage: partial.coverage, ledger: partial.ledger);

      // No resumable session remains (cleaned up).
      expect(await store.hasSession(_projectId, _levelId), isFalse);

      // Resume after discard → a FRESH, empty session (nothing restored).
      final resumed = await _resume(store);
      expect(resumed.coverage.filledCount, 0);
      expect(_filledIndices(resumed.coverage), isEmpty);
      expect(resumed.ledger.accepted, isEmpty);
      expect(resumed.ledger.warned, isEmpty);
      expect(resumed.ledger.rejected, isEmpty);
    });
  });

  group('edge cases', () {
    test('no saved session → fresh start, no crash', () async {
      final resumed = await _resume(store); // nothing ever saved
      expect(resumed.coverage.segmentCount, _n);
      expect(resumed.coverage.filledCount, 0);
      expect(resumed.coverage.currentTarget, 0); // all missing, from position 0
      expect(resumed.ledger.accepted, isEmpty);
    });

    test('corrupt active_session data → graceful fresh start (no crash)',
        () async {
      // Open the box via a real save, then corrupt the entry.
      await _applyExit(SaveExitChoice.saveExit, store,
          coverage: _buildPartial().coverage, ledger: _buildPartial().ledger);
      final box = Hive.box<String>(BoxNames.captureSessions);
      await box.put('$_projectId::$_levelId', 'not even json');

      final resumed = await _resume(store);
      expect(resumed.coverage.filledCount, 0, reason: 'degraded to fresh');
      expect(resumed.ledger.accepted, isEmpty);
    });

    test('resuming twice yields identical state (idempotent, no duplication)',
        () async {
      final partial = _buildPartial();
      await _applyExit(SaveExitChoice.saveExit, store,
          coverage: partial.coverage, ledger: partial.ledger);

      final r1 = await _resume(store);
      final r2 = await _resume(store);

      expect(r2.coverage, r1.coverage); // SegmentCoverage value-equal
      expect(r2.ledger.accepted, r1.ledger.accepted);
      expect(r2.ledger.warned, r1.ledger.warned);
      expect(r2.ledger.rejected, r1.ledger.rejected);
      // No capture got duplicated on the second restore (restoreLedger resets).
      expect(r2.ledger.accepted.length, 3);
    });

    test('integrity: no orphaned or duplicated captures after the round-trip',
        () async {
      final partial = _buildPartial();
      final beforePaths =
          partial.ledger.accepted.map((r) => r.framePath).toList();

      await _applyExit(SaveExitChoice.saveExit, store,
          coverage: partial.coverage, ledger: partial.ledger);
      final resumed = await _resume(store);

      final afterPaths =
          resumed.ledger.accepted.map((r) => r.framePath).toList();
      // Same set, same count, no duplicates introduced.
      expect(afterPaths, beforePaths);
      expect(afterPaths.toSet().length, afterPaths.length, reason: 'unique');
      // Every accepted photo maps to a segment that is actually filled (no orphan).
      final filled = _filledIndices(resumed.coverage);
      for (final r in resumed.ledger.accepted) {
        expect(filled.contains(r.segmentIndex), isTrue,
            reason: 'accepted ${r.framePath} → filled segment ${r.segmentIndex}');
      }
      // Distinct accepted segments == filled count (no double-fill / orphan gap).
      expect(
        resumed.ledger.accepted.map((r) => r.segmentIndex).toSet().length,
        resumed.coverage.filledCount,
      );
    });
  });
}
