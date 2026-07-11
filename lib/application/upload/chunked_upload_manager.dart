// lib/application/upload/chunked_upload_manager.dart
//
// The upload ENGINE: transfers a completed capture session's files to S3 via
// presigned MULTIPART uploads over Dio. Per file it: initiates a multipart upload,
// chunks the file into S3-valid parts ([planFileParts]), PUTs parts to their
// presigned URLs with BOUNDED concurrency, RETRIES transient part failures with
// bounded exponential backoff, collects ETags, and COMPLETES the upload with the
// ETags in ascending part-number order — or ABORTS (terminal failure / cancel) so
// S3 keeps no incomplete (billed) upload.
//
// It is UI-free: it implements the existing [UploadProgressSource] (Screen 9 binds
// to this via a [uploadProgressSourceProvider] override) and [UploadController]
// (the Pause/Resume/Cancel buttons signal through it). All progress flows through
// one place ([_emit]); the UI never computes progress. `bytesUploaded` is REAL
// acknowledged bytes and MONOTONIC — a retried part is never double-counted.
//
// Everything crossing a boundary is injected ([MultipartUploadApi], [S3PartClient],
// [PartByteSource], the sleep + connectivity hooks), so the whole engine is
// unit-testable with fakes — no real network or filesystem.
import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';

import '../../data/local/upload_progress_box.dart';
import '../../domain/upload/file_upload_progress.dart';
import '../../domain/upload/upload_part_plan.dart';
import '../../domain/upload/upload_session_spec.dart';
import '../../domain/entities/upload_progress.dart';
import '../../utils/analytics.dart';
import '../../utils/byte_format.dart';
import 'multipart_upload_api.dart';
import 'upload_controller.dart';
import 'upload_progress_provider.dart';

/// Internal signal distinguishing a user cancel from a transfer failure.
class _CancelledSignal implements Exception {
  const _CancelledSignal();
}

/// Internal signal: a file failed terminally (status already set failed) — stops
/// the session loop without a second failure emission.
class _FileFailedSignal implements Exception {
  const _FileFailedSignal();
}

/// Chunked, presigned-multipart S3 upload engine.
class ChunkedUploadManager implements UploadProgressSource, UploadController {
  ChunkedUploadManager({
    required MultipartUploadApi api,
    required S3PartClient s3,
    PartByteSource byteSource = const FilePartByteSource(),
    UploadRetryPolicy retry = const UploadRetryPolicy(),
    int maxConcurrentParts = 3,
    int chunkSize = kDefaultChunkSize,
    bool Function()? isOnline,
    Future<void> Function(Duration)? sleep,
    String deviceType = 'mobile',
    UploadProgressStore? store,
  })  : _api = api,
        _s3 = s3,
        _byteSource = byteSource,
        _retry = retry,
        _maxConcurrent = maxConcurrentParts < 1 ? 1 : maxConcurrentParts,
        _chunkSize = chunkSize,
        _isOnline = isOnline,
        _sleep = sleep ?? Future.delayed,
        _deviceType = deviceType,
        _store = store;

  final MultipartUploadApi _api;
  final S3PartClient _s3;
  final PartByteSource _byteSource;

  /// Optional durability layer. When null, the engine is stateless (no persist /
  /// resume) — existing behaviour. When provided, offsets + ETags + uploadId are
  /// persisted so a paused/killed upload resumes without re-uploading confirmed
  /// parts. See [UploadProgressStore].
  final UploadProgressStore? _store;
  final UploadRetryPolicy _retry;
  final int _maxConcurrent;
  final int _chunkSize;
  final bool Function()? _isOnline;
  final Future<void> Function(Duration) _sleep;
  final String _deviceType;

  final StreamController<UploadProgress> _controller =
      StreamController<UploadProgress>.broadcast();

  UploadProgress _progress = UploadProgress.initial;
  String? _sessionId;

  // Progress accounting.
  int _totalBytes = 0;
  int _totalFiles = 0;
  int _filesUploaded = 0;
  int _confirmedBytes = 0; // sum of fully-acked parts (authoritative)
  int _reportedBytes = 0; // emitted value, clamped monotonic
  final Map<int, int> _inFlight = {}; // partNumber → bytes sent this attempt

