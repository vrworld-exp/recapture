// test/upload/upload_flow_steps_test.dart
//
// The step-timeline contract (pure Dart, no Flutter): steps run IN ORDER,
// nothing completes implicitly, fail/cancel is terminal for the whole
// timeline, and every invalid transition is a defensive NO-OP returning the
// SAME instance (never a throw) — a tracker bookkeeping bug must not be able
// to fail a real upload.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/upload/upload_flow_steps.dart';

void main() {
  final t0 = DateTime.utc(2026, 7, 12, 10, 0, 0);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

  /// Walks the five steps start→complete in canonical order.
  UploadFlowTimeline completedThrough(
    UploadFlowTimeline t,
    UploadFlowStepId last,
  ) {
    for (final id in UploadFlowStepId.values) {
      t = t.start(id, at: at(id.index * 2));
      t = t.complete(id, at: at(id.index * 2 + 1));
      if (id == last) break;
    }
    return t;
  }

  group('initial', () {
    test('five steps pending, in canonical order, nothing derived', () {
      final t = UploadFlowTimeline.initial();
      expect(t.steps.map((s) => s.id), UploadFlowStepId.values);
      expect(t.steps.every((s) => s.isPending), isTrue);
      expect(t.runningId, isNull);
      expect(t.isTerminal, isFalse);
      expect(t.hasFailure, isFalse);
      expect(t.isCancelled, isFalse);
      expect(t.isAllDone, isFalse);
      expect(t.firstStartedAt, isNull);
      expect(t.lastEndedAt, isNull);
    });

    test('steps list is unmodifiable', () {
      final t = UploadFlowTimeline.initial();
      expect(
        () => t.steps.add(const UploadFlowStepState(
            id: UploadFlowStepId.prepare)),
        throwsUnsupportedError,
      );
    });
  });

  group('start', () {
    test('starting the first step marks it running with its timestamp', () {
      final t = UploadFlowTimeline.initial()
          .start(UploadFlowStepId.prepare, at: at(0));
      expect(t[UploadFlowStepId.prepare].isRunning, isTrue);
      expect(t[UploadFlowStepId.prepare].startedAt, at(0));
      expect(t.runningId, UploadFlowStepId.prepare);
      expect(t.firstStartedAt, at(0));
    });

    test('starting out of order is a no-op (same instance)', () {
      final t = UploadFlowTimeline.initial();
      expect(identical(t.start(UploadFlowStepId.createProject), t), isTrue);
      expect(identical(t.start(UploadFlowStepId.finalize), t), isTrue);
    });

    test('starting while another step is running is a no-op', () {
      final t = UploadFlowTimeline.initial().start(UploadFlowStepId.prepare);
      expect(identical(t.start(UploadFlowStepId.createProject), t), isTrue);
    });

    test('starting a later step with an incomplete gap is a no-op', () {
      // prepare done, createProject still pending → createJob may not start.
      var t = completedThrough(
          UploadFlowTimeline.initial(), UploadFlowStepId.prepare);
      expect(identical(t.start(UploadFlowStepId.createJob), t), isTrue);
      // The immediately next step DOES start.
      t = t.start(UploadFlowStepId.createProject);
      expect(t[UploadFlowStepId.createProject].isRunning, isTrue);
    });

    test('re-starting a done step is a no-op', () {
      final t = completedThrough(
          UploadFlowTimeline.initial(), UploadFlowStepId.prepare);
      expect(identical(t.start(UploadFlowStepId.prepare), t), isTrue);
    });

    test('start records devDetail on the step', () {
      final t = UploadFlowTimeline.initial()
          .start(UploadFlowStepId.prepare, devDetail: ['warmup kicked']);
      expect(t[UploadFlowStepId.prepare].devDetail, ['warmup kicked']);
    });
  });

  group('complete', () {
    test('completes only the RUNNING step, with endedAt + info', () {
      final t = UploadFlowTimeline.initial()
          .start(UploadFlowStepId.prepare, at: at(0))
          .complete(UploadFlowStepId.prepare, info: '38 files', at: at(1));
      final s = t[UploadFlowStepId.prepare];
      expect(s.isDone, isTrue);
      expect(s.endedAt, at(1));
      expect(s.info, '38 files');
      expect(t.lastEndedAt, at(1));
    });

    test('completing a pending step is a no-op — nothing implicit', () {
      final t = UploadFlowTimeline.initial();
      expect(identical(t.complete(UploadFlowStepId.prepare), t), isTrue);
      expect(identical(t.complete(UploadFlowStepId.transfer), t), isTrue);
    });

    test('completing twice is a no-op the second time', () {
      final t = UploadFlowTimeline.initial()
          .start(UploadFlowStepId.prepare)
          .complete(UploadFlowStepId.prepare);
      expect(identical(t.complete(UploadFlowStepId.prepare), t), isTrue);
    });

    test('complete APPENDS devDetail to what start recorded', () {
      final t = UploadFlowTimeline.initial()
          .start(UploadFlowStepId.prepare, devDetail: ['a'])
          .complete(UploadFlowStepId.prepare, devDetail: ['b', 'c']);
      expect(t[UploadFlowStepId.prepare].devDetail, ['a', 'b', 'c']);
    });
  });

  group('updateInfo', () {
    test('sets / replaces / clears the RUNNING step info', () {
      var t = completedThrough(
              UploadFlowTimeline.initial(), UploadFlowStepId.createJob)
          .start(UploadFlowStepId.transfer);
      t = t.updateInfo(UploadFlowStepId.transfer, 'Retrying…');
      expect(t[UploadFlowStepId.transfer].info, 'Retrying…');
      t = t.updateInfo(UploadFlowStepId.transfer, 'Retrying (2)…');
      expect(t[UploadFlowStepId.transfer].info, 'Retrying (2)…');
      t = t.updateInfo(UploadFlowStepId.transfer, null);
      expect(t[UploadFlowStepId.transfer].info, isNull);
    });

    test('no-op when the value is unchanged or the step is not running', () {
      final idle = UploadFlowTimeline.initial();
      expect(
          identical(idle.updateInfo(UploadFlowStepId.transfer, 'x'), idle),
          isTrue);
      final running = idle.start(UploadFlowStepId.prepare);
      final withInfo = running.updateInfo(UploadFlowStepId.prepare, 'x');
      expect(
          identical(withInfo.updateInfo(UploadFlowStepId.prepare, 'x'),
              withInfo),
          isTrue);
      // Clearing an already-null info is also a no-op.
      expect(identical(running.updateInfo(UploadFlowStepId.prepare, null),
          running), isTrue);
    });
  });

  group('fail', () {
    test('failing the running step is terminal for the whole timeline', () {
      final t = UploadFlowTimeline.initial()
          .start(UploadFlowStepId.prepare, at: at(0))
          .fail(UploadFlowStepId.prepare, devDetail: ['boom'], at: at(1));
      expect(t[UploadFlowStepId.prepare].isFailed, isTrue);
      expect(t[UploadFlowStepId.prepare].endedAt, at(1));
      expect(t[UploadFlowStepId.prepare].devDetail, ['boom']);
      expect(t.hasFailure, isTrue);
      expect(t.isTerminal, isTrue);
      // Everything after a failure is a no-op.
      expect(identical(t.start(UploadFlowStepId.createProject), t), isTrue);
      expect(identical(t.complete(UploadFlowStepId.prepare), t), isTrue);
      expect(identical(t.fail(UploadFlowStepId.createProject), t), isTrue);
      expect(identical(t.updateInfo(UploadFlowStepId.prepare, 'x'), t),
          isTrue);
      expect(identical(t.cancelRemaining(), t), isTrue);
    });

    test('a PENDING step can fail (failure landed before its start)', () {
      final t = UploadFlowTimeline.initial()
          .fail(UploadFlowStepId.createProject);
      expect(t[UploadFlowStepId.createProject].isFailed, isTrue);
      expect(t.isTerminal, isTrue);
    });

    test('failing a DONE step is a no-op', () {
      final t = completedThrough(
          UploadFlowTimeline.initial(), UploadFlowStepId.prepare);
      expect(identical(t.fail(UploadFlowStepId.prepare), t), isTrue);
    });

    test('failRunning pins the running step', () {
      final t = completedThrough(
              UploadFlowTimeline.initial(), UploadFlowStepId.prepare)
          .start(UploadFlowStepId.createProject)
          .failRunning(devDetail: ['dio timeout']);
      expect(t[UploadFlowStepId.createProject].isFailed, isTrue);
      expect(t[UploadFlowStepId.prepare].isDone, isTrue);
    });

    test('failRunning with nothing running pins the first pending step', () {
      final t = completedThrough(
              UploadFlowTimeline.initial(), UploadFlowStepId.createProject)
          .failRunning();
      expect(t[UploadFlowStepId.createJob].isFailed, isTrue);
    });
  });

  group('cancelRemaining', () {
    test('cancels running + pending, keeps done, and is terminal', () {
      final t = completedThrough(
              UploadFlowTimeline.initial(), UploadFlowStepId.createJob)
          .start(UploadFlowStepId.transfer)
          .cancelRemaining(at: at(9));
      expect(t[UploadFlowStepId.prepare].isDone, isTrue);
      expect(t[UploadFlowStepId.createProject].isDone, isTrue);
      expect(t[UploadFlowStepId.createJob].isDone, isTrue);
      expect(t[UploadFlowStepId.transfer].isCancelled, isTrue);
      expect(t[UploadFlowStepId.transfer].endedAt, at(9));
      expect(t[UploadFlowStepId.finalize].isCancelled, isTrue);
      expect(t.isCancelled, isTrue);
      expect(t.isTerminal, isTrue);
      // Terminal: a second cancel (or anything else) is a no-op.
      expect(identical(t.cancelRemaining(), t), isTrue);
      expect(identical(t.start(UploadFlowStepId.transfer), t), isTrue);
    });

    test('cancel before anything started strikes all five', () {
      final t = UploadFlowTimeline.initial().cancelRemaining();
      expect(t.steps.every((s) => s.isCancelled), isTrue);
      expect(t.isTerminal, isTrue);
    });
  });

  group('full happy walk', () {
    test('all five complete in order → isAllDone, then frozen', () {
      final t = completedThrough(
          UploadFlowTimeline.initial(), UploadFlowStepId.finalize);
      expect(t.steps.every((s) => s.isDone), isTrue);
      expect(t.isAllDone, isTrue);
      expect(t.isTerminal, isTrue);
      expect(t.hasFailure, isFalse);
      expect(t.isCancelled, isFalse);
      // Duration anchors: prepare's start → finalize's end.
      expect(t.firstStartedAt, at(0));
      expect(t.lastEndedAt, at(UploadFlowStepId.finalize.index * 2 + 1));
      // Frozen once all done.
      expect(identical(t.fail(UploadFlowStepId.finalize), t), isTrue);
      expect(identical(t.cancelRemaining(), t), isTrue);
    });

    test('every transition returns a NEW timeline (input untouched)', () {
      final t0 = UploadFlowTimeline.initial();
      final t1 = t0.start(UploadFlowStepId.prepare);
      expect(identical(t0, t1), isFalse);
      expect(t0[UploadFlowStepId.prepare].isPending, isTrue);
      expect(t1[UploadFlowStepId.prepare].isRunning, isTrue);
    });
  });
}
