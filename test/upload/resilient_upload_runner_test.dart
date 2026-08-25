// test/upload/resilient_upload_runner_test.dart
//
// Retry-loop tests for ResilientUploadRunner with a fake UploadAttempt (no real
// transport): recover-on-retry, exhaustion, non-retryable immediate fail, backoff
// schedule, Retry-After, and cancellation (during attempt + during backoff).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/application/upload/resilient_upload_runner.dart';
import 'package:recapture/domain/upload/session_retry_policy.dart';
import 'package:recapture/domain/upload/upload_failure.dart';
import 'package:recapture/domain/upload/upload_session_spec.dart';
import 'package:recapture/utils/analytics.dart';

/// Fake attempt returning a scripted result per call (last result repeats).
class _ScriptedAttempt implements UploadAttempt {
  _ScriptedAttempt(this.script);
  final List<UploadAttemptResult> script;
  int calls = 0;
  int cancels = 0;

  @override
  Future<UploadAttemptResult> run(UploadSessionSpec session) async {
    final i = calls < script.length ? calls : script.length - 1;
    calls++;
    return script[i];
  }

  @override
  void cancel() => cancels++;
}

/// Attempt that never resolves until [complete] is called — for cancel-mid-attempt.
class _GatedAttempt implements UploadAttempt {
  final Completer<UploadAttemptResult> _gate = Completer();
  int cancels = 0;

  @override
  Future<UploadAttemptResult> run(UploadSessionSpec session) => _gate.future;

  @override
  void cancel() {
    cancels++;
    if (!_gate.isCompleted) _gate.complete(const UploadAttemptCancelled());
  }
}

const _session = UploadSessionSpec(sessionId: 'sess', files: []);

const _policy = SessionRetryPolicy(
  baseDelay: Duration(seconds: 1),
  multiplier: 2.0,
  maxDelay: Duration(seconds: 30),
  jitter: RetryJitter.full,
);

UploadAttemptFailure _net([Duration? retryAfter]) =>
    UploadAttemptFailure(UploadErrorCategory.network, retryAfter: retryAfter);

void main() {
  tearDown(() => Analytics.testSink = null);

  test('success on first attempt → succeeded, attempts_used = 1', () async {
    final events = <String>[];
    Analytics.testSink = (n, _) => events.add(n);
    final runner = ResilientUploadRunner(
      attempt: _ScriptedAttempt([const UploadAttemptSuccess()]),
      policy: _policy,
      sleep: (_) async {},
    );
    final out = await runner.run(_session);
    expect(out.status, ResilientUploadStatus.succeeded);
    expect(out.attemptsUsed, 1);
    expect(events, contains('upload_succeeded'));
  });

  test('transient failures then success → succeeds with attempts_used = 3', () async {
    final attempt = _ScriptedAttempt([
      _net(),
      _net(),
      const UploadAttemptSuccess(),
    ]);
    final runner = ResilientUploadRunner(
      attempt: attempt,
      policy: _policy,
      sleep: (_) async {},
    );
    final out = await runner.run(_session);
    expect(out.status, ResilientUploadStatus.succeeded);
    expect(out.attemptsUsed, 3);
    expect(attempt.calls, 3);
  });

  test('persistent transient → exactly 4 attempts, terminal exhausted network',
      () async {
    final props = <String, Map<String, Object?>>{};
    Analytics.testSink = (n, p) => props[n] = p;
    final attempt = _ScriptedAttempt([_net()]);
    final runner = ResilientUploadRunner(
      attempt: attempt,
      policy: _policy,
      sleep: (_) async {},
    );
    final out = await runner.run(_session);
    expect(attempt.calls, 4); // 1 + 3 retries
    expect(out.status, ResilientUploadStatus.failed);
    expect(out.attemptsUsed, 4);
    expect(out.category, UploadErrorCategory.network);
    expect(out.autoRetriesExhausted, isTrue);
    expect(props['upload_retries_exhausted']!['total_attempts'], 4);
    expect(props['upload_retries_exhausted']!['error_category'], 'network');
  });

  test('non-retryable failure → zero retries, immediate terminal fail', () async {
    final events = <String>[];
    Analytics.testSink = (n, _) => events.add(n);
    final attempt = _ScriptedAttempt(
      [const UploadAttemptFailure(UploadErrorCategory.auth)],
    );
    final runner = ResilientUploadRunner(
      attempt: attempt,
      policy: _policy,
      sleep: (_) async {},
    );
    final out = await runner.run(_session);
    expect(attempt.calls, 1);
    expect(out.status, ResilientUploadStatus.failed);
    expect(out.category, UploadErrorCategory.auth);
    expect(out.autoRetriesExhausted, isFalse);
    expect(events, isNot(contains('upload_retries_exhausted')));
  });

  test('backoff follows the exponential schedule (random=1.0), capped', () async {
    final delays = <int>[];
    final attempt = _ScriptedAttempt([_net()]); // always fails → exhausts
    final runner = ResilientUploadRunner(
      attempt: attempt,
      policy: _policy,
      sleep: (d) async => delays.add(d.inMilliseconds),
      random: () => 1.0,
    );
    await runner.run(_session);
    expect(delays, [1000, 2000, 4000]); // 3 waits before the 4th (final) attempt
  });

  test('Retry-After is honored over the computed backoff', () async {
    final delays = <int>[];
    final attempt = _ScriptedAttempt([_net(const Duration(seconds: 9))]);
    final runner = ResilientUploadRunner(
      attempt: attempt,
      policy: _policy,
      sleep: (d) async => delays.add(d.inMilliseconds),
      random: () => 1.0,
    );
    await runner.run(_session);
    expect(delays, [9000, 9000, 9000]);
  });

  test('cancel during a backoff wait → cancelled, not a network failure', () async {
    // sleep never completes on its own, so the runner parks in the wait.
    final runner = ResilientUploadRunner(
      attempt: _ScriptedAttempt([_net()]),
      policy: _policy,
      sleep: (_) => Completer<void>().future,
    );
    final future = runner.run(_session);
    await Future<void>.delayed(Duration.zero); // let it reach the wait
    runner.cancel();
    final out = await future;
    expect(out.status, ResilientUploadStatus.cancelled);
  });

  test('cancel during an in-flight attempt → cancelled, attempt.cancel called',
      () async {
    final attempt = _GatedAttempt();
    final runner = ResilientUploadRunner(attempt: attempt, policy: _policy);
    final future = runner.run(_session);
    await Future<void>.delayed(Duration.zero);
    runner.cancel();
    final out = await future;
    expect(out.status, ResilientUploadStatus.cancelled);
    expect(attempt.cancels, 1);
  });
}