  // Control.
  bool _cancelled = false;
  bool _paused = false;
  Completer<void>? _pauseGate;
  final Set<CancelToken> _activeTokens = {};

  // Lifecycle analytics context (see _logLifecycle).
  DateTime? _startedAt;
  String? _pendingPauseReason;

  /// Milestones (25/50/75/100) already fired this run (see _fireProgressMilestones).
  final Set<int> _milestonesFired = {};

  String? _lastFailureReason;
  Object? _lastFailureError;

  /// The last failure's (non-PII) reason, for diagnostics — the progress contract
  /// itself carries only the status enum (Screen 9's shape).
  String? get lastFailureReason => _lastFailureReason;

  /// The raw error object behind the last failure (for the retry layer to classify
  /// via the shared [classifyUploadFailure] + extract a `Retry-After`). Never shown
  /// to the UI — the mapped category is.
  Object? get lastFailureError => _lastFailureError;

  /// The current terminal/liveness status (the retry layer reads this after a
  /// [start] attempt resolves to decide success/failure/cancelled).
  UploadStatus get currentStatus => _progress.status;

  // ── UploadProgressSource ─────────────────────────────────────────────────────

  @override
  Stream<UploadProgress> watch() async* {
    yield _progress; // replay the current snapshot to a new subscriber
    yield* _controller.stream;
  }

  // ── UploadController ─────────────────────────────────────────────────────────

  @override
  void pause() {
    if (_progress.status != UploadStatus.inProgress) return;
    _paused = true;
    _pendingPauseReason = 'user';
    _setStatus(UploadStatus.paused);
  }

  @override
  void resume() {
    if (!_paused) return;
    _paused = false;
    _pauseGate?.complete();
    _pauseGate = null;
    if (!_cancelled && _progress.status == UploadStatus.paused) {
      _setStatus(UploadStatus.inProgress);
    }
  }

  @override
  void cancel() {
    if (_progress.status == UploadStatus.completed ||
        _progress.status == UploadStatus.cancelled) {
      return;
    }
    _cancelled = true;
    // Release any parked workers, then cancel in-flight transfers.
    _paused = false;
    _pauseGate?.complete();
    _pauseGate = null;
    for (final t in _activeTokens.toList()) {
      if (!t.isCancelled) t.cancel('upload cancelled');
    }
    // start()'s control flow performs the multipart abort + final status.
  }

  // ── engine ───────────────────────────────────────────────────────────────────

  /// Uploads [session] end-to-end. Idempotent-ish: a no-op if already running.
  /// Resolves when the session reaches a terminal status (completed/failed/
  /// cancelled) — inspect the progress stream / [lastFailureReason] for the outcome.
  Future<void> start(UploadSessionSpec session) async {
    if (_progress.status == UploadStatus.inProgress ||
        _progress.status == UploadStatus.paused) {
      return;
    }
    _reset(session);
    _setStatus(UploadStatus.inProgress);

    for (var fileIndex = 0; fileIndex < session.files.length; fileIndex++) {
      if (_cancelled) break;
      final file = session.files[fileIndex];
      final parts = planFileParts(file.size, chunkSize: _chunkSize);
      if (parts.isEmpty) {
        // Zero-byte / sizeless file: nothing to multipart. Skip + advance so the
        // session can still complete (do not crash, do not fabricate an upload).
        _filesUploaded++;
        _emit();
        continue;
      }
      final fileBytes = parts.fold(0, (s, p) => s + p.length);

      // A file already finalized in a prior run (persisted) is skipped entirely —
      // its bytes still count toward progress so the bar reflects resumed work.
      final persisted = await _store?.get(session.sessionId, file.key);
      if (persisted != null && persisted.status == UploadStatus.completed) {
        _confirmedBytes += fileBytes;
        _filesUploaded++;
        _emit();
        continue;
      }

      try {
        await _uploadOneFile(session, fileIndex, file, parts, persisted);
      } on _CancelledSignal {
        await _store?.clearSession(session.sessionId);
        _setStatus(UploadStatus.cancelled);
        return;
      } on _FileFailedSignal {
        // Terminal: status already set failed; persisted state is RETAINED so the
        // session can resume later (do NOT clear).
        return;
      }
    }

    if (_cancelled) {
      await _store?.clearSession(session.sessionId);
      _setStatus(UploadStatus.cancelled);
      return;
    }
    // Whole session done — the upload bookkeeping is no longer needed.
    await _store?.clearSession(session.sessionId);
    _setStatus(UploadStatus.completed);
  }

