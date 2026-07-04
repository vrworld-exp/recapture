// lib/application/upload/resilient_upload_runner.dart
//
// The SESSION-level automatic retry layer: wraps a single upload ATTEMPT in a
// retry loop that retries TRANSIENT failures with exponential backoff + jitter
// (honoring `Retry-After`), capped at [SessionRetryPolicy.maxRetries] (default 3 →
// 4 total attempts). Only after auto-retries are exhausted (or on a non-retryable
// failure) does it surface a TERMINAL failure — which Screen 9F then offers the
// USER to retry (a fresh sequence). The two layers are distinct: this is silent
// engine recovery; 9F is user-initiated.
//
// Retryability reuses the SAME classifier as 9F ([UploadErrorCategory] /
// [UploadErrorCategoryX.retryable] from upload_failure.dart) so auto-retry and the
// failure screen never disagree on what is transient. (Reconciliation: 429→quota
// is non-retryable per that shared classifier — retrying a quota error won't help;
// `Retry-After` is honored for the retryable categories that supply it, e.g. 503.)
//
// IDEMPOTENCY: a retried attempt is safe because the wrapped attempt resumes from
// the durable [UploadProgressStore] (confirmed parts are skipped, the server dedupes
// re-sent parts by number) — so auto-retry never produces a duplicate/corrupt
// server object. See project-resumable-upload-persistence.
//
// Backoff waits are async + cancellable (race the delay against a cancel signal),
// never a blocking sleep on the UI isolate. Cancellation is reported as CANCELLED,
// never as a network failure.
import 'dart:async';

import 'package:dio/dio.dart';

import '../../domain/entities/upload_progress.dart' show UploadStatus;
import '../../domain/upload/session_retry_policy.dart';
import '../../domain/upload/upload_failure.dart';
import '../../domain/upload/upload_session_spec.dart';
import '../../utils/analytics.dart';
import 'chunked_upload_manager.dart';

/// The outcome of ONE upload attempt, as seen by the retry loop.
sealed class UploadAttemptResult {
  const UploadAttemptResult();
}

/// The attempt succeeded.
class UploadAttemptSuccess extends UploadAttemptResult {
  const UploadAttemptSuccess();
}

/// The attempt failed. [category] is the shared 9F classification; [retryAfter]
/// carries a server-provided delay (429/503) when present.
class UploadAttemptFailure extends UploadAttemptResult {
  const UploadAttemptFailure(this.category, {this.retryAfter});

  final UploadErrorCategory category;
  final Duration? retryAfter;
}

/// The attempt was cancelled by the user.
class UploadAttemptCancelled extends UploadAttemptResult {
  const UploadAttemptCancelled();
}

/// A single upload attempt — the unit the retry loop wraps. Injectable so the
/// runner is testable without the real transport. Implementations MUST be
/// idempotent across attempts (resume/dedupe) so a retry never duplicates data.
abstract interface class UploadAttempt {
  Future<UploadAttemptResult> run(UploadSessionSpec session);

  /// Abort an in-flight attempt (called on runner cancel).
  void cancel();
}

/// How a whole (retried) upload finished.
enum ResilientUploadStatus { succeeded, failed, cancelled }

/// The terminal outcome the upload controller / Screen 9F consumes.
class ResilientUploadOutcome {
  const ResilientUploadOutcome({
    required this.status,
    required this.attemptsUsed,
    this.category,
    this.autoRetriesExhausted = false,
  });

  final ResilientUploadStatus status;

  /// Attempts actually made (1 = succeeded/failed first try; up to maxAttempts).
  final int attemptsUsed;

  /// The mapped failure category (null unless [status] is failed).
  final UploadErrorCategory? category;

  /// True when a TRANSIENT failure persisted through all allowed auto-retries — so
  /// 9F can say "we tried automatically" and still offer a manual retry.
  final bool autoRetriesExhausted;

  bool get isSuccess => status == ResilientUploadStatus.succeeded;
}

/// Wraps a [UploadAttempt] with the session-level retry policy.
class ResilientUploadRunner {
  ResilientUploadRunner({
    required UploadAttempt attempt,
    SessionRetryPolicy policy = SessionRetryPolicy.bundledDefault,
    Future<void> Function(Duration)? sleep,
    double Function()? random,
    void Function(String name, Map<String, Object?> props)? analytics,
    String deviceType = 'mobile',
  })  : _attempt = attempt,
        _policy = policy,
        _sleep = sleep ?? Future.delayed,
        _random = random,
        _analytics = analytics ?? Analytics.logEvent,
        _deviceType = deviceType;

  final UploadAttempt _attempt;
  final SessionRetryPolicy _policy;
  final Future<void> Function(Duration) _sleep;
  final double Function()? _random;
  final void Function(String, Map<String, Object?>) _analytics;
  final String _deviceType;

  bool _cancelled = false;
  Completer<void>? _cancelWait;

