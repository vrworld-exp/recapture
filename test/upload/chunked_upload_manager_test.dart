// test/upload/chunked_upload_manager_test.dart
//
// Engine tests for ChunkedUploadManager with in-memory fakes (no network/disk):
// full-session success + monotonic progress, retry without re-uploading completed
// parts, ETag ascending completion, abort on terminal failure + on cancel,
// pause/resume + connectivity-gate behaviour, lifecycle + milestone analytics,
// and the pause→resume continuity suite (per-part PUT count == 1, same-attempt
// uploadId, no re-upload after resume).
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/upload/chunked_upload_manager.dart';
import 'package:recapture/application/upload/multipart_upload_api.dart';
import 'package:recapture/domain/entities/upload_progress.dart';
import 'package:recapture/domain/upload/upload_part_plan.dart';
import 'package:recapture/domain/upload/upload_session_spec.dart';
import 'package:recapture/utils/analytics.dart';
import 'package:recapture/utils/byte_format.dart';

int _pnFromUrl(String url) =>
    int.parse(RegExp(r'/part/(\d+)').firstMatch(url)!.group(1)!);

/// Streams `length` zero-bytes in bounded 64 KiB chunks (never a giant buffer).
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
  final List<List<CompletedPart>> completed = [];
  final List<String> completedUploadIds = [];
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

/// S3 fake that can fail chosen parts N times (transient 500) then succeed.
class _FakeS3 implements S3PartClient {
  _FakeS3({Map<int, int>? failuresRemaining})
      : failuresRemaining = {...?failuresRemaining};
  final Map<int, int> failuresRemaining;
  final List<int> uploaded = [];

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
    final left = failuresRemaining[pn] ?? 0;
    if (left > 0) {
      failuresRemaining[pn] = left - 1;
      throw DioException(
        requestOptions: RequestOptions(path: url),
        type: DioExceptionType.badResponse,
        response: Response(requestOptions: RequestOptions(path: url), statusCode: 500),
      );
    }
    onSendProgress?.call(length, length);
    uploaded.add(pn);
    return 'etag-$pn';
  }
}

/// S3 fake that blocks each part at a gate the test releases — for deterministic
/// pause/resume + connectivity stepping.
class _GatedS3 implements S3PartClient {
  final List<int> started = [];
  final List<int> uploaded = [];
  final Map<int, Completer<void>> _gates = {};
  final Map<int, Completer<void>> _startedWaiters = {};

  Future<void> waitStarted(int pn) =>
      _startedWaiters.putIfAbsent(pn, Completer<void>.new).future;

  void release(int pn) =>
      _gates.putIfAbsent(pn, Completer<void>.new).complete();

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
    started.add(pn);
    final w = _startedWaiters.putIfAbsent(pn, Completer<void>.new);
    if (!w.isCompleted) w.complete();
    await _gates.putIfAbsent(pn, Completer<void>.new).future;
    onSendProgress?.call(length, length);
    uploaded.add(pn);
    return 'etag-$pn';
  }
}

