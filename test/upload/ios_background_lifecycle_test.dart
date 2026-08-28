// test/upload/ios_background_lifecycle_test.dart
//
// iOS BACKGROUND-UPLOAD CONTRACT RECORD — reaction-level tests.
//
// ── The contract, established from the code (2026-07-05) ────────────────────
// **NOT IMPLEMENTED.** Neither background-continuation (contract A) nor
// pause-on-background/resume-on-foreground (contract B) exists in the upload
// pipeline today:
//   • Nothing in the upload stack observes app lifecycle. The only
//     WidgetsBindingObservers in lib/ are camera/UI concerns (capture screen,
//     permissions screen, intro animation) — grep-verified.
//   • A native iOS background transport DOES exist
//     (ios/Runner/BackgroundUploadManager.swift — URLSession .background —
//     bridged by lib/platform/upload_background_session.dart), but it is a
//     whole-file PUT transport that is NOT wired into this multipart engine
//     or any pipeline. Its existence does not change the engine's behavior.
//   • ChunkedUploadManager is pure Dart over Dio: on a real iOS device it
//     keeps uploading only until the OS suspends the process, then its
//     sockets freeze. That suspension CANNOT be reproduced in `flutter test`.
//
// What these tests therefore pin is the engine's REACTION to lifecycle
// events — which is, by design-as-built, NO reaction: backgrounding neither
// pauses, cancels, restarts, nor duplicates anything. If someone later wires
// contract A (hand-off to the native background session) or contract B
// (auto-pause on `paused`), the contract-pin test below FAILS — that is the
// intended tripwire forcing this record to be rewritten against the new
// contract, not a regression.
//
// ── Fidelity ─────────────────────────────────────────────────────────────────
// REACTION-LEVEL ONLY. `handleAppLifecycleStateChanged` delivers the same
// callbacks iOS would, but does NOT suspend the isolate, freeze sockets, or
// exercise a real background URLSession. OS-suspension behavior is NOT
// provable here (no integration_test harness exists in this repo, and the
// iOS simulator does not faithfully suspend apps either).
//
// ── Manual QA — physical iOS device (required for the OS-level guarantee) ──
//   1. Start a large multi-file upload on a real iPhone.
//   2. Background the app mid-upload (Home / app switcher); leave it several
//      minutes. Expected TODAY: parts stop arriving server-side once iOS
//      suspends the process (no native hand-off is wired).
//   3. Foreground the app. Expected TODAY: in-flight Dio PUTs that died
//      surface as retryable failures; SessionRetryPolicy/resume applies; no
//      part may be duplicated (same multipart uploadId, per-part PUT == 1
//      server-side).
//   4. Repeat with screen locked, and with another app foregrounded.
//   5. OS-kill while backgrounded (memory pressure): cold-resume from the
//      persisted UploadProgressStore is a SEPARATE guarantee — record
//      whether the session restarts or resumes; not asserted here.
//   6. Record which contract the product ultimately wants (A: wire
//      BackgroundUploadManager; B: lifecycle auto-pause) — then replace this
//      file's contract pin.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
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

/// S3 fake that blocks each part at a gate the test releases — deterministic
/// stepping so lifecycle events land at exact part boundaries / mid-flight.
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

