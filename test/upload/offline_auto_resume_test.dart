// test/upload/offline_auto_resume_test.dart
//
// Offline during upload → queues, auto-resumes on reconnect. Composed
// INTEGRATION tests over the real production stack:
//
//   OfflineUploadQueue → ResilientUploadRunner → ManagerUploadAttempt
//     → ChunkedUploadManager (+ InMemoryUploadProgressStore)
//
// ARCHITECTURE FINDING these tests pin (spec assumption #1 confirmed): the
// ENGINE does not subscribe to connectivity and has NO auto-resume — its pull
// `isOnline` hook only auto-PAUSES (upload_paused{connectivity}) and parks
// until an external resume(). Auto-resume on reconnect lives in the
// OfflineUploadQueue: a real network failure re-queues the job (offlineQueued,
// never failed) and a debounced onConnectivityChanged(true) re-RUNS it; the
// re-run continues from the durable UploadProgressStore (persisted uploadId +
// ETags → confirmed parts are skipped, initiate is NOT called again). So the
// connectivity cycle's analytics are upload_offline_queued /
// upload_offline_auto_resumed (+ per-run engine lifecycle events) — NOT an
// engine-level upload_paused/upload_resumed pair.
//
// Determinism: fakes mirror test/upload/chunked_upload_manager_test.dart
// (gated S3 with per-part release + attempt recording; that file's fakes are
// private to it, hence the local copies); all sleeps injected as no-ops; the
// only "network" is the `offline` flag on the S3 fake (PUTs throw
// connectionError while set). No sockets, no wall-clock.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/upload/chunked_upload_manager.dart';
import 'package:recapture/application/upload/multipart_upload_api.dart';
import 'package:recapture/application/upload/offline_upload_queue.dart';
import 'package:recapture/application/upload/resilient_upload_runner.dart';
import 'package:recapture/data/local/upload_progress_box.dart';
import 'package:recapture/data/local/upload_queue_box.dart';
import 'package:recapture/domain/entities/upload_progress.dart';
import 'package:recapture/domain/upload/session_retry_policy.dart';
import 'package:recapture/domain/upload/upload_part_plan.dart';
import 'package:recapture/domain/upload/upload_queue_entry.dart';
import 'package:recapture/domain/upload/upload_session_spec.dart';
import 'package:recapture/utils/analytics.dart';

int _pnFromUrl(String url) =>
    int.parse(RegExp(r'/part/(\d+)').firstMatch(url)!.group(1)!);

class _ZeroBytes implements PartByteSource {
  _ZeroBytes(this.sizes);
  final Map<String, int> sizes;
  @override
  int fileSize(String path) => sizes[path] ?? 0;
  @override
  Stream<List<int>> read(String path, int offset, int length) async* {
    var remaining = length;
    const chunk = 65536;
    while (remaining > 0) {
      final n = remaining < chunk ? remaining : chunk;
      yield List.filled(n, 0);
      remaining -= n;
    }
  }
}

class _FakeApi implements MultipartUploadApi {
  final List<String> initiated = [];
  final List<String> completedUploadIds = [];
  final List<List<CompletedPart>> completed = [];
  int aborts = 0;

  @override
  Future<InitiatedUpload> initiate({
    required String sessionId,
    required String fileKey,
    required int fileSize,
    required int partCount,
  }) async {
    initiated.add(fileKey);
    return InitiatedUpload(
      uploadId: 'u-$fileKey',
      key: fileKey,
      parts: [
        for (var n = 1; n <= partCount; n++)
          PresignedPart(partNumber: n, url: 'https://s3/$fileKey/part/$n'),
      ],
    );
  }

  @override
  Future<String?> refreshPartUrl({
    required String uploadId,
    required String key,
    required int partNumber,
  }) async =>
      'https://s3/$key/part/$partNumber?refreshed';

  @override
  Future<void> complete({
    required String uploadId,
    required String key,
    required List<CompletedPart> parts,
  }) async {
    completedUploadIds.add(uploadId);
    completed.add(parts);
  }

  @override
  Future<void> abort({required String uploadId, required String key}) async =>
      aborts++;
}

/// Gated S3 fake with a network switch: each part parks at a per-part gate the
/// test releases; while [offline] every released PUT throws a Dio
/// connectionError (classified `network` by the shared classifier). Records
/// EVERY attempt and every success separately so retry storms and re-uploads
/// are both directly countable.
class _OfflineGatedS3 implements S3PartClient {
  bool offline = false;
  final List<int> attempts = []; // every putPart call
  final List<int> uploaded = []; // successes only
  final Map<int, Completer<void>> _gates = {};
  final Map<int, Completer<void>> _startedWaiters = {};

  Future<void> waitStarted(int pn) =>
      _startedWaiters.putIfAbsent(pn, Completer<void>.new).future;

