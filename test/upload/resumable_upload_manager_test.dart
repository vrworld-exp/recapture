// test/upload/resumable_upload_manager_test.dart
//
// Resume behaviour of ChunkedUploadManager with an injected UploadProgressStore:
// persist offset+ETag only on confirm, resume skips completed parts + reuses the
// uploadId + finalizes with the full ETag list, crash-window re-upload, uploadId
// re-initiate, and cancel clears persisted state.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/upload/chunked_upload_manager.dart';
import 'package:recapture/application/upload/multipart_upload_api.dart';
import 'package:recapture/data/local/upload_progress_box.dart';
import 'package:recapture/domain/upload/file_upload_progress.dart';
import 'package:recapture/domain/upload/upload_part_plan.dart';
import 'package:recapture/domain/upload/upload_session_spec.dart';

const _min = kS3MinPartSize;

// URL shape: https://s3/{uploadId}/{key}/part/{n}
final _urlRe = RegExp(r'https://s3/([^/]+)/[^/]+/part/(\d+)');

class _Api implements MultipartUploadApi {
  int initiateCount = 0;
  final List<List<CompletedPart>> completes = [];
  int aborts = 0;

  @override
  Future<InitiatedUpload> initiate({
    required String sessionId,
    required String fileKey,
    required int fileSize,
    required int partCount,
  }) async {
    initiateCount++;
    final uid = 'U$initiateCount';
    return InitiatedUpload(
      uploadId: uid,
      key: fileKey,
      parts: [
        for (var n = 1; n <= partCount; n++)
          PresignedPart(partNumber: n, url: 'https://s3/$uid/$fileKey/part/$n'),
      ],
    );
  }

  @override
  Future<String?> refreshPartUrl({
    required String uploadId,
    required String key,
    required int partNumber,
  }) async =>
      'https://s3/$uploadId/$key/part/$partNumber';

  @override
  Future<void> complete({
    required String uploadId,
    required String key,
    required List<CompletedPart> parts,
  }) async =>
      completes.add(parts);

  @override
  Future<void> abort({required String uploadId, required String key}) async =>
      aborts++;
}

class _S3 implements S3PartClient {
  _S3({this.invalidUploadIds = const {}});
  final Set<String> invalidUploadIds;
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
    final m = _urlRe.firstMatch(url)!;
    final uid = m.group(1)!;
    final pn = int.parse(m.group(2)!);
    if (invalidUploadIds.contains(uid)) {
      throw DioException(
        requestOptions: RequestOptions(path: url),
        type: DioExceptionType.badResponse,
        response: Response(
            requestOptions: RequestOptions(path: url),
            statusCode: 404,
            data: 'NoSuchUpload'),
      );
    }
    onSendProgress?.call(length, length);
    uploaded.add(pn);
    return 'etag-$uid-$pn';
  }
}

/// Gated S3 for the cancel test.
class _GatedS3 implements S3PartClient {
  final Map<int, Completer<void>> _gates = {};
  final Map<int, Completer<void>> _started = {};
  Future<void> waitStarted(int pn) =>
      _started.putIfAbsent(pn, Completer<void>.new).future;
  void release(int pn) => _gates.putIfAbsent(pn, Completer<void>.new).complete();

  @override
  Future<String> putPart({
    required String url,
    required Stream<List<int>> body,
    required int length,
    void Function(int sent, int total)? onSendProgress,
    required CancelToken cancelToken,
  }) async {
    await body.drain<void>();
    final m = _urlRe.firstMatch(url)!;
    final pn = int.parse(m.group(2)!);
    final w = _started.putIfAbsent(pn, Completer<void>.new);
    if (!w.isCompleted) w.complete();
    await _gates.putIfAbsent(pn, Completer<void>.new).future;
    return 'etag-$pn';
  }
}

/// Spy over the in-memory store: records recordPartComplete + clearSession.
class _SpyStore implements UploadProgressStore {
  final InMemoryUploadProgressStore inner = InMemoryUploadProgressStore();
  final List<({int partNumber, String etag, int offset})> recorded = [];
  int clearSessionCount = 0;

  @override
  Future<FileUploadProgress?> get(String s, String f) => inner.get(s, f);
  @override
  Future<void> begin(String s, String f,
          {required String uploadId,
          required String objectKey,
          required int totalParts,
          required int totalBytes}) =>
      inner.begin(s, f,
          uploadId: uploadId,
          objectKey: objectKey,
          totalParts: totalParts,
          totalBytes: totalBytes);
  @override
  Future<void> recordPartComplete(String s, String f,
      {required int partNumber, required String etag, required int offset}) {
    recorded.add((partNumber: partNumber, etag: etag, offset: offset));
    return inner.recordPartComplete(s, f,
        partNumber: partNumber, etag: etag, offset: offset);
  }

  @override
  Future<void> markFileComplete(String s, String f) => inner.markFileComplete(s, f);
  @override
  Future<void> clearFile(String s, String f) => inner.clearFile(s, f);
  @override
  Future<void> clearSession(String s) {
    clearSessionCount++;
    return inner.clearSession(s);
  }

  @override
  Future<List<FileUploadProgress>> listSession(String s) => inner.listSession(s);
}

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

UploadSessionSpec _session(String sessionId, int size) => UploadSessionSpec(
      sessionId: sessionId,
      files: [UploadFileSpec(path: 'f0', key: 'file_0.jpg', size: size)],
    );

ChunkedUploadManager _manager(
  _Api api,
  S3PartClient s3,
  UploadProgressStore store, {
  int concurrency = 1,
}) =>
    ChunkedUploadManager(
      api: api,
      s3: s3,
      store: store,
      byteSource: _ZeroBytes({'f0': _min * 2 + 50}),
      maxConcurrentParts: concurrency,
      chunkSize: _min,
      sleep: (_) async {},
    );

