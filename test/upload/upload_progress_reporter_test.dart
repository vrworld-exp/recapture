// test/upload/upload_progress_reporter_test.dart
//
// Reporting layer: throttle/coalesce, phase (retrying/finalizing), full-restart
// reset, late-subscriber snapshot, terminal close, zero totals. Emits NO
// analytics — the milestone event (upload_progress) moved to the engine.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/upload/upload_progress_reporter.dart';
import 'package:recapture/domain/entities/upload_progress.dart';
import 'package:recapture/domain/upload/upload_progress_view.dart';
import 'package:recapture/utils/analytics.dart';

UploadProgress _p(
  UploadStatus status,
  int bytes,
  int totalBytes,
  int files,
  int totalFiles,
) =>
    UploadProgress(
      status: status,
      bytesUploaded: bytes,
      totalBytes: totalBytes,
      filesUploaded: files,
      totalFiles: totalFiles,
    );

Future<void> _pump([int n = 4]) async {
  for (var i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late StreamController<UploadProgress> src;
  late UploadProgressReporter reporter;
  late List<UploadProgressView> seen;
  late StreamSubscription<UploadProgressView> sub;

  void listen() {
    seen = [];
    sub = reporter.watch().listen(seen.add);
  }

  tearDown(() async {
    await sub.cancel();
    await reporter.dispose();
    await src.close();
    Analytics.testSink = null;
  });

  test('coalesces many tiny byte updates to a bounded number of emits', () async {
    src = StreamController<UploadProgress>();
    reporter = UploadProgressReporter(src.stream, minFractionDelta: 0.01);
    listen();

    // 1000 tiny increments over 100000 bytes → ~1% steps should bound emits.
    for (var b = 0; b <= 1000; b++) {
      src.add(_p(UploadStatus.inProgress, b * 100, 100000, 0, 4));
    }
    await _pump();

    // Far fewer than 1001 emits (coalesced to ~100 at 1% granularity + a bit).
    expect(seen.length, lessThan(150));
    expect(seen.length, greaterThan(50));
    // Latest reflects the final byte value pushed.
    expect(reporter.latest.bytesUploaded, 100000);
  });

  test('a file completion always emits even within the byte threshold', () async {
    src = StreamController<UploadProgress>();
    reporter = UploadProgressReporter(src.stream, minFractionDelta: 0.5);
    listen();
    src.add(_p(UploadStatus.inProgress, 10, 1000, 0, 4)); // first → emit
    src.add(_p(UploadStatus.inProgress, 11, 1000, 1, 4)); // <0.5% byte, but file++
    await _pump();
    expect(seen.map((v) => v.filesUploaded), containsAllInOrder([0, 1]));
  });

  test('markRetrying flips phase (counts hold); markUploading resumes', () async {
    src = StreamController<UploadProgress>();
    reporter = UploadProgressReporter(src.stream);
    listen();
    src.add(_p(UploadStatus.inProgress, 500, 1000, 1, 4));
    await _pump();

    reporter.markRetrying(2);
    await _pump();
    final retrying = seen.last;
    expect(retrying.phase, UploadPhase.retrying);
    expect(retrying.retryAttempt, 2);
    expect(retrying.bytesUploaded, 500); // counts steady during backoff

    reporter.markUploading();
    await _pump();
    expect(seen.last.phase, UploadPhase.uploading);
    expect(seen.last.retryAttempt, 0);
  });

  test('bytes are monotonic; a stray backward snapshot is clamped', () async {
    src = StreamController<UploadProgress>();
    reporter = UploadProgressReporter(src.stream, minFractionDelta: 0.0);
    listen();
    src.add(_p(UploadStatus.inProgress, 800, 1000, 2, 4));
    src.add(_p(UploadStatus.inProgress, 300, 1000, 2, 4)); // backward → clamped
    await _pump();
    expect(reporter.latest.bytesUploaded, 800);
    expect(seen.every((v) => v.bytesUploaded >= 0), isTrue);
    expect(seen.map((v) => v.bytesUploaded).reduce((a, b) => a > b ? a : b), 800);
  });

  test('reset emits an explicit 0/total (the only backward move)', () async {
    src = StreamController<UploadProgress>();
    reporter = UploadProgressReporter(src.stream);
    listen();
    src.add(_p(UploadStatus.inProgress, 900, 1000, 3, 4));
    await _pump();
    reporter.reset();
    await _pump();
    final r = seen.last;
    expect(r.bytesUploaded, 0);
    expect(r.filesUploaded, 0);
    expect(r.totalBytes, 1000); // totals preserved
    expect(r.phase, UploadPhase.uploading);
  });

  test('late subscriber immediately receives the current snapshot', () async {
    src = StreamController<UploadProgress>();
    reporter = UploadProgressReporter(src.stream);
    src.add(_p(UploadStatus.inProgress, 400, 1000, 2, 4));
    await _pump();
    // Attach AFTER progress already advanced.
    final late = <UploadProgressView>[];
    final lateSub = reporter.watch().listen(late.add);
    await _pump();
    expect(late.first.bytesUploaded, 400);
    await lateSub.cancel();
    // Needed for tearDown symmetry.
    seen = [];
    sub = reporter.watch().listen(seen.add);
  });

  test('multiple subscribers both receive updates', () async {
    src = StreamController<UploadProgress>();
    reporter = UploadProgressReporter(src.stream, minFractionDelta: 0.0);
    final a = <UploadProgressView>[];
    final b = <UploadProgressView>[];
    final sa = reporter.watch().listen(a.add);
    final sb = reporter.watch().listen(b.add);
    src.add(_p(UploadStatus.inProgress, 250, 1000, 1, 4));
    await _pump();
    expect(a.any((v) => v.bytesUploaded == 250), isTrue);
    expect(b.any((v) => v.bytesUploaded == 250), isTrue);
    await sa.cancel();
    await sb.cancel();
    seen = [];
    sub = reporter.watch().listen(seen.add);
  });

  test('terminal status → final 100% emit then close; no events after', () async {
    src = StreamController<UploadProgress>();
    reporter = UploadProgressReporter(src.stream);
    listen();
    src.add(_p(UploadStatus.inProgress, 500, 1000, 2, 4));
    src.add(_p(UploadStatus.completed, 1000, 1000, 4, 4));
    await _pump();
    expect(seen.last.fraction, 1.0);
    expect(seen.last.filesUploaded, 4);
    final countAfterTerminal = seen.length;
    // A post-terminal source event is ignored (stream already closed).
    src.add(_p(UploadStatus.completed, 1000, 1000, 4, 4));
    await _pump();
    expect(seen.length, countAfterTerminal);
  });

  test('zero totals: no crash, fraction 0, terminal still closes', () async {
    src = StreamController<UploadProgress>();
    reporter = UploadProgressReporter(src.stream);
    listen();
    src.add(_p(UploadStatus.idle, 0, 0, 0, 0));
    src.add(_p(UploadStatus.completed, 0, 0, 0, 0));
    await _pump();
    expect(seen.last.fraction, 0.0);
    expect(reporter.latest.status, UploadStatus.completed);
  });

  test('emits NO analytics — milestones belong to the engine (upload_progress)',
      () async {
    final events = <String>[];
    Analytics.testSink = (n, _) => events.add(n);
    src = StreamController<UploadProgress>();
    reporter = UploadProgressReporter(src.stream, minFractionDelta: 0.0);
    listen();
    for (var pct = 0; pct <= 100; pct += 5) {
      src.add(_p(UploadStatus.inProgress, pct * 10, 1000, 0, 1));
    }
    src.add(_p(UploadStatus.completed, 1000, 1000, 1, 1));
    await _pump();
    expect(events, isEmpty);
  });
}
