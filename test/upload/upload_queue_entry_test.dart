// test/upload/upload_queue_entry_test.dart
//
// Pure domain model of the offline upload queue: the JSON codec (restart
// durability), the userPaused vs offlineQueued distinction, the FIFO
// auto-resume selection, and the restart reconciliation rules.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/upload/upload_failure.dart';
import 'package:recapture/domain/upload/upload_queue_entry.dart';
import 'package:recapture/domain/upload/upload_session_spec.dart';

UploadQueueEntry entry(
  String id, {
  UploadJobState state = UploadJobState.offlineQueued,
  int seq = 0,
  int attempts = 0,
}) =>
    UploadQueueEntry(
      jobId: id,
      spec: UploadSessionSpec(sessionId: id, files: [
        UploadFileSpec(path: '/captures/$id/eye_0001.jpg', key: 'k/$id', size: 123),
      ]),
      state: state,
      seq: seq,
      attempts: attempts,
    );

void main() {
  group('codec', () {
    test('round-trips every field losslessly', () {
      final original = entry('job-1', seq: 7, attempts: 2)
          .copyWith(lastErrorCategory: UploadErrorCategory.network);

      final decoded = UploadQueueEntry.fromJson(original.toJson());

      expect(decoded.jobId, 'job-1');
      expect(decoded.state, UploadJobState.offlineQueued);
      expect(decoded.seq, 7);
      expect(decoded.attempts, 2);
      expect(decoded.lastErrorCategory, UploadErrorCategory.network);
      expect(decoded.spec.sessionId, 'job-1');
      expect(decoded.spec.files.single.path, '/captures/job-1/eye_0001.jpg');
      expect(decoded.spec.files.single.key, 'k/job-1');
      expect(decoded.spec.files.single.size, 123);
    });

    test('round-trips the userPaused state (intent survives restart)', () {
      final decoded = UploadQueueEntry.fromJson(
        entry('j', state: UploadJobState.userPaused).toJson(),
      );
      expect(decoded.state, UploadJobState.userPaused);
    });

    test('unknown state on the wire falls back to offlineQueued (safe lane)', () {
      final json = entry('j').toJson()..['state'] = 'hyperdrive';
      expect(UploadQueueEntry.fromJson(json).state, UploadJobState.offlineQueued);
    });

    test('missing jobId or spec throws FormatException (unreplayable)', () {
      expect(() => UploadQueueEntry.fromJson(const {'state': 'uploading'}),
          throwsFormatException);
      expect(
        () => UploadQueueEntry.fromJson(const {'jobId': 'j', 'spec': 'nope'}),
        throwsFormatException,
      );
    });
  });

  group('state semantics', () {
    test('only offlineQueued is auto-resumable — userPaused never is', () {
      expect(entry('a').isAutoResumable, isTrue);
      expect(entry('a', state: UploadJobState.userPaused).isAutoResumable, isFalse);
      expect(entry('a', state: UploadJobState.uploading).isAutoResumable, isFalse);
      expect(entry('a', state: UploadJobState.failed).isAutoResumable, isFalse);
    });

    test('isWaitingForConnection mirrors offlineQueued', () {
      expect(entry('a').isWaitingForConnection, isTrue);
      expect(
        entry('a', state: UploadJobState.retrying).isWaitingForConnection,
        isFalse,
      );
    });

    test('terminal = completed/failed/cancelled', () {
      expect(entry('a', state: UploadJobState.completed).isTerminal, isTrue);
      expect(entry('a', state: UploadJobState.failed).isTerminal, isTrue);
      expect(entry('a', state: UploadJobState.cancelled).isTerminal, isTrue);
      expect(entry('a', state: UploadJobState.userPaused).isTerminal, isFalse);
      expect(entry('a').isTerminal, isFalse);
    });
  });

  group('autoResumableJobs', () {
    test('selects only offlineQueued, in seq (FIFO) order', () {
      final jobs = autoResumableJobs([
        entry('c', seq: 3),
        entry('paused', state: UploadJobState.userPaused, seq: 0),
        entry('a', seq: 1),
        entry('failed', state: UploadJobState.failed, seq: 2),
        entry('b', seq: 2),
      ]);
      expect(jobs.map((e) => e.jobId), ['a', 'b', 'c']);
    });
  });

  group('reconcileOnRestore', () {
    test('interrupted running states re-queue as offlineQueued', () {
      expect(
        reconcileOnRestore(entry('a', state: UploadJobState.uploading))!.state,
        UploadJobState.offlineQueued,
      );
      expect(
        reconcileOnRestore(entry('a', state: UploadJobState.retrying))!.state,
        UploadJobState.offlineQueued,
      );
    });

    test('userPaused survives untouched (user intent outlives the process)', () {
      final restored =
          reconcileOnRestore(entry('a', state: UploadJobState.userPaused));
      expect(restored!.state, UploadJobState.userPaused);
    });

    test('offlineQueued restores as-is; terminal rows drop (null)', () {
      expect(reconcileOnRestore(entry('a'))!.state, UploadJobState.offlineQueued);
      expect(reconcileOnRestore(entry('a', state: UploadJobState.completed)), isNull);
      expect(reconcileOnRestore(entry('a', state: UploadJobState.cancelled)), isNull);
      expect(reconcileOnRestore(entry('a', state: UploadJobState.failed)), isNull);
    });
  });
}
