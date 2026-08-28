// test/upload/offline_upload_queue_test.dart
//
// The offline upload queue coordinator: offline (hint OR real network failure)
// → durable "waiting for connection" (never failed); connectivity restore →
// auto-resume of offline-queued jobs ONLY (user-paused stays paused); debounced
// flapping; false-positive reachability re-probe with backoff; restart
// durability via restore(); FIFO multi-job order; cancel clears both the queue
// entry and the byte-level resume bookkeeping.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/upload/offline_upload_queue.dart';
import 'package:recapture/application/upload/resilient_upload_runner.dart';
import 'package:recapture/data/local/upload_progress_box.dart';
import 'package:recapture/data/local/upload_queue_box.dart';
import 'package:recapture/domain/upload/upload_failure.dart';
import 'package:recapture/domain/upload/upload_queue_entry.dart';
import 'package:recapture/domain/upload/upload_session_spec.dart';
import 'package:recapture/utils/analytics.dart';

UploadSessionSpec spec(String id) => UploadSessionSpec(sessionId: id, files: [
      UploadFileSpec(path: '/c/$id.jpg', key: 'k/$id', size: 100),
    ]);

const succeeded =
    ResilientUploadOutcome(status: ResilientUploadStatus.succeeded, attemptsUsed: 1);
const networkFailed = ResilientUploadOutcome(
  status: ResilientUploadStatus.failed,
  attemptsUsed: 4,
  category: UploadErrorCategory.network,
  autoRetriesExhausted: true,
);
const validationFailed = ResilientUploadOutcome(
  status: ResilientUploadStatus.failed,
  attemptsUsed: 1,
  category: UploadErrorCategory.validation,
);

/// Scripted [UploadJobRunner]: records run order; per-session handlers decide
/// the outcome (default: immediate success).
class ScriptedRunner implements UploadJobRunner {
  final List<String> runs = [];
  Future<ResilientUploadOutcome> Function(UploadSessionSpec session)? handler;

  @override
  Future<ResilientUploadOutcome> run(UploadSessionSpec session) {
    runs.add(session.sessionId);
    return handler?.call(session) ?? Future.value(succeeded);
  }
}

/// Injectable sleep whose completions the test controls (debounce + probe holds).
class ManualSleep {
  final List<Completer<void>> pending = [];

  Future<void> call(Duration _) {
    final c = Completer<void>();
    pending.add(c);
    return c.future;
  }

  Future<void> release() async {
    final batch = [...pending];
    pending.clear();
    for (final c in batch) {
      c.complete();
    }
    await pumpEventQueue();
  }
}