  void release(int pn) {
    final g = _gates.putIfAbsent(pn, Completer<void>.new);
    if (!g.isCompleted) g.complete();
  }

  int attemptsOf(int pn) => attempts.where((p) => p == pn).length;
  int successesOf(int pn) => uploaded.where((p) => p == pn).length;

  @override
  Future<String> putPart({
    required String url,
    required Stream<List<int>> body,
    required int length,
    void Function(int sent, int total)? onSendProgress,
    required CancelToken cancelToken,
  }) async {
    await body.drain<void>();
    final pn = _pnFromUrl(url);
    attempts.add(pn);
    final w = _startedWaiters.putIfAbsent(pn, Completer<void>.new);
    if (!w.isCompleted) w.complete();
    await _gates.putIfAbsent(pn, Completer<void>.new).future;
    if (offline) {
      throw DioException(
        requestOptions: RequestOptions(path: url),
        type: DioExceptionType.connectionError,
      );
    }
    onSendProgress?.call(length, length);
    uploaded.add(pn);
    return 'etag-$pn';
  }
}

/// The composition glue the production pipeline will use (documented in
/// offline_upload_queue.dart's LAYERING note): one drained job = one
/// ResilientUploadRunner.run over the engine.
class _RunnerJob implements UploadJobRunner {
  _RunnerJob(this.runner);
  final ResilientUploadRunner runner;
  @override
  Future<ResilientUploadOutcome> run(UploadSessionSpec session) =>
      runner.run(session);
}