  /// Uploads (or resumes) ONE file: reuses a persisted server uploadId + confirmed
  /// parts when present, uploads the remaining parts, and finalizes with the FULL
  /// ETag list in ascending order. Retries ONCE (fresh initiate) if the server
  /// uploadId is invalid/expired. On confirm of a part, the offset+ETag are
  /// persisted atomically. Throws [_CancelledSignal] / [_FileFailedSignal].
  Future<void> _uploadOneFile(
    UploadSessionSpec session,
    int fileIndex,
    UploadFileSpec file,
    List<UploadPartPlan> parts,
    FileUploadProgress? persistedIn,
  ) async {
    final baseBytes = _confirmedBytes; // this file's contribution starts here
    var reInitiated = false;
    var persisted = persistedIn;

    while (true) {
      InitiatedUpload? init;
      try {
        // Resolve the upload: reuse a persisted uploadId, or initiate fresh.
        final Set<int> skip;
        final Map<int, String> etags;
        if (_store != null &&
            persisted != null &&
            persisted.uploadId != null &&
            persisted.status != UploadStatus.completed) {
          // RESUME: reuse the server uploadId; presigned part URLs are re-fetched
          // per remaining part (they aren't persisted). Skip confirmed parts.
          init = InitiatedUpload(
            uploadId: persisted.uploadId!,
            key: persisted.objectKey,
            parts: const [],
          );
          skip = {
            for (final n in persisted.completedPartNumbers)
              if (n >= 1 && n <= parts.length) n,
          };
          etags = {
            for (final p in persisted.completedParts)
              if (p.partNumber >= 1 && p.partNumber <= parts.length)
                p.partNumber: p.etag,
          };
          // Count already-confirmed bytes so progress reflects resumed work.
          final seeded = parts
              .where((p) => skip.contains(p.partNumber))
              .fold(0, (s, p) => s + p.length);
          if (seeded > 0) {
            _confirmedBytes = baseBytes + seeded;
            _emit();
          }
        } else {
          init = await _api.initiate(
            sessionId: session.sessionId,
            fileKey: file.key,
            fileSize: file.size,
            partCount: parts.length,
          );
          await _store?.begin(
            session.sessionId,
            file.key,
            uploadId: init.uploadId,
            objectKey: init.key,
            totalParts: parts.length,
            totalBytes: file.size,
          );
          skip = const {};
          etags = {};
        }

        final uploaded =
            await _uploadFileParts(session, fileIndex, file, init, parts, skip);
        etags.addAll(uploaded);

        // Finalize with ETags in ASCENDING part-number order (S3 requirement).
        final ordered = etags.keys.toList()..sort();
        await _api.complete(
          uploadId: init.uploadId,
          key: init.key,
          parts: [
            for (final n in ordered)
              CompletedPart(partNumber: n, etag: etags[n]!),
          ],
        );
        await _store?.markFileComplete(session.sessionId, file.key);
        _filesUploaded++;
        _emit();
        return;
      } on _CancelledSignal {
        await _abort(init, 'cancelled');
        rethrow;
      } catch (e) {
        // uploadId expired / server-offset mismatch → re-initiate ONCE, dropping
        // the stale persisted parts, and restart this file from scratch (parts are
        // idempotent). Guarded so a dead uploadId can't loop.
        if (_isUploadInvalid(e) && !reInitiated && !_cancelled) {
          reInitiated = true;
          _confirmedBytes =
              baseBytes; // undo this file's seeded/confirmed bytes
          _inFlight.clear();
          _emit();
          await _store?.clearFile(session.sessionId, file.key);
          persisted = null;
          continue;
        }
        await _abort(init, 'part_failed');
        _lastFailureReason = e.toString();
        _lastFailureError = e;
        _setStatus(UploadStatus.failed);
        throw const _FileFailedSignal();
      }
    }
  }