/// Per-part PUT attempt counts (every putPart call, including any re-PUT) —
/// the shared no-duplicate invariant from the pause/resume suite.
Map<int, int> _putCounts(_GatedS3 s3) {
  final counts = <int, int>{};
  for (final pn in s3.started) {
    counts[pn] = (counts[pn] ?? 0) + 1;
  }
  return counts;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  /// Delivers the same lifecycle sequence iOS sends on backgrounding. This is
  /// the CALLBACK only — the isolate keeps running (see header: reaction-level).
  void goBackground() {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  }

  void goForeground() {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }

  setUp(() =>
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
  tearDown(() {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    Analytics.testSink = null;
  });

  test(
      'CONTRACT PIN (not-implemented): backgrounding mid-upload neither pauses '
      'the engine nor duplicates parts; same attempt completes', () async {
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
    s3.release(1); // clean boundary: part 1 confirmed

    goBackground(); // ← the transition under test
    await _tick(10);

    // NOT contract B: the engine does not observe lifecycle, so it does NOT
    // pause. (If auto-pause is ever wired, this line fails — rewrite this file
    // against the new contract.)
    expect(manager.currentStatus, UploadStatus.inProgress,
        reason: 'no lifecycle observer exists — backgrounding must not pause');

    // While "backgrounded" (process still alive — exactly the pre-suspension
    // window on a real device) the engine keeps uploading the NEXT part; it
    // does not cancel or restart from part 1.
    await s3.waitStarted(2);
    expect(s3.started, [1, 2],
        reason: 'proceeds to the next part; never re-PUTs part 1');
    s3.release(2);

    goForeground(); // returning to foreground is equally a no-op
    await s3.waitStarted(3);
    s3.release(3);
    await done;
    await _tick();

    // The shared cross-cutting invariants, across both transitions:
    // every part PUT exactly once, same multipart attempt end-to-end,
    // monotonic bytes, clean completion.
    expect(_putCounts(s3), {1: 1, 2: 1, 3: 1});
    expect(api.initiated, ['file_0.jpg']);
    expect(api.completedUploadIds, ['u-file_0.jpg']);
    expect(api.aborts, 0);
    for (var i = 1; i < snapshots.length; i++) {
      expect(snapshots[i].bytesUploaded,
          greaterThanOrEqualTo(snapshots[i - 1].bytesUploaded));
    }
    expect(snapshots.last.status, UploadStatus.completed);
    expect(snapshots.last.bytesUploaded, kS3MinPartSize * 2 + 50);
  });

  test(
      'no upload_paused/upload_resumed analytics fire on lifecycle edges '
      '(there is no transition to report)', () async {
    final events = <String>[];
    Analytics.testSink = (name, _) => events.add(name);

    final api = _FakeApi();
    final s3 = _GatedS3();
    final manager = ChunkedUploadManager(
      api: api,
      s3: s3,
      byteSource: _ZeroBytes({'f0': kS3MinPartSize + 50}), // parts 1,2
      maxConcurrentParts: 1,
      chunkSize: kS3MinPartSize,
    );
    addTearDown(manager.dispose);

    final done = manager.start(_session([kS3MinPartSize + 50]));
    await s3.waitStarted(1);
    goBackground();
    s3.release(1);
    await s3.waitStarted(2);
    goForeground();
    s3.release(2);
    await done;

    expect(events, isNot(contains(AnalyticsEvents.uploadPaused)),
        reason: 'no auto-pause exists, so no paused event may fire');
    expect(events, isNot(contains(AnalyticsEvents.uploadResumed)));
    expect(events.where((e) => e == AnalyticsEvents.uploadStarted).length, 1);
    expect(events.where((e) => e == AnalyticsEvents.uploadCompleted).length, 1);
  });

  test('multiple background/foreground cycles: no part ever PUT twice',
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
    addTearDown(manager.dispose);

    final done = manager.start(_session([kS3MinPartSize * 2 + 50]));
    await s3.waitStarted(1);
    goBackground(); // cycle 1: background while part 1 is mid-flight
    s3.release(1);
    await _tick(10);
    goForeground();
    goBackground(); // cycle 2: rapid double transition between parts
    await s3.waitStarted(2);
    s3.release(2);
    goForeground();
    goBackground(); // cycle 3: background again before the last part
    await s3.waitStarted(3);
    s3.release(3);
    goForeground();
    await done;

    // Three full cycles landed mid-flight and on both boundaries — every part
    // still PUT exactly once, one attempt end-to-end.
    expect(_putCounts(s3), {1: 1, 2: 1, 3: 1});
    expect(s3.uploaded, [1, 2, 3]);
    expect(api.initiated, ['file_0.jpg']);
    expect(api.completedUploadIds, ['u-file_0.jpg']);
    expect(api.aborts, 0);
    expect((await manager.watch().first).status, UploadStatus.completed);
  });

  test(
      'backgrounding near 100%: completes cleanly and the result is '
      'finalize-able (all parts, one complete per file, original uploadId)',
      () async {
    final api = _FakeApi();
    final s3 = _GatedS3();
    final manager = ChunkedUploadManager(
      api: api,
      s3: s3,
      byteSource: _ZeroBytes({'f0': kS3MinPartSize + 50}), // parts 1,2
      maxConcurrentParts: 1,
      chunkSize: kS3MinPartSize,
    );
    addTearDown(manager.dispose);

    final done = manager.start(_session([kS3MinPartSize + 50]));
    await s3.waitStarted(1);
    s3.release(1);
    await s3.waitStarted(2);
    s3.release(2);
    goBackground(); // lands between the last part and complete()
    await done;

    // Client-side finalize precondition: every part confirmed with its ETag in
    // ascending order, exactly one complete() on the ORIGINAL uploadId, zero
    // aborts — the uploaded set finalize would count is intact. (The server
    // side of finalize acceptance is covered by recapture-api's
    // jobs-finalize tests.)
    final parts = api.completed.single;
    expect(parts.map((p) => p.partNumber).toList(), [1, 2]);
    expect(parts.map((p) => p.etag).toList(), ['etag-1', 'etag-2']);
    expect(api.completedUploadIds, ['u-file_0.jpg']);
    expect(api.aborts, 0);
    expect((await manager.watch().first).status, UploadStatus.completed);
  });
}