Future<void> _tick([int times = 10]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

UploadSessionSpec _session(List<int> sizes) => UploadSessionSpec(
      sessionId: 'sess1',
      files: [
        for (var i = 0; i < sizes.length; i++)
          UploadFileSpec(path: 'f$i', key: 'file_$i.jpg', size: sizes[i]),
      ],
    );

/// One fully-wired offline-capable upload stack.
({
  _FakeApi api,
  _OfflineGatedS3 s3,
  ChunkedUploadManager manager,
  OfflineUploadQueue queue,
}) _buildStack({required Map<String, int> sizes, bool initialOnline = true}) {
  final api = _FakeApi();
  final s3 = _OfflineGatedS3();
  final progress = InMemoryUploadProgressStore();
  final manager = ChunkedUploadManager(
    api: api,
    s3: s3,
    byteSource: _ZeroBytes(sizes),
    maxConcurrentParts: 1,
    chunkSize: kS3MinPartSize,
    retry: const UploadRetryPolicy(maxAttempts: 2), // bounded per engine run
    sleep: (_) async {},
    store: progress,
  );
  final runner = ResilientUploadRunner(
    attempt: ManagerUploadAttempt(manager),
    policy: const SessionRetryPolicy(maxRetries: 1), // bounded per queue run
    sleep: (_) async {},
  );
  final queue = OfflineUploadQueue(
    store: InMemoryUploadQueueStore(),
    runner: _RunnerJob(runner),
    progressStore: progress,
    initialOnline: initialOnline,
    sleep: (_) async {}, // debounce/probe settle on microtasks
  );
  addTearDown(manager.dispose);
  addTearDown(queue.dispose);
  return (api: api, s3: s3, manager: manager, queue: queue);
}

void main() {
  late List<(String, Map<String, Object?>)> events;

  List<Map<String, Object?>> named(String name) =>
      [for (final (n, p) in events) if (n == name) p];

  setUp(() {
    events = [];
    Analytics.testSink = (n, p) => events.add((n, p));
  });
  tearDown(() => Analytics.testSink = null);

  group('engine connectivity hint (pull) — pause side only', () {
    test(
        'hint-offline mid-upload → paused(connectivity), zero PUTs while parked, '
        'and NO engine-level auto-resume when the hint recovers (queue owns resume)',
        () async {
      var online = true;
      final api = _FakeApi();
      final s3 = _OfflineGatedS3();
      final manager = ChunkedUploadManager(
        api: api,
        s3: s3,
        byteSource: _ZeroBytes({'f0': kS3MinPartSize * 2 + 50}), // 3 parts
        maxConcurrentParts: 1,
        chunkSize: kS3MinPartSize,
        isOnline: () => online,
      );
      addTearDown(manager.dispose);

      final done = manager.start(_session([kS3MinPartSize * 2 + 50]));
      await s3.waitStarted(1);
      online = false; // hint flips while part 1 is in flight
      s3.release(1); // part 1 finishes; worker then sees offline and parks

      await _tick();
      expect(manager.currentStatus, UploadStatus.paused,
          reason: 'offline must pause, never fail');
      expect(s3.attempts, [1], reason: 'worker parked — zero attempts offline');
      await _tick(20);
      expect(s3.attempts, [1], reason: 'no retry storm against a dead network');

      final paused = named(AnalyticsEvents.uploadPaused);
      expect(paused, hasLength(1), reason: 'edge event, not per tick');
      expect(paused.single['pause_reason'], 'connectivity');
      expect(named(AnalyticsEvents.uploadFailed), isEmpty);

      // FINDING (pinned): the engine does NOT observe the hint recovering —
      // auto-resume is the OfflineUploadQueue's job (tests below).
      online = true;
      await _tick(20);
      expect(manager.currentStatus, UploadStatus.paused);
      expect(named(AnalyticsEvents.uploadResumed), isEmpty);

      // Cleanup path (manual lane): resume → completes, nothing re-uploaded.
      s3.release(2);
      s3.release(3);
      manager.resume();
      await done;
      expect(s3.successesOf(1), 1);
      expect(s3.successesOf(2), 1);
      expect(s3.successesOf(3), 1);
    });
  });

  group('offline mid-upload → queued → AUTO-resume on reconnect (composed stack)', () {
    test(
        'full cycle: queued not failed, bounded attempts offline, reconnect '
        'auto-resumes with NO resume() call, every part uploaded exactly once, '
        'same uploadId (single initiate)', () async {
      final stack = _buildStack(sizes: {'f0': kS3MinPartSize * 2 + 50}); // 3 parts
      final (api: api, s3: s3, manager: manager, queue: queue) = stack;
      final snapshots = <UploadProgress>[];
      final sub = manager.watch().listen(snapshots.add);
      addTearDown(sub.cancel);

      await queue.enqueue(_session([kS3MinPartSize * 2 + 50]));
      await s3.waitStarted(1);
      s3.release(1); // part 1 confirmed online → persisted in the store
      await s3.waitStarted(2); // part 2 mid-flight when the network dies

      queue.onConnectivityChanged(false); // hint transitions first…
      await _tick(); // …and settles (debounced, injected sleep)
      s3.offline = true; // now the network is really dead
      s3.release(2); // the in-flight PUT fails with connectionError
      await _tick(30);
      await queue.idle; // runner retries exhausted → job re-queued

      // Queued, NOT failed — and the offline window is strictly bounded:
      // engine 2 attempts/run × runner 2 runs = 4 PUT attempts on part 2.
      expect(queue.entries.single.state, UploadJobState.offlineQueued);
      expect(s3.attemptsOf(2), 4);
      expect(s3.attemptsOf(3), 0, reason: 'part 3 never launched offline');
      final frozen = s3.attempts.length;
      await _tick(30);
      expect(s3.attempts.length, frozen,
          reason: 'no retry storm while queued offline (hint offline → no probes)');
      expect(named(AnalyticsEvents.uploadOfflineQueued), hasLength(1));
      expect(named(AnalyticsEvents.uploadOfflineQueued).single['reason'],
          'network_failure');

      // Reconnect. The test NEVER calls resume()/autoResumeQueued() — the
      // connectivity event alone must drive the resume.
      s3.offline = false;
      s3.release(3); // pre-release so the resumed run can finish
      queue.onConnectivityChanged(true);
      await _tick(30);
      await queue.idle;

      // Auto-resumed and completed: job drained off the queue.
      expect(queue.entries, isEmpty, reason: 'success removes the entry');
      expect(named(AnalyticsEvents.uploadOfflineAutoResumed), hasLength(1));

      // No re-upload: parts 1 and 3 PUT exactly once ever; part 2 succeeded
      // exactly once (its 4 offline attempts all failed before any byte was
      // acknowledged).
      expect(s3.attemptsOf(1), 1, reason: 'confirmed part never re-PUT');
      expect(s3.successesOf(1), 1);
      expect(s3.successesOf(2), 1);
      expect(s3.attemptsOf(3), 1);
      expect(s3.successesOf(3), 1);

      // Same attempt across the reconnect: initiate was called ONCE — the
      // resumed run reused the persisted uploadId from the progress store —
      // and the multipart completed under the ORIGINAL id.
      expect(api.initiated, ['file_0.jpg']);
      expect(api.completedUploadIds, ['u-file_0.jpg']);

      // Progress: monotonic within each engine run (runs are separated by the
      // engine's documented reset-to-seed snapshot), resumed run seeds from
      // part 1's persisted offset (never re-transfers from byte 0), and the
      // final snapshot equals the full total.
      final runs = <List<int>>[[]];
      for (final s in snapshots) {
        if (runs.last.isNotEmpty && s.bytesUploaded < runs.last.last) {
          runs.add([]);
        }
        runs.last.add(s.bytesUploaded);
      }
      for (final run in runs) {
        for (var i = 1; i < run.length; i++) {
          expect(run[i], greaterThanOrEqualTo(run[i - 1]));
        }
      }
      expect(snapshots.last.bytesUploaded, kS3MinPartSize * 2 + 50);
      expect(snapshots.last.status, UploadStatus.completed);
    });

    test('already offline at start: queues (offline_at_start), zero PUTs, then '
        'auto-uploads on reconnect', () async {
      final stack = _buildStack(sizes: {'f0': 1000}, initialOnline: false);
      final (api: _, s3: s3, manager: _, queue: queue) = stack;

      await queue.enqueue(_session([1000]));
      await _tick(20);
      expect(queue.entries.single.state, UploadJobState.offlineQueued);
      expect(s3.attempts, isEmpty, reason: 'nothing is attempted offline');
      expect(named(AnalyticsEvents.uploadOfflineQueued).single['reason'],
          'offline_at_start');

      s3.release(1);
      queue.onConnectivityChanged(true);
      await _tick(30);
      await queue.idle;

      expect(queue.entries, isEmpty);
      expect(s3.attemptsOf(1), 1);
      expect(s3.successesOf(1), 1);
    });

    test('connectivity flapping: debounce coalesces to ONE effective resume; '
        'no part ever uploaded twice', () async {
      final stack = _buildStack(sizes: {'f0': 1000}, initialOnline: false);
      final (api: api, s3: s3, manager: _, queue: queue) = stack;

      await queue.enqueue(_session([1000]));
      s3.release(1);

      // Rapid flapping ending online: generation guard + single-flight drain
      // must coalesce this into exactly one run.
      queue.onConnectivityChanged(true);
      queue.onConnectivityChanged(false);
      queue.onConnectivityChanged(true);
      queue.onConnectivityChanged(false);
      queue.onConnectivityChanged(true);
      await _tick(30);
      await queue.idle;

      expect(queue.entries, isEmpty);
      expect(s3.attemptsOf(1), 1, reason: 'no duplicate/concurrent resumes');
      expect(s3.successesOf(1), 1);
      expect(api.initiated, ['file_0.jpg']);
      expect(named(AnalyticsEvents.uploadStarted), hasLength(1),
          reason: 'the job ran exactly once despite the flapping');
    });

    test('connectivity never recovers: stays offlineQueued indefinitely — '
        'no failure surfaced, attempts frozen', () async {
      final stack = _buildStack(sizes: {'f0': 1000});
      final (api: _, s3: s3, manager: _, queue: queue) = stack;

      queue.onConnectivityChanged(false);
      await _tick();
      s3.offline = true;
      s3.release(1);
      await queue.enqueue(_session([1000]));
      await _tick(30);
      await queue.idle;

      expect(queue.entries.single.state, UploadJobState.offlineQueued,
          reason: 'queued forever, never UploadJobState.failed');
      final frozen = s3.attempts.length;
      await _tick(50);
      expect(s3.attempts.length, frozen,
          reason: 'no tight retry loop while the hint stays offline');
    });

    test('two offline/online cycles in one upload: each part exactly once, '
        'queued+auto-resumed once per cycle', () async {
      final stack = _buildStack(sizes: {'f0': kS3MinPartSize * 2 + 50}); // 3 parts
      final (api: api, s3: s3, manager: _, queue: queue) = stack;

      await queue.enqueue(_session([kS3MinPartSize * 2 + 50]));
      await s3.waitStarted(1);
      s3.release(1);
      await s3.waitStarted(2);

      // Cycle 1: die during part 2.
      queue.onConnectivityChanged(false);
      await _tick();
      s3.offline = true;
      s3.release(2);
      await _tick(30);
      await queue.idle;
      expect(queue.entries.single.state, UploadJobState.offlineQueued);

      // Recover; die again during part 3.
      s3.offline = false;
      queue.onConnectivityChanged(true);
      await s3.waitStarted(3); // part 2 done (resumed run); part 3 mid-flight
      queue.onConnectivityChanged(false);
      await _tick();
      s3.offline = true;
      s3.release(3);
      await _tick(30);
      await queue.idle;
      expect(queue.entries.single.state, UploadJobState.offlineQueued);

      // Final recovery → completes.
      s3.offline = false;
      queue.onConnectivityChanged(true);
      await _tick(30);
      await queue.idle;

      expect(queue.entries, isEmpty);
      expect(s3.successesOf(1), 1);
      expect(s3.successesOf(2), 1);
      expect(s3.successesOf(3), 1);
      expect(s3.attemptsOf(1), 1, reason: 'confirmed part survives BOTH cycles');
      expect(api.initiated, ['file_0.jpg']);
      expect(api.completedUploadIds, ['u-file_0.jpg']);
      expect(named(AnalyticsEvents.uploadOfflineQueued), hasLength(2));
      expect(named(AnalyticsEvents.uploadOfflineAutoResumed), hasLength(2));
    });
  });
}