  /// Uploads a file's remaining parts (those not in [skip]) with bounded
  /// concurrency + retry. Persists each part's ETag+offset atomically on confirm.
  /// Returns partNumber→ETag for the newly-uploaded parts. Throws [_CancelledSignal]
  /// on cancel, or the first part's terminal error.
  Future<Map<int, String>> _uploadFileParts(
    UploadSessionSpec session,
    int fileIndex,
    UploadFileSpec file,
    InitiatedUpload init,
    List<UploadPartPlan> parts,
    Set<int> skip,
  ) async {
    final etags = <int, String>{};
    final queue = Queue<UploadPartPlan>.of(
      [
        for (final p in parts)
          if (!skip.contains(p.partNumber)) p
      ],
    );
    Object? firstError;

    Future<void> worker() async {
      while (true) {
        if (_cancelled || firstError != null) return;
        await _awaitIfPaused();
        if (_cancelled || firstError != null) return;
        // Connectivity gate: don't launch a part into a dead network — park until
        // resumed (auto-pause) instead of retrying blindly.
        if (_isOnline != null && !_isOnline()) {
          _autoPause();
          await _awaitIfPaused();
          continue; // re-check cancel/pause/connectivity from the top after resume
        }
        if (queue.isEmpty) return;
        final part = queue.removeFirst();
        try {
          final etag = await _uploadPartWithRetry(fileIndex, file, init, part);
          etags[part.partNumber] = etag;
          // Advance confirmed bytes FIRST, then persist offset+ETag together — only
          // AFTER the server confirmed the part (never before).
          _confirmBytes(part);
          await _store?.recordPartComplete(
            session.sessionId,
            file.key,
            partNumber: part.partNumber,
            etag: etag,
            offset: _confirmedBytes,
          );
        } catch (e) {
          firstError ??= e;
          return;
        }
      }
    }

    final remaining = queue.length;
    final workers = _maxConcurrent < remaining ? _maxConcurrent : remaining;
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);