Future<void> _tick([int times = 5]) async {
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

void main() {
  tearDown(() => Analytics.testSink = null);

  test('full session uploads: initiate → parts → complete, monotonic progress', () async {
    final api = _FakeApi();
    final s3 = _FakeS3();
    final manager = ChunkedUploadManager(
      api: api,
      s3: s3,
      byteSource: _ZeroBytes({'f0': 1000, 'f1': 2000}),
    );
    final seen = <UploadProgress>[];
    final sub = manager.watch().listen(seen.add);
    addTearDown(sub.cancel);
    addTearDown(manager.dispose);

    await manager.start(_session([1000, 2000]));

    expect(manager.lastFailureReason, isNull);
    final last = manager.watch();
    final terminal = await last.first;
    expect(terminal.status, UploadStatus.completed);
    expect(terminal.bytesUploaded, 3000);
    expect(terminal.totalBytes, 3000);
    expect(terminal.filesUploaded, 2);
    expect(terminal.totalFiles, 2);
    expect(api.initiated, ['file_0.jpg', 'file_1.jpg']);
    expect(api.completed.length, 2);
    expect(api.aborts, 0);

    // Monotonic bytesUploaded across every emission.
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i].bytesUploaded, greaterThanOrEqualTo(seen[i - 1].bytesUploaded));
    }
  });

  test('transient part failure retried with backoff; completed parts not re-uploaded',
      () async {
    final api = _FakeApi();
    final s3 = _FakeS3(failuresRemaining: {2: 1}); // part 2 fails once
    final retries = <Map<String, Object?>>[];
    Analytics.testSink = (n, p) {
      if (n == AnalyticsEvents.uploadPartRetry) retries.add(p);
    };
    final manager = ChunkedUploadManager(
      api: api,
      s3: s3,
      byteSource: _ZeroBytes({'f0': kS3MinPartSize + 100}), // 2 parts
      maxConcurrentParts: 1,
      chunkSize: kS3MinPartSize,
      retry: const UploadRetryPolicy(maxAttempts: 4),
      sleep: (_) async {}, // no real delay
    );
    addTearDown(manager.dispose);

    await manager.start(_session([kS3MinPartSize + 100]));

    final terminal = await manager.watch().first;
    expect(terminal.status, UploadStatus.completed);
    // Part 1 uploaded exactly once (never re-uploaded); part 2 succeeded on retry.
    expect(s3.uploaded.where((p) => p == 1).length, 1);
    expect(s3.uploaded.where((p) => p == 2).length, 1);
    expect(retries.length, 1);
    expect(retries.single['part_number'], 2);
    expect(retries.single['attempt'], 1);
    expect(api.aborts, 0);
  });

  test('ETags submitted in ascending part-number order', () async {
    final api = _FakeApi();
    // Make part 1 finish LAST by failing it a couple times; part 3/2 finish first.
    final s3 = _FakeS3(failuresRemaining: {1: 2});
    final manager = ChunkedUploadManager(
      api: api,
      s3: s3,
      byteSource: _ZeroBytes({'f0': kS3MinPartSize * 2 + 50}), // 3 parts
      maxConcurrentParts: 3,
      chunkSize: kS3MinPartSize,
      sleep: (_) async {},
    );
    addTearDown(manager.dispose);

    await manager.start(_session([kS3MinPartSize * 2 + 50]));

    expect(api.completed.length, 1);
    final parts = api.completed.single;
    expect(parts.map((p) => p.partNumber).toList(), [1, 2, 3]);
    expect(parts.map((p) => p.etag).toList(), ['etag-1', 'etag-2', 'etag-3']);
  });

  test('terminal part failure aborts the multipart upload', () async {
    final api = _FakeApi();
    final s3 = _FakeS3(failuresRemaining: {1: 99}); // always fails
    final aborted = <Map<String, Object?>>[];
    Analytics.testSink = (n, p) {
      if (n == AnalyticsEvents.uploadMultipartAborted) aborted.add(p);
    };
    final manager = ChunkedUploadManager(
      api: api,
      s3: s3,
      byteSource: _ZeroBytes({'f0': 1000}),
      retry: const UploadRetryPolicy(maxAttempts: 2),
      sleep: (_) async {},
    );
    addTearDown(manager.dispose);

    await manager.start(_session([1000]));

    final terminal = await manager.watch().first;
    expect(terminal.status, UploadStatus.failed);
    expect(manager.lastFailureReason, isNotNull);
    expect(api.aborts, 1);
    expect(api.completed, isEmpty);
    expect(aborted.single['reason'], 'part_failed');
    expect(aborted.single['files_completed'], 0);
  });

  test('cancel aborts the in-flight multipart and ends cancelled', () async {
    final api = _FakeApi();
    final s3 = _GatedS3();
    final manager = ChunkedUploadManager(
      api: api,
      s3: s3,
      byteSource: _ZeroBytes({'f0': 1000}),
      maxConcurrentParts: 1,
    );
    addTearDown(manager.dispose);

    final done = manager.start(_session([1000]));
    await s3.waitStarted(1); // part in flight at the gate
    manager.cancel();
    s3.release(1); // let it settle
    await done;

    final terminal = await manager.watch().first;
    expect(terminal.status, UploadStatus.cancelled);
    expect(api.aborts, 1);
    expect(api.completed, isEmpty);
  });

  test('pause stops new parts; resume finishes without re-uploading', () async {
    final api = _FakeApi();
    final s3 = _GatedS3();
    final manager = ChunkedUploadManager(
      api: api,
      s3: s3,
      byteSource: _ZeroBytes({'f0': kS3MinPartSize + 100}), // 2 parts
      maxConcurrentParts: 1,
      chunkSize: kS3MinPartSize,
    );
    final statuses = <UploadStatus>[];
    final sub = manager.watch().listen((p) => statuses.add(p.status));
    addTearDown(sub.cancel);
    addTearDown(manager.dispose);

    final done = manager.start(_session([kS3MinPartSize + 100]));
    await s3.waitStarted(1);
    manager.pause(); // while part 1 is in flight
    s3.release(1); // part 1 completes; worker then parks at the pause gate
    await _tick();

    expect(s3.uploaded, [1]); // part 2 has NOT started
    expect(s3.started, [1]);
    expect(manager.watch(), isNotNull);
    expect(statuses, contains(UploadStatus.paused));

    manager.resume();
    await s3.waitStarted(2);
    s3.release(2);
    await done;

    final terminal = await manager.watch().first;
    expect(terminal.status, UploadStatus.completed);
    expect(s3.uploaded, [1, 2]); // no re-upload of part 1
    expect(api.completed.single.map((p) => p.partNumber).toList(), [1, 2]);
  });

  test('offline connectivity gate auto-pauses instead of uploading', () async {
    final api = _FakeApi();
    final s3 = _FakeS3();
    var online = false;
    final manager = ChunkedUploadManager(
      api: api,
      s3: s3,
      byteSource: _ZeroBytes({'f0': 1000}),
      maxConcurrentParts: 1,
      isOnline: () => online,
    );
    addTearDown(manager.dispose);

    final done = manager.start(_session([1000]));
    await _tick();
    // Offline → worker auto-paused before uploading any part.
    expect(s3.uploaded, isEmpty);
    expect(manager.watch(), isNotNull);
    final paused = await manager.watch().first;
    expect(paused.status, UploadStatus.paused);

    online = true;
    manager.resume();
    await done;

    final terminal = await manager.watch().first;
    expect(terminal.status, UploadStatus.completed);
    expect(s3.uploaded, [1]);
  });

  group('lifecycle analytics (upload_started/paused/resumed/completed/failed)', () {
    const lifecycle = {
      AnalyticsEvents.uploadStarted,
      AnalyticsEvents.uploadPaused,
      AnalyticsEvents.uploadResumed,
      AnalyticsEvents.uploadCompleted,
      AnalyticsEvents.uploadFailed,
    };

    List<(String, Map<String, Object?>)> sinkLifecycle() {
      final events = <(String, Map<String, Object?>)>[];
      Analytics.testSink = (n, p) {
        if (lifecycle.contains(n)) events.add((n, p));
      };
      return events;
    }

    test('full run: exactly one started then one completed, joined on capture_session_id',
        () async {
      final events = sinkLifecycle();
      final manager = ChunkedUploadManager(
        api: _FakeApi(),
        s3: _FakeS3(),
        byteSource: _ZeroBytes({'f0': 1000, 'f1': 2000}),
      );
      addTearDown(manager.dispose);

      await manager.start(_session([1000, 2000]));

      expect(events.map((e) => e.$1).toList(),
          [AnalyticsEvents.uploadStarted, AnalyticsEvents.uploadCompleted]);
      final (_, started) = events[0];
      expect(started['capture_session_id'], 'sess1');
      expect(started['total_files'], 2);
      expect(started['total_bytes'], 3000);
      expect(started['device_type'], 'mobile');
      final (_, completed) = events[1];
      expect(completed['capture_session_id'], 'sess1');
      expect(completed['total_files'], 2);
      expect(completed['total_bytes'], 3000);
      expect(completed['duration_ms'], isA<int>());
    });

    test('two user pause/resume cycles emit two correctly-paired event pairs', () async {
      final events = sinkLifecycle();
      final s3 = _GatedS3();
      final manager = ChunkedUploadManager(
        api: _FakeApi(),
        s3: s3,
        byteSource: _ZeroBytes({'f0': kS3MinPartSize * 2 + 50}), // 3 parts
        maxConcurrentParts: 1,
        chunkSize: kS3MinPartSize,
      );
      addTearDown(manager.dispose);

      final done = manager.start(_session([kS3MinPartSize * 2 + 50]));
      await s3.waitStarted(1);
      manager.pause();
      s3.release(1);
      await _tick();
      manager.resume();
      await s3.waitStarted(2);
      manager.pause();
      s3.release(2);
      await _tick();
      manager.resume();
      await s3.waitStarted(3);
      s3.release(3);
      await done;

      expect(events.map((e) => e.$1).toList(), [
        AnalyticsEvents.uploadStarted,
        AnalyticsEvents.uploadPaused,
        AnalyticsEvents.uploadResumed,
        AnalyticsEvents.uploadPaused,
        AnalyticsEvents.uploadResumed,
        AnalyticsEvents.uploadCompleted,
      ]);
      for (final (name, props) in events) {
        expect(props['capture_session_id'], 'sess1', reason: name);
      }
      final pauses = events.where((e) => e.$1 == AnalyticsEvents.uploadPaused);
      expect(pauses.map((e) => e.$2['pause_reason']), everyElement('user'));
    });

    test('connectivity auto-pause carries pause_reason "connectivity"', () async {
      final events = sinkLifecycle();
      var online = false;
      final manager = ChunkedUploadManager(
        api: _FakeApi(),
        s3: _FakeS3(),
        byteSource: _ZeroBytes({'f0': 1000}),
        maxConcurrentParts: 1,
        isOnline: () => online,
      );
      addTearDown(manager.dispose);

      final done = manager.start(_session([1000]));
      await _tick();
      online = true;
      manager.resume();
      await done;

      expect(events.map((e) => e.$1).toList(), [
        AnalyticsEvents.uploadStarted,
        AnalyticsEvents.uploadPaused,
        AnalyticsEvents.uploadResumed,
        AnalyticsEvents.uploadCompleted,
      ]);
      final (_, paused) = events[1];
      expect(paused['pause_reason'], 'connectivity');
    });

    test('terminal failure: one upload_failed with failure_reason; part retries emit no lifecycle events',
        () async {
      final events = sinkLifecycle();
      final manager = ChunkedUploadManager(
        api: _FakeApi(),
        s3: _FakeS3(failuresRemaining: {1: 99}), // always fails
        byteSource: _ZeroBytes({'f0': 1000}),
        retry: const UploadRetryPolicy(maxAttempts: 3), // 2 in-run part retries
        sleep: (_) async {},
      );
      addTearDown(manager.dispose);

      await manager.start(_session([1000]));

      // Retries happened inside the run yet only the started/failed edges emit.
      expect(events.map((e) => e.$1).toList(),
          [AnalyticsEvents.uploadStarted, AnalyticsEvents.uploadFailed]);
      final (_, failed) = events[1];
      expect(failed['failure_reason'], isNotEmpty);
      expect(failed['files_uploaded'], 0);
      expect(failed['bytes_uploaded'], isA<int>());
    });

    test('cancel emits NO lifecycle event (not a failure, not a completion)', () async {
      final events = sinkLifecycle();
      final s3 = _GatedS3();
      final manager = ChunkedUploadManager(
        api: _FakeApi(),
        s3: s3,
        byteSource: _ZeroBytes({'f0': 1000}),
        maxConcurrentParts: 1,
      );
      addTearDown(manager.dispose);

      final done = manager.start(_session([1000]));
      await s3.waitStarted(1);
      manager.cancel();
      s3.release(1);
      await done;

      expect(events.map((e) => e.$1).toList(), [AnalyticsEvents.uploadStarted]);
    });

    test('new watch() subscribers (rebuild/replay) never re-emit lifecycle events', () async {
      final events = sinkLifecycle();
      final manager = ChunkedUploadManager(
        api: _FakeApi(),
        s3: _FakeS3(),
        byteSource: _ZeroBytes({'f0': 1000}),
      );
      addTearDown(manager.dispose);

      await manager.start(_session([1000]));
      // Simulate UI rebuilds re-subscribing to the replayed snapshot.
      await manager.watch().first;
      await manager.watch().first;

      expect(events.map((e) => e.$1).toList(),
          [AnalyticsEvents.uploadStarted, AnalyticsEvents.uploadCompleted]);
    });
  });

  group('upload_progress milestones (25/50/75/100) + upload_size_mb', () {
    List<(String, Map<String, Object?>)> sinkAll() {
      final events = <(String, Map<String, Object?>)>[];
      Analytics.testSink = (n, p) => events.add((n, p));
      return events;
    }

    List<Map<String, Object?>> milestonesOf(
            List<(String, Map<String, Object?>)> events) =>
        [
          for (final (n, p) in events)
            if (n == AnalyticsEvents.uploadProgress) p,
        ];

    test('tiny upload: all four milestones fire once, in order, alongside upload_completed',
        () async {
      final events = sinkAll();
      final manager = ChunkedUploadManager(
        api: _FakeApi(),
        s3: _FakeS3(),
        byteSource: _ZeroBytes({'f0': 1000}),
      );
      addTearDown(manager.dispose);

      await manager.start(_session([1000]));

      final milestones = milestonesOf(events);
      expect(milestones.map((p) => p['milestone_pct']).toList(), [25, 50, 75, 100]);
      for (final p in milestones) {
        expect(p['capture_session_id'], 'sess1');
        expect(p['upload_size_mb'], bytesToMb(1000));
        expect(p['bytes_uploaded'], isA<int>());
        expect(p['device_type'], 'mobile');
      }
      // 100% milestone coexists with (does not replace) upload_completed.
      expect(events.where((e) => e.$1 == AnalyticsEvents.uploadCompleted), hasLength(1));
      // upload_size_mb also rides started/completed (size known up front).
      final started =
          events.firstWhere((e) => e.$1 == AnalyticsEvents.uploadStarted).$2;
      expect(started['upload_size_mb'], bytesToMb(1000));
    });

    test('pause/resume mid-upload never re-fires an already-passed milestone', () async {
      final events = sinkAll();
      final s3 = _GatedS3();
      final manager = ChunkedUploadManager(
        api: _FakeApi(),
        s3: s3,
        byteSource: _ZeroBytes({'f0': kS3MinPartSize * 2 + 50}), // 3 parts
        maxConcurrentParts: 1,
        chunkSize: kS3MinPartSize,
      );
      addTearDown(manager.dispose);

      final done = manager.start(_session([kS3MinPartSize * 2 + 50]));
      await s3.waitStarted(1);
      s3.release(1); // ~50% confirmed → 25 fires
      await s3.waitStarted(2);
      manager.pause();
      s3.release(2); // ~99% confirmed while pausing → 50/75 fire
      await _tick();
      manager.resume();
      await s3.waitStarted(3);
      s3.release(3);
      await done;

      // Exactly one of each — the pause/resume cycle re-fired nothing.
      expect(
        milestonesOf(events).map((p) => p['milestone_pct']).toList(),
        [25, 50, 75, 100],
      );
    });

    test('failure mid-upload: only reached milestones fired; 100 never fires', () async {
      final events = sinkAll();
      final manager = ChunkedUploadManager(
        api: _FakeApi(),
        s3: _FakeS3(failuresRemaining: {2: 99}), // part 2 always fails
        byteSource: _ZeroBytes({'f0': kS3MinPartSize + 100}), // 2 parts
        maxConcurrentParts: 1,
        chunkSize: kS3MinPartSize,
        retry: const UploadRetryPolicy(maxAttempts: 2),
        sleep: (_) async {},
      );
      addTearDown(manager.dispose);

      await manager.start(_session([kS3MinPartSize + 100]));

      // Only part 1 confirms (~99.99% of bytes — pct floors to 99, never 100).
      final fired = milestonesOf(events).map((p) => p['milestone_pct']).toList();
      expect(fired, isNot(contains(100)));
      expect(fired, containsAllInOrder([25, 50]));
      expect(events.where((e) => e.$1 == AnalyticsEvents.uploadFailed), hasLength(1));
    });

    test('fresh re-attempt after failure resets milestones and reports them again',
        () async {
      final events = sinkAll();
      final s3 = _FakeS3(failuresRemaining: {1: 2}); // fails twice, then works
      final manager = ChunkedUploadManager(
        api: _FakeApi(),
        s3: s3,
        byteSource: _ZeroBytes({'f0': 1000}),
        retry: const UploadRetryPolicy(maxAttempts: 2),
        sleep: (_) async {},
      );
      addTearDown(manager.dispose);

      await manager.start(_session([1000])); // run 1: fails at 0% — no milestones
      expect(milestonesOf(events), isEmpty);

      await manager.start(_session([1000])); // run 2: fresh attempt succeeds
      expect(
        milestonesOf(events).map((p) => p['milestone_pct']).toList(),
        [25, 50, 75, 100],
      );
    });

    test('zero-byte session: no percentage, no milestone, no crash', () async {
      final events = sinkAll();
      final manager = ChunkedUploadManager(
        api: _FakeApi(),
        s3: _FakeS3(),
        byteSource: _ZeroBytes({'f0': 0}),
      );
      addTearDown(manager.dispose);

      await manager.start(_session([0]));

      expect(milestonesOf(events), isEmpty);
      final terminal = await manager.watch().first;
      expect(terminal.status, UploadStatus.completed);
    });
  });

  // ── Pause → resume continuity: no re-upload, same attempt ────────────────────
  //
  // Guards the engine's most expensive failure mode: a resume that silently
  // restarts or re-sends data. Core invariant asserted in every case: per-part
  // PUT count == 1 across the entire run. Attempt continuity is asserted via
  // api.initiated (one initiate per file — a restart would re-initiate) and the
  // uploadId passed to complete() (the ORIGINAL id, not a fresh one).
  //
  // ENGINE GUARANTEE for a mid-flight pause (documented in pause()/
  // _awaitIfPaused): the in-flight part PUT is NOT cancelled — it finishes and
  // confirms while paused; the worker then parks BEFORE the next part. So the
  // interrupted part uploads exactly once, and pause leaves a clean
  // "parts 1..N done, N+1 not started" boundary.
  group('pause → resume continues from the same part (no re-upload)', () {
    /// Per-part PUT attempt counts (every putPart call, including any re-PUT).
    Map<int, int> putCounts(_GatedS3 s3) {
      final counts = <int, int>{};
      for (final pn in s3.started) {
        counts[pn] = (counts[pn] ?? 0) + 1;
      }
      return counts;
    }

    test('clean boundary: part 1 done at pause; resume starts at part 2; every part PUT once',
        () async {
      final api = _FakeApi();
      final s3 = _GatedS3();
      final manager = ChunkedUploadManager(
        api: api,
        s3: s3,
        byteSource: _ZeroBytes({'f0': kS3MinPartSize * 2 + 50}), // parts 1,2,3
        maxConcurrentParts: 1,
        chunkSize: kS3MinPartSize,
      );
      final snapshots = <UploadProgress>[];
      final sub = manager.watch().listen(snapshots.add);
      addTearDown(sub.cancel);
      addTearDown(manager.dispose);

      final done = manager.start(_session([kS3MinPartSize * 2 + 50]));
      await s3.waitStarted(1);
      manager.pause(); // in-flight part 1 will finish; worker parks before part 2
      s3.release(1);
      await _tick(10);

      // Paused at the clean boundary: part 1 confirmed, part 2 never started,
      // and no further PUTs happen while paused.
      expect(manager.currentStatus, UploadStatus.paused);
      expect(s3.uploaded, [1]);
      expect(s3.started, [1]);
      final bytesAtPause = snapshots.last.bytesUploaded;
      expect(bytesAtPause, kS3MinPartSize); // part 1 fully confirmed, nothing more
      await _tick(10);
      expect(s3.started, [1], reason: 'no PUTs may be issued while paused');

      manager.resume();
      await s3.waitStarted(2);
      // First work after resume is the NEXT part — not a restart from part 1.
      expect(s3.started, [1, 2]);
      s3.release(2);
      await s3.waitStarted(3);
      s3.release(3);
      await done;
      await _tick(); // let the broadcast stream deliver the final snapshot

      // Every part PUT exactly once across the whole run.
      expect(putCounts(s3), {1: 1, 2: 1, 3: 1});
      expect(s3.uploaded, [1, 2, 3]);

      // Same multipart attempt end-to-end: one initiate, completed with the
      // ORIGINAL uploadId, ETags collected once each.
      expect(api.initiated, ['file_0.jpg']);
      expect(api.completedUploadIds, ['u-file_0.jpg']);
      expect(api.aborts, 0);
      final parts = api.completed.single;
      expect(parts.map((p) => p.partNumber).toList(), [1, 2, 3]);
      expect(parts.map((p) => p.etag).toList(), ['etag-1', 'etag-2', 'etag-3']);

      // bytesUploaded: monotonic across the pause/resume boundary, exact total
      // at completion (a re-sent part would double-count and overshoot the
      // pre-clamp candidate; a restart would dip).
      for (var i = 1; i < snapshots.length; i++) {
        expect(snapshots[i].bytesUploaded,
            greaterThanOrEqualTo(snapshots[i - 1].bytesUploaded));
      }
      expect(snapshots.last.status, UploadStatus.completed);
      expect(snapshots.last.bytesUploaded, kS3MinPartSize * 2 + 50);
    });

    test('mid-flight pause: the interrupted part uploads exactly once', () async {
      final api = _FakeApi();
      final s3 = _GatedS3();
      final manager = ChunkedUploadManager(
        api: api,
        s3: s3,
        byteSource: _ZeroBytes({'f0': kS3MinPartSize * 2 + 50}),
        maxConcurrentParts: 1,
        chunkSize: kS3MinPartSize,
      );
      addTearDown(manager.dispose);

      final done = manager.start(_session([kS3MinPartSize * 2 + 50]));
      await s3.waitStarted(1);
      s3.release(1);
      await s3.waitStarted(2); // part 2 now mid-flight
      manager.pause();
      s3.release(2); // engine finishes the in-flight PUT (never cancels/re-sends it)
      await _tick(10);

      expect(manager.currentStatus, UploadStatus.paused);
      expect(s3.uploaded, [1, 2], reason: 'interrupted part finished while paused');
      expect(putCounts(s3)[2], 1, reason: 'the in-flight part is never re-sent');

      manager.resume();
      await s3.waitStarted(3);
      s3.release(3);
      await done;

      expect(putCounts(s3), {1: 1, 2: 1, 3: 1});
      expect(api.initiated, ['file_0.jpg']); // same attempt
      expect((await manager.watch().first).status, UploadStatus.completed);
    });

    test('multiple pause/resume cycles across files: no part ever PUT twice', () async {
      final api = _FakeApi();
      final s3 = _GatedS3();
      final manager = ChunkedUploadManager(
        api: api,
        s3: s3,
        // file_0: parts 1,2 — file_1: part 1 (distinct URLs per file, but the
        // gate/record is keyed by part number; file_1's single part re-uses
        // gate 1 only AFTER it was released, so sequencing stays deterministic
        // with maxConcurrentParts: 1 and explicit waits.
        byteSource: _ZeroBytes({'f0': kS3MinPartSize + 100, 'f1': 900}),
        maxConcurrentParts: 1,
        chunkSize: kS3MinPartSize,
      );
      addTearDown(manager.dispose);

      final done = manager.start(_session([kS3MinPartSize + 100, 900]));
      // Cycle 1: pause during file_0 part 1.
      await s3.waitStarted(1);
      manager.pause();
      s3.release(1);
      await _tick(10);
      expect(manager.currentStatus, UploadStatus.paused);
      manager.resume();

      // Cycle 2: pause during file_0 part 2.
      await s3.waitStarted(2);
      manager.pause();
      s3.release(2);
      await _tick(10);
      expect(manager.currentStatus, UploadStatus.paused);
      expect(api.initiated, ['file_0.jpg'],
          reason: 'file_1 must not be initiated while paused');
      manager.resume();
      await done; // file_1's part reuses the already-released gate 1

      // file_0 parts 1,2 PUT once each + file_1 part 1 PUT once (gate 1 records
      // two entries for part number 1 — one per FILE — both exactly once).
      expect(putCounts(s3), {1: 2, 2: 1});
      expect(s3.started, [1, 2, 1]);
      expect(api.initiated, ['file_0.jpg', 'file_1.jpg']); // once per file
      expect(api.completedUploadIds, ['u-file_0.jpg', 'u-file_1.jpg']);
      expect(api.aborts, 0);
      final terminal = await manager.watch().first;
      expect(terminal.status, UploadStatus.completed);
      expect(terminal.bytesUploaded, kS3MinPartSize + 100 + 900);
    });

    test('pause before any part starts: resume proceeds from part 1 without duplicates',
        () async {
      final api = _FakeApi();
      final s3 = _GatedS3();
      final manager = ChunkedUploadManager(
        api: api,
        s3: s3,
        byteSource: _ZeroBytes({'f0': 1000}),
        maxConcurrentParts: 1,
      );
      addTearDown(manager.dispose);

      final done = manager.start(_session([1000]));
      manager.pause(); // status is inProgress synchronously; no part started yet
      await _tick(10);
      expect(s3.started, isEmpty, reason: 'paused before the first PUT');
      expect(manager.currentStatus, UploadStatus.paused);

      manager.resume();
      await s3.waitStarted(1);
      s3.release(1);
      await done;

      expect(putCounts(s3), {1: 1});
      expect(api.initiated, ['file_0.jpg']);
      expect((await manager.watch().first).status, UploadStatus.completed);
    });

    test('pause at the last part: resume finalizes without re-PUT of earlier parts',
        () async {
      final api = _FakeApi();
      final s3 = _GatedS3();
      final manager = ChunkedUploadManager(
        api: api,
        s3: s3,
        byteSource: _ZeroBytes({'f0': kS3MinPartSize * 2 + 50}),
        maxConcurrentParts: 1,
        chunkSize: kS3MinPartSize,
      );
      addTearDown(manager.dispose);

      final done = manager.start(_session([kS3MinPartSize * 2 + 50]));
      await s3.waitStarted(1);
      s3.release(1);
      await s3.waitStarted(2);
      s3.release(2);
      await s3.waitStarted(3); // last part mid-flight
      manager.pause();
      s3.release(3);
      await _tick(10);
      expect(manager.currentStatus, UploadStatus.paused);
      expect(api.completed, isEmpty, reason: 'finalize must not run while paused');

      manager.resume();
      await done;

      expect(putCounts(s3), {1: 1, 2: 1, 3: 1});
      expect(api.completed.single.map((p) => p.partNumber).toList(), [1, 2, 3]);
      expect(api.completedUploadIds, ['u-file_0.jpg']);
      expect((await manager.watch().first).status, UploadStatus.completed);
    });

    test('resume when not paused / double resume: no duplicates, no crash', () async {
      final api = _FakeApi();
      final s3 = _GatedS3();
      final manager = ChunkedUploadManager(
        api: api,
        s3: s3,
        byteSource: _ZeroBytes({'f0': kS3MinPartSize + 100}), // 2 parts
        maxConcurrentParts: 1,
        chunkSize: kS3MinPartSize,
      );
      addTearDown(manager.dispose);

      final done = manager.start(_session([kS3MinPartSize + 100]));
      await s3.waitStarted(1);
      manager.resume(); // not paused → documented no-op
      s3.release(1);
      await s3.waitStarted(2);
      manager.pause();
      manager.resume();
      manager.resume(); // double resume → second is a no-op
      s3.release(2);
      await done;

      expect(putCounts(s3), {1: 1, 2: 1});
      expect(api.initiated, ['file_0.jpg']);
      expect((await manager.watch().first).status, UploadStatus.completed);
    });
  });

}