void main() {
  late InMemoryUploadQueueStore store;
  late InMemoryUploadProgressStore progressStore;
  late ScriptedRunner runner;
  late List<(String, Map<String, Object?>)> events;

  setUp(() {
    store = InMemoryUploadQueueStore();
    progressStore = InMemoryUploadProgressStore();
    runner = ScriptedRunner();
    events = [];
  });

  OfflineUploadQueue makeQueue({
    bool online = true,
    Future<void> Function(Duration)? sleep,
  }) =>
      OfflineUploadQueue(
        store: store,
        runner: runner,
        progressStore: progressStore,
        initialOnline: online,
        sleep: sleep ?? (_) async {},
        analytics: (name, props) => events.add((name, props)),
      );

  List<String> eventNames() => [for (final e in events) e.$1];

  group('offline → queue (never fail)', () {
    test('enqueue while offline → waiting for connection; nothing runs', () async {
      final q = makeQueue(online: false);
      await q.enqueue(spec('s1'));
      await pumpEventQueue();

      expect(runner.runs, isEmpty);
      final entry = q.entries.single;
      expect(entry.state, UploadJobState.offlineQueued);
      expect(entry.isWaitingForConnection, isTrue);
      // Durable, not just in-memory.
      expect((await store.get('s1'))!.state, UploadJobState.offlineQueued);
      expect(eventNames(), contains(AnalyticsEvents.uploadOfflineQueued));
      expect(events.single.$2['reason'], 'offline_at_start');
    });

    test('enqueue while online → runs immediately and completes', () async {
      final q = makeQueue();
      await q.enqueue(spec('s1'));
      await pumpEventQueue();
      await q.idle;

      expect(runner.runs, ['s1']);
      expect(q.entries, isEmpty);
      expect(await store.get('s1'), isNull); // bookkeeping cleaned up
    });

    test('network failure mid-upload → re-queued (waiting), resume state retained',
        () async {
      final sleep = ManualSleep(); // holds the reachability probe
      runner.handler = (_) async => networkFailed;
      // Simulate the engine's persisted resume point for this session.
      await progressStore.begin('s1', 'f0',
          uploadId: 'u-1', objectKey: 'k0', totalParts: 3, totalBytes: 300);

      final q = makeQueue(sleep: sleep.call);
      await q.enqueue(spec('s1'));
      await pumpEventQueue();
      await q.idle;

      final entry = q.entries.single;
      expect(entry.state, UploadJobState.offlineQueued); // NOT failed
      expect(entry.lastErrorCategory, UploadErrorCategory.network);
      // The offset/ETag bookkeeping is untouched — resume continues from it.
      expect((await progressStore.get('s1', 'f0'))!.uploadId, 'u-1');
      expect(eventNames(), contains(AnalyticsEvents.uploadOfflineQueued));
    });

    test('onUploadNetworkFailure (external reachability signal) re-queues',
        () async {
      final sleep = ManualSleep();
      final q = makeQueue(sleep: sleep.call, online: false);
      await q.enqueue(spec('s1'));
      // Simulate a pipeline-side network failure report for a tracked job that
      // some other layer had been running.
      await q.onUploadNetworkFailure('s1');

      expect(q.entries.single.state, UploadJobState.offlineQueued);
      expect(q.entries.single.lastErrorCategory, UploadErrorCategory.network);
    });
  });

  group('auto-resume on connectivity restore', () {
    test('offline→online drains the queued job from its persisted state',
        () async {
      final q = makeQueue(online: false);
      await q.enqueue(spec('s1'));
      await pumpEventQueue();
      expect(runner.runs, isEmpty);

      q.onConnectivityChanged(true);
      await pumpEventQueue();
      await q.idle;

      expect(runner.runs, ['s1']);
      expect(q.entries, isEmpty);
    });

    test('multiple queued jobs resume in FIFO (enqueue) order', () async {
      final q = makeQueue(online: false);
      await q.enqueue(spec('a'));
      await q.enqueue(spec('b'));
      await q.enqueue(spec('c'));

      q.onConnectivityChanged(true);
      await pumpEventQueue();
      await q.idle;

      expect(runner.runs, ['a', 'b', 'c']);
      expect(q.entries, isEmpty);
    });

    test('a resumed job (attempts > 0) emits upload_offline_auto_resumed',
        () async {
      final sleep = ManualSleep();
      var calls = 0;
      runner.handler = (_) async => ++calls == 1 ? networkFailed : succeeded;

      final q = makeQueue(sleep: sleep.call);
      await q.enqueue(spec('s1'));
      await pumpEventQueue();
      await q.idle; // first run → network failure → re-queued
      expect(events.where((e) => e.$1 == AnalyticsEvents.uploadOfflineAutoResumed),
          isEmpty);

      await sleep.release(); // reachability probe fires → second run
      await q.idle;

      final resumed = events
          .where((e) => e.$1 == AnalyticsEvents.uploadOfflineAutoResumed)
          .toList();
      expect(resumed, hasLength(1));
      expect(resumed.single.$2['attempt'], 2);
      expect(q.entries, isEmpty); // second run succeeded
      expect(runner.runs, ['s1', 's1']);
    });

    test('drain stops at a network failure — jobs behind it stay queued',
        () async {
      final sleep = ManualSleep(); // holds the probe (no immediate re-drain)
      runner.handler = (_) async => networkFailed;

      final q = makeQueue(online: false, sleep: sleep.call);
      await q.enqueue(spec('a'));
      await q.enqueue(spec('b'));
      q.onConnectivityChanged(true);
      await sleep.release(); // debounce settles → drain
      await q.idle;

      expect(runner.runs, ['a']); // b never attempted into a dead network
      expect(q.entries.map((e) => e.state),
          everyElement(UploadJobState.offlineQueued));
    });

    test('a NON-network terminal failure marks failed and does not block the rest',
        () async {
      runner.handler = (s) async =>
          s.sessionId == 'bad' ? validationFailed : succeeded;

      final q = makeQueue(online: false);
      await q.enqueue(spec('bad'));
      await q.enqueue(spec('good'));
      q.onConnectivityChanged(true);
      await pumpEventQueue();
      await q.idle;

      expect(runner.runs, ['bad', 'good']);
      final bad = q.entries.single; // 'good' completed and was removed
      expect(bad.jobId, 'bad');
      expect(bad.state, UploadJobState.failed); // 9F territory
      expect(bad.lastErrorCategory, UploadErrorCategory.validation);
    });

    test('concurrent autoResumeQueued calls share one drain (single-flight)',
        () async {
      final gate = Completer<ResilientUploadOutcome>();
      runner.handler = (_) => gate.future;

      final q = makeQueue(online: false);
      await q.enqueue(spec('s1'));
      final d1 = q.autoResumeQueued();
      final d2 = q.autoResumeQueued();
      await pumpEventQueue();
      expect(runner.runs, ['s1']); // one run, not two

      gate.complete(succeeded);
      await d1;
      await d2;
      expect(runner.runs, ['s1']);
    });
  });

  group('debounce (flapping connectivity)', () {
    test('online flap that reverts within the debounce never starts a drain',
        () async {
      final sleep = ManualSleep();
      final q = makeQueue(online: false, sleep: sleep.call);
      await q.enqueue(spec('s1'));

      q.onConnectivityChanged(true); // flap up…
      q.onConnectivityChanged(false); // …and straight back down
      await sleep.release(); // both debounce windows elapse
      await q.idle;

      expect(runner.runs, isEmpty); // the stale "online" was superseded
      expect(q.entries.single.state, UploadJobState.offlineQueued);
    });

    test('a settled online transition after flapping drains once', () async {
      final sleep = ManualSleep();
      final q = makeQueue(online: false, sleep: sleep.call);
      await q.enqueue(spec('s1'));

      q.onConnectivityChanged(true);
      q.onConnectivityChanged(false);
      q.onConnectivityChanged(true); // settles online
      await sleep.release();
      await q.idle;

      expect(runner.runs, ['s1']);
    });
  });

  group('user-paused vs offline-queued (the KEY distinction)', () {
    test('a user-paused job STAYS paused when connectivity returns', () async {
      final q = makeQueue(online: false);
      await q.enqueue(spec('paused'));
      await q.enqueue(spec('queued'));
      await q.markUserPaused('paused');

      q.onConnectivityChanged(true);
      await pumpEventQueue();
      await q.idle;

      expect(runner.runs, ['queued']); // never the paused one
      expect(q.entries.single.jobId, 'paused');
      expect(q.entries.single.state, UploadJobState.userPaused);
    });

    test('user pause DURING a run wins over the network-failure re-queue',
        () async {
      final gate = Completer<ResilientUploadOutcome>();
      runner.handler = (_) => gate.future;
      final sleep = ManualSleep();

      final q = makeQueue(sleep: sleep.call);
      await q.enqueue(spec('s1'));
      await pumpEventQueue();
      expect(runner.runs, ['s1']); // in flight

      await q.markUserPaused('s1'); // user intent lands mid-run
      gate.complete(networkFailed); // the interrupted run then reports network
      await q.idle;

      expect(q.entries.single.state, UploadJobState.userPaused); // intent kept
    });

    test('manual resume while online runs the job', () async {
      final q = makeQueue(online: false);
      await q.enqueue(spec('s1'));
      await q.markUserPaused('s1');
      q.onConnectivityChanged(true);
      await pumpEventQueue();
      await q.idle;
      expect(runner.runs, isEmpty); // still paused after restore

      await q.resumeUserPaused('s1');
      await q.idle;
      expect(runner.runs, ['s1']);
      expect(q.entries, isEmpty);
    });

    test('manual resume while offline re-enters the waiting lane (no run)',
        () async {
      final q = makeQueue(online: false);
      await q.enqueue(spec('s1'));
      await q.markUserPaused('s1');

      await q.resumeUserPaused('s1');
      await pumpEventQueue();

      expect(runner.runs, isEmpty);
      expect(q.entries.single.state, UploadJobState.offlineQueued);
    });
  });

  group('durability across restart (restore)', () {
    test('relaunch offline: queued stays queued; interrupted runs re-queue; '
        'user intent + terminal cleanup honored', () async {
      // Persisted world from the previous process:
      await store.put(_persisted('killed-mid-run', UploadJobState.uploading, 0));
      await store.put(_persisted('paused', UploadJobState.userPaused, 1));
      await store.put(_persisted('waiting', UploadJobState.offlineQueued, 2));
      await store.put(_persisted('done', UploadJobState.completed, 3));

      final q = makeQueue(online: false);
      await q.restore();
      await pumpEventQueue();

      expect(runner.runs, isEmpty); // offline → nothing resumes
      final byId = {for (final e in q.entries) e.jobId: e};
      expect(byId['killed-mid-run']!.state, UploadJobState.offlineQueued);
      expect(byId['paused']!.state, UploadJobState.userPaused);
      expect(byId['waiting']!.state, UploadJobState.offlineQueued);
      expect(byId.containsKey('done'), isFalse); // stale terminal row dropped
      expect(await store.get('done'), isNull);
      // The reconciled state is persisted (a second relaunch sees it directly).
      expect((await store.get('killed-mid-run'))!.state,
          UploadJobState.offlineQueued);
    });

    test('relaunch online: queued jobs auto-resume; user-paused does not',
        () async {
      await store.put(_persisted('waiting', UploadJobState.offlineQueued, 0));
      await store.put(_persisted('paused', UploadJobState.userPaused, 1));

      final q = makeQueue();
      await q.restore();
      await pumpEventQueue();
      await q.idle;

      expect(runner.runs, ['waiting']);
      expect(q.entries.single.jobId, 'paused');
    });

    test('new enqueues after restore keep FIFO order behind restored jobs',
        () async {
      await store.put(_persisted('old', UploadJobState.offlineQueued, 5));

      final q = makeQueue(online: false);
      await q.restore();
      await q.enqueue(spec('new'));

      q.onConnectivityChanged(true);
      await pumpEventQueue();
      await q.idle;

      expect(runner.runs, ['old', 'new']);
    });
  });

  group('cancel', () {
    test('cancelling a queued job clears the entry AND the resume bookkeeping',
        () async {
      await progressStore.begin('s1', 'f0',
          uploadId: 'u-1', objectKey: 'k0', totalParts: 2, totalBytes: 200);

      final q = makeQueue(online: false);
      await q.enqueue(spec('s1'));
      await q.cancel('s1');

      expect(q.entries, isEmpty);
      expect(await store.get('s1'), isNull);
      expect(await progressStore.get('s1', 'f0'), isNull); // bookkeeping cleared
      // Going online later must not resurrect it.
      q.onConnectivityChanged(true);
      await pumpEventQueue();
      await q.idle;
      expect(runner.runs, isEmpty);
    });

    test('cancel during a run: the outcome does not resurrect the entry',
        () async {
      final gate = Completer<ResilientUploadOutcome>();
      runner.handler = (_) => gate.future;
      final sleep = ManualSleep();

      final q = makeQueue(sleep: sleep.call);
      await q.enqueue(spec('s1'));
      await pumpEventQueue();
      expect(runner.runs, ['s1']);

      await q.cancel('s1'); // user cancels while in flight
      gate.complete(networkFailed); // the aborted run surfaces a network error
      await q.idle;

      expect(q.entries, isEmpty);
      expect(await store.get('s1'), isNull);
    });
  });

  group('reachability false positive (hint online, server unreachable)', () {
    test('failure while the hint says online schedules a backoff re-probe that '
        'drains again', () async {
      final sleep = ManualSleep();
      var calls = 0;
      runner.handler = (_) async => ++calls == 1 ? networkFailed : succeeded;

      final q = makeQueue(sleep: sleep.call); // hint: online the whole time
      await q.enqueue(spec('s1'));
      await pumpEventQueue();
      await q.idle;
      expect(q.entries.single.state, UploadJobState.offlineQueued);
      expect(sleep.pending, hasLength(1)); // exactly one probe pending

      await sleep.release(); // probe elapses → re-drain
      await q.idle;

      expect(runner.runs, ['s1', 's1']);
      expect(q.entries, isEmpty); // reachability returned → completed
    });

    test('a real online transition supersedes the pending probe (no double '
        'drain)', () async {
      final sleep = ManualSleep();
      var calls = 0;
      runner.handler = (_) async => ++calls == 1 ? networkFailed : succeeded;

      final q = makeQueue(sleep: sleep.call);
      await q.enqueue(spec('s1'));
      await pumpEventQueue();
      await q.idle; // failed → probe pending

      q.onConnectivityChanged(false); // the hint catches up…
      q.onConnectivityChanged(true); // …then connectivity really returns
      await sleep.release(); // probe + debounce windows all elapse
      await q.idle;
      await pumpEventQueue();

      expect(runner.runs, ['s1', 's1']); // resumed exactly once
      expect(q.entries, isEmpty);
    });
  });
}

UploadQueueEntry _persisted(String id, UploadJobState state, int seq) =>
    UploadQueueEntry(jobId: id, spec: spec(id), state: state, seq: seq);