    if (_cancelled) throw const _CancelledSignal();
    if (firstError != null) throw firstError!;
    return etags;
  }

  bool _isUploadInvalid(Object e) {
    if (e is! DioException) return false;
    if (e.response?.statusCode == 404) return true;
    final body = e.response?.data?.toString().toLowerCase() ?? '';
    return body.contains('nosuchupload');
  }

  /// Uploads one part, retrying transient failures with bounded backoff. Re-fetches
  /// an expired presigned URL when the contract supports it.
  Future<String> _uploadPartWithRetry(
    int fileIndex,
    UploadFileSpec file,
    InitiatedUpload init,
    UploadPartPlan part,
  ) async {
    final resolved = init.urlForPart(part.partNumber) ??
        await _api.refreshPartUrl(
            uploadId: init.uploadId,
            key: init.key,
            partNumber: part.partNumber);
    if (resolved == null) {
      throw StateError('no presigned URL for part ${part.partNumber}');
    }
    var url = resolved; // non-null; reassigned only to a non-null refreshed URL

    var attempt = 0;
    while (true) {
      attempt++;
      final token = CancelToken();
      _activeTokens.add(token);
      try {
        final etag = await _s3.putPart(
          url: url,
          body: _byteSource.read(file.path, part.offset, part.length),
          length: part.length,
          onSendProgress: (sent, _) => _onPartProgress(part.partNumber, sent),
          cancelToken: token,
        );
        return etag;
      } catch (e) {
        if (_cancelled || (e is DioException && CancelToken.isCancel(e)))
          rethrow;
        // Reset this part's in-flight contribution so a retry can't double-count.
        _inFlight[part.partNumber] = 0;

        final expired = _isExpired(e);
        if (expired) {
          final fresh = await _api.refreshPartUrl(
              uploadId: init.uploadId,
              key: init.key,
              partNumber: part.partNumber);
          if (fresh != null) url = fresh;
        }
        final transient = expired || _isTransient(e);
        if (!transient || attempt >= _retry.maxAttempts) rethrow;

        _emitRetry(fileIndex, part.partNumber, attempt);
        await _sleep(_retry.delayForAttempt(attempt));
      } finally {
        _activeTokens.remove(token);
      }
    }
  }

  Future<void> _abort(InitiatedUpload? init, String reason) async {
    if (init != null) {
      try {
        await _api.abort(uploadId: init.uploadId, key: init.key);
      } catch (_) {
        // Best-effort — never mask the original failure/cancel with an abort error.
      }
    }
    Analytics.logEvent(AnalyticsEvents.uploadMultipartAborted, {
      'capture_session_id': _sessionId,
      'reason': reason,
      'files_completed': _filesUploaded,
      'device_type': _deviceType,
    });
  }

  // ── pause gate + progress ─────────────────────────────────────────────────────

  Future<void> _awaitIfPaused() async {
    while (_paused && !_cancelled) {
      _pauseGate ??= Completer<void>();
      await _pauseGate!.future;
    }
  }

  void _autoPause() {
    if (!_paused) {
      _paused = true;
      _pendingPauseReason = 'connectivity';
      _setStatus(UploadStatus.paused);
    }
  }

  void _onPartProgress(int partNumber, int sent) {
    _inFlight[partNumber] = sent;
    _emit();
  }

  void _confirmBytes(UploadPartPlan part) {
    _inFlight.remove(part.partNumber);
    _confirmedBytes += part.length;
    _emit();
  }

  void _emit() {
    var candidate = _confirmedBytes;
    for (final v in _inFlight.values) {
      candidate += v;
    }
    if (candidate > _reportedBytes) _reportedBytes = candidate;
    if (_totalBytes > 0 && _reportedBytes > _totalBytes) {
      _reportedBytes = _totalBytes;
    }
    _push(_progress.copyWith(
      bytesUploaded: _reportedBytes,
      filesUploaded: _filesUploaded,
    ));
    _fireProgressMilestones();
  }

  /// Emits `upload_progress` the first time cumulative progress crosses each
  /// 25% milestone — at most once per milestone per run ([_milestonesFired],
  /// cleared in [_reset]); a multi-milestone jump fires each crossed one in
  /// ascending order. Based on [_reportedBytes], which is MONOTONIC, so
  /// pause/resume and part-retry dips can never re-fire a milestone. Skipped
  /// entirely while totalBytes is 0/unknown (no div-by-zero, no bogus 100%).
  /// The 100% milestone is intra-upload signal — [uploadCompleted] (status
  /// edge) remains the completion event.
  void _fireProgressMilestones() {
    if (_totalBytes <= 0) return;
    final pct = _reportedBytes * 100 ~/ _totalBytes;
    for (final m in const [25, 50, 75, 100]) {
      if (pct >= m && _milestonesFired.add(m)) {
        Analytics.logEvent(AnalyticsEvents.uploadProgress, {
          'capture_session_id': _sessionId,
          'milestone_pct': m,
          'bytes_uploaded': _reportedBytes,
          'upload_size_mb': bytesToMb(_totalBytes),
          'device_type': _deviceType,
        });
      }
    }
  }

  void _setStatus(UploadStatus status) {
    final previous = _progress.status;
    _push(_progress.copyWith(status: status));
    // Emission rides the transition itself: a status change cannot happen
    // without its lifecycle event, and repeated reads/rebuilds (which never
    // reach here) cannot re-emit. Same-status calls are edge-guarded.
    if (previous != status) _logLifecycle(previous, status);
  }

  /// Canonical upload lifecycle funnel (upload_started/paused/resumed/
  /// completed/failed), fired once per genuine status EDGE from the engine's
  /// single transition point. Part-level telemetry ([_emitRetry], [_abort])
  /// sits below this and never fires lifecycle events. CANCEL is deliberately
  /// silent here — it is not a failure; the tap-intent `upload_cancelled` and
  /// `upload_multipart_aborted{reason: cancelled}` already cover it. An
  /// auto-retry re-[start] is a new engine run and emits a fresh
  /// upload_started (attempt context lives in the runner's
  /// upload_attempt_started).
  void _logLifecycle(UploadStatus previous, UploadStatus status) {
    switch (status) {
      case UploadStatus.inProgress:
        if (previous == UploadStatus.paused) {
          Analytics.logEvent(AnalyticsEvents.uploadResumed, {
            'capture_session_id': _sessionId,
            'files_uploaded': _filesUploaded,
            'bytes_uploaded': _reportedBytes,
            'device_type': _deviceType,
          });
        } else {
          _startedAt = DateTime.now();
          Analytics.logEvent(AnalyticsEvents.uploadStarted, {
            'capture_session_id': _sessionId,
            'total_files': _totalFiles,
            'total_bytes': _totalBytes,
            'upload_size_mb': bytesToMb(_totalBytes),
            'device_type': _deviceType,
          });
        }
      case UploadStatus.paused:
        Analytics.logEvent(AnalyticsEvents.uploadPaused, {
          'capture_session_id': _sessionId,
          'files_uploaded': _filesUploaded,
          'bytes_uploaded': _reportedBytes,
          'pause_reason': _pendingPauseReason ?? 'other',
          'device_type': _deviceType,
        });
        _pendingPauseReason = null;
      case UploadStatus.completed:
        Analytics.logEvent(AnalyticsEvents.uploadCompleted, {
          'capture_session_id': _sessionId,
          'total_files': _totalFiles,
          'total_bytes': _totalBytes,
          'upload_size_mb': bytesToMb(_totalBytes),
          'duration_ms': _startedAt == null
              ? null
              : DateTime.now().difference(_startedAt!).inMilliseconds,
          'device_type': _deviceType,
        });
      case UploadStatus.failed:
        Analytics.logEvent(AnalyticsEvents.uploadFailed, {
          'capture_session_id': _sessionId,
          'files_uploaded': _filesUploaded,
          'bytes_uploaded': _reportedBytes,
          // Set by the failure site BEFORE the status flip (see _uploadOneFile).
          'failure_reason': _lastFailureReason ?? 'unknown',
          'device_type': _deviceType,
        });
      case UploadStatus.cancelled:
      case UploadStatus.idle:
        break; // cancel ≠ failure; idle is never entered via _setStatus.
    }
  }

  void _push(UploadProgress next) {
    _progress = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  void _reset(UploadSessionSpec session) {
    _sessionId = session.sessionId;
    _totalBytes = session.totalBytes;
    _totalFiles = session.totalFiles;
    _filesUploaded = 0;
    _confirmedBytes = 0;
    _reportedBytes = 0;
    _inFlight.clear();
    _cancelled = false;
    _paused = false;
    _pauseGate = null;
    _lastFailureReason = null;
    _lastFailureError = null;
    _startedAt = null;
    _pendingPauseReason = null;
    _milestonesFired.clear(); // fresh run reports its milestones again
    _progress = UploadProgress(
      status: UploadStatus.idle,
      bytesUploaded: 0,
      totalBytes: _totalBytes,
      filesUploaded: 0,
      totalFiles: _totalFiles,
    );
  }

  void _emitRetry(int fileIndex, int partNumber, int attempt) {
    Analytics.logEvent(AnalyticsEvents.uploadPartRetry, {
      'capture_session_id': _sessionId,
      'file_index': fileIndex,
      'part_number': partNumber,
      'attempt': attempt,
      'device_type': _deviceType,
    });
  }

  bool _isExpired(Object e) =>
      e is DioException && e.response?.statusCode == 403;

  bool _isTransient(Object e) {
    if (e is! DioException) return false;
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode ?? 0;
        return code >= 500;
      default:
        return false;
    }
  }

  /// Releases resources. After this the manager must not be reused.
  Future<void> dispose() async {
    await _controller.close();
  }
}