  /// Cancels the run: aborts the in-flight attempt and wakes any backoff wait.
  void cancel() {
    _cancelled = true;
    _attempt.cancel();
    _cancelWait?.complete();
  }

  /// Runs [session] with automatic retry. Resolves with the terminal outcome.
  Future<ResilientUploadOutcome> run(UploadSessionSpec session) async {
    var attemptNo = 0;
    while (true) {
      if (_cancelled) {
        return ResilientUploadOutcome(
          status: ResilientUploadStatus.cancelled,
          attemptsUsed: attemptNo,
        );
      }
      attemptNo++;
      _emit(AnalyticsEvents.uploadAttemptStarted, session, {
        'attempt': attemptNo,
        'is_retry': attemptNo > 1,
      });

      final result = await _attempt.run(session);

      if (result is UploadAttemptSuccess) {
        _emit(AnalyticsEvents.uploadSucceeded, session, {
          'attempts_used': attemptNo,
        });
        return ResilientUploadOutcome(
          status: ResilientUploadStatus.succeeded,
          attemptsUsed: attemptNo,
        );
      }
      if (result is UploadAttemptCancelled || _cancelled) {
        return ResilientUploadOutcome(
          status: ResilientUploadStatus.cancelled,
          attemptsUsed: attemptNo,
        );
      }

      final failure = result as UploadAttemptFailure;
      final retryable = failure.category.retryable;
      final retriesUsed = attemptNo - 1;
      final willRetry =
          retryable && retriesUsed < _policy.maxRetries && !_cancelled;

      final delay = willRetry
          ? _policy.delayForRetry(
              retriesUsed,
              retryAfter: failure.retryAfter,
              random: _random,
            )
          : null;

      _emit(AnalyticsEvents.uploadAttemptFailed, session, {
        'attempt': attemptNo,
        'error_category': failure.category.wireName,
        'retryable': retryable,
        if (delay != null) 'next_delay_ms': delay.inMilliseconds,
      });

      if (!retryable) {
        // Non-retryable → immediate terminal failure (no retry).
        return ResilientUploadOutcome(
          status: ResilientUploadStatus.failed,
          attemptsUsed: attemptNo,
          category: failure.category,
        );
      }
      if (!willRetry) {
        // Retryable but out of retries → terminal, flagged for 9F.
        _emit(AnalyticsEvents.uploadRetriesExhausted, session, {
          'total_attempts': attemptNo,
          'error_category': failure.category.wireName,
        });
        return ResilientUploadOutcome(
          status: ResilientUploadStatus.failed,
          attemptsUsed: attemptNo,
          category: failure.category,
          autoRetriesExhausted: true,
        );
      }

      await _cancellableWait(delay!);
      if (_cancelled) {
        return ResilientUploadOutcome(
          status: ResilientUploadStatus.cancelled,
          attemptsUsed: attemptNo,
        );
      }
    }
  }

  /// Awaits [delay], but returns early if [cancel] fires during the wait.
  Future<void> _cancellableWait(Duration delay) async {
    if (_cancelled) return;
    final wait = _cancelWait = Completer<void>();
    try {
      await Future.any<void>([_sleep(delay), wait.future]);
    } finally {
      _cancelWait = null;
    }
  }

  void _emit(String name, UploadSessionSpec session, Map<String, Object?> props) {
    _analytics(name, {
      'session_id': session.sessionId,
      ...props,
      'device_type': _deviceType,
    });
  }
}

/// Production [UploadAttempt] over a [ChunkedUploadManager]: one `run` = one full
/// `manager.start(session)` (which itself resumes from the durable store, making
/// the attempt idempotent). Maps the manager's terminal status to a result, using
/// the shared [classifyUploadFailure] + a `Retry-After` extracted from the raw
/// error.
class ManagerUploadAttempt implements UploadAttempt {
  ManagerUploadAttempt(this._manager);

  final ChunkedUploadManager _manager;

  @override
  Future<UploadAttemptResult> run(UploadSessionSpec session) async {
    await _manager.start(session);
    switch (_manager.currentStatus) {
      case UploadStatus.completed:
        return const UploadAttemptSuccess();
      case UploadStatus.cancelled:
        return const UploadAttemptCancelled();
      default:
        return UploadAttemptFailure(
          classifyUploadFailure(_manager.lastFailureError),
          retryAfter: parseRetryAfter(_manager.lastFailureError),
        );
    }
  }

  @override
  void cancel() => _manager.cancel();
}

/// Extracts a `Retry-After` duration from a Dio error's response headers, if any.
/// Supports the numeric-seconds form (the HTTP-date form is treated as absent —
/// the computed backoff applies). Returns null when there is nothing to honor.
Duration? parseRetryAfter(Object? error) {
  if (error is! DioException) return null;
  final raw = error.response?.headers.value('retry-after');
  if (raw == null) return null;
  final seconds = int.tryParse(raw.trim());
  if (seconds == null || seconds < 0) return null;
  return Duration(seconds: seconds);
}
