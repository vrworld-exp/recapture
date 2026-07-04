// test/upload/chunked_upload_manager_test.dart
//
// Engine tests for ChunkedUploadManager with in-memory fakes (no network/disk):
// full-session success + monotonic progress, retry without re-uploading completed
// parts, ETag ascending completion, abort on terminal failure + on cancel, and
// pause/resume + connectivity-gate behaviour.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/upload/chunked_upload_manager.dart';
import 'package:recapture/application/upload/multipart_upload_api.dart';
import 'package:recapture/domain/entities/upload_progress.dart';
import 'package:recapture/domain/upload/upload_part_plan.dart';
import 'package:recapture/domain/upload/upload_session_spec.dart';
import 'package:recapture/utils/analytics.dart';

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
  }) async =>
      completed.add(parts);

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
}