void main() {
  test('offset advances only on confirm; ETag+offset persisted atomically', () async {
    final api = _Api();
    final s3 = _S3();
    final store = _SpyStore();
    await _manager(api, s3, store).start(_session('sess', _min * 2 + 50));

    // One record per part, in confirm order, offsets = running confirmed totals.
    expect(store.recorded.map((r) => r.partNumber).toList(), [1, 2, 3]);
    expect(store.recorded.map((r) => r.offset).toList(),
        [_min, _min * 2, _min * 2 + 50]);
    // Each record carries the part's real ETag (persisted together with offset).
    expect(store.recorded[0].etag, 'etag-U1-1');
    // Session finalized and its bookkeeping cleared.
    expect(api.completes.single.map((p) => p.partNumber).toList(), [1, 2, 3]);
    expect(store.clearSessionCount, greaterThanOrEqualTo(1));
    expect(await store.get('sess', 'file_0.jpg'), isNull);
  });

  test('resume reuses uploadId, skips confirmed parts, finalizes full ETag list',
      () async {
    final api = _Api();
    final s3 = _S3();
    final store = _SpyStore();
    // Prior partial run: uploadId U-pre, part 1 confirmed.
    await store.begin('sess', 'file_0.jpg',
        uploadId: 'U-pre',
        objectKey: 'file_0.jpg',
        totalParts: 3,
        totalBytes: _min * 2 + 50);
    await store.recordPartComplete('sess', 'file_0.jpg',
        partNumber: 1, etag: 'PRE-1', offset: _min);
    store.recorded.clear();

    await _manager(api, s3, store).start(_session('sess', _min * 2 + 50));

    // Reused the server uploadId — never re-initiated.
    expect(api.initiateCount, 0);
    // Only the remaining parts were uploaded (part 1 not re-sent).
    expect(s3.uploaded, [2, 3]);
    // Finalized with the FULL ETag list, ascending, part 1's ETag from persistence.
    final finalParts = api.completes.single;
    expect(finalParts.map((p) => p.partNumber).toList(), [1, 2, 3]);
    expect(finalParts.first.etag, 'PRE-1');
    expect(finalParts[1].etag, 'etag-U-pre-2');
  });

  test('all parts confirmed but not finalized → resume just finalizes', () async {
    final api = _Api();
    final s3 = _S3();
    final store = _SpyStore();
    await store.begin('sess', 'file_0.jpg',
        uploadId: 'U-pre',
        objectKey: 'file_0.jpg',
        totalParts: 3,
        totalBytes: _min * 2 + 50);
    for (var n = 1; n <= 3; n++) {
      await store.recordPartComplete('sess', 'file_0.jpg',
          partNumber: n, etag: 'PRE-$n', offset: _min * n);
    }

    await _manager(api, s3, store).start(_session('sess', _min * 2 + 50));

    expect(api.initiateCount, 0);
    expect(s3.uploaded, isEmpty); // nothing re-uploaded
    expect(api.completes.single.map((p) => p.etag).toList(),
        ['PRE-1', 'PRE-2', 'PRE-3']);
  });

  test('crash-window: a part missing from persistence is re-uploaded, never skipped',
      () async {
    final api = _Api();
    final s3 = _S3();
    final store = _SpyStore();
    // Server had part 2 before the crash, but only part 1 got persisted.
    await store.begin('sess', 'file_0.jpg',
        uploadId: 'U-pre',
        objectKey: 'file_0.jpg',
        totalParts: 3,
        totalBytes: _min * 2 + 50);
    await store.recordPartComplete('sess', 'file_0.jpg',
        partNumber: 1, etag: 'PRE-1', offset: _min);

    await _manager(api, s3, store).start(_session('sess', _min * 2 + 50));

    // Part 2 (unpersisted) is re-uploaded — at-least-once, never skipped.
    expect(s3.uploaded, [2, 3]);
    expect(api.completes.single.map((p) => p.partNumber).toList(), [1, 2, 3]);
  });

  test('invalid/expired uploadId → re-initiate once, no loop, then completes',
      () async {
    final api = _Api();
    final s3 = _S3(invalidUploadIds: {'STALE'});
    final store = _SpyStore();
    await store.begin('sess', 'file_0.jpg',
        uploadId: 'STALE',
        objectKey: 'file_0.jpg',
        totalParts: 3,
        totalBytes: _min * 2 + 50);
    await store.recordPartComplete('sess', 'file_0.jpg',
        partNumber: 1, etag: 'PRE-1', offset: _min);

    await _manager(api, s3, store).start(_session('sess', _min * 2 + 50));

    // Re-initiated exactly once (fresh uploadId), then all parts uploaded fresh.
    expect(api.initiateCount, 1);
    expect(s3.uploaded..sort(), [1, 2, 3]);
    expect(api.completes.single.map((p) => p.partNumber).toList(), [1, 2, 3]);
    expect(api.completes.single.first.etag, 'etag-U1-1'); // fresh, not PRE-1
  });

  test('cancel clears the persisted session state', () async {
    final api = _Api();
    final s3 = _GatedS3();
    final store = _SpyStore();
    final manager = ChunkedUploadManager(
      api: api,
      s3: s3,
      store: store,
      byteSource: _ZeroBytes({'f0': 1000}), // 1 part
      maxConcurrentParts: 1,
      chunkSize: _min,
    );

    final done = manager.start(_session('sess', 1000));
    await s3.waitStarted(1);
    manager.cancel();
    s3.release(1);
    await done;

    expect(store.clearSessionCount, greaterThanOrEqualTo(1));
    expect(await store.get('sess', 'file_0.jpg'), isNull);
  });
}
