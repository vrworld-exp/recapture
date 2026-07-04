// lib/application/upload/upload_progress_reporter.dart
//
// The REPORTING layer over the existing uploader's raw progress. It observes a
// source `Stream<UploadProgress>` (the ChunkedUploadManager, via its
// [UploadProgressSource.watch]) and re-publishes a [UploadProgressView] that is:
//
//   • THROTTLED / COALESCED — raw byte callbacks fire per chunk and would flood the
//     UI. This coalesces to a bounded set of emits: a snapshot is published only on
//     a MEANINGFUL change — a byte fraction moving ≥ [minFractionDelta] (default 1%),
//     a file completing, a phase change, the final 100%, or a terminal status —
//     never once per chunk. (Time-independent, so it's deterministic + testable and
//     bounds emits to ~100 byte-updates over a whole upload.)
//   • PHASE-AWARE — [markRetrying]/[markUploading]/[markFinalizing] let the retry
//     layer surface a "retrying" phase during a backoff wait (counts hold steady, so
//     the bar shows retrying rather than looking frozen).
//   • MONOTONIC — byte progress never slides backward; the ONLY backward move is an
//     explicit [reset] (a genuine full restart → an intentional 0/total signal).
//   • LATE-SUBSCRIBER-SAFE — [watch] replays the current [latest] snapshot to a new
//     listener immediately (broadcast), and [latest] is readable synchronously.
//
// It does NOT own the outcome: success/failure/cancel stays with the upload
// controller / Screen 9F. On a terminal source status this emits the final snapshot
// then CLOSES — no events after close.
import 'dart:async';

import '../../domain/entities/upload_progress.dart';
import '../../domain/upload/upload_progress_view.dart';
import '../../utils/analytics.dart';

class UploadProgressReporter {
  UploadProgressReporter(
    Stream<UploadProgress> source, {
    this.minFractionDelta = 0.01,
    this.emitMilestones = true,
    String? sessionId,
    String deviceType = 'mobile',
    void Function(String name, Map<String, Object?> props)? analytics,
  })  : _sessionId = sessionId,
        _deviceType = deviceType,
        _analytics = analytics ?? Analytics.logEvent {
    _sub = source.listen(_onSource, onError: (_) {}, onDone: _close);
  }

  /// Minimum byte-fraction change (0..1) that triggers an emit between milestones
  /// (1% default) — the coalescing threshold that keeps the UI from being flooded.
  final double minFractionDelta;
  final bool emitMilestones;
  final String? _sessionId;
  final String _deviceType;
  final void Function(String, Map<String, Object?>) _analytics;

  final StreamController<UploadProgressView> _out =
      StreamController<UploadProgressView>.broadcast();
  StreamSubscription<UploadProgress>? _sub;

  UploadProgressView _latest = UploadProgressView.initial;
  UploadProgressView? _lastEmitted;
  int _maxBytes = 0; // monotonic guard baseline
  UploadPhase _phase = UploadPhase.uploading;
  int _retryAttempt = 0;
  final Set<int> _milestonesFired = {};
  bool _closed = false;

  /// The current snapshot — readable synchronously so a subscriber attaching late
  /// (screen reopened mid-upload) renders immediately.
  UploadProgressView get latest => _latest;

  /// Per-subscriber stream that replays [latest] first, then forwards live updates.
  /// Subscribes to the broadcast source EAGERLY (before returning) so there is no
  /// gap between the replayed snapshot and live events — a late subscriber never
  /// misses an emit that lands during attach.
  Stream<UploadProgressView> watch() {
    final controller = StreamController<UploadProgressView>();
    controller.add(_latest); // buffered until the caller listens
    if (_closed) {
      controller.close(); // already terminal → just the final snapshot
      return controller.stream;
    }
    final s = _out.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = s.cancel;
    return controller.stream;
  }

  // ── phase controls (driven by the retry layer) ──────────────────────────────

  /// Enter the retrying phase (backoff wait): counts hold, phase flips → an emit.
  void markRetrying(int attempt) {
    _retryAttempt = attempt;
    _setPhase(UploadPhase.retrying);
  }

  /// Back to actively transferring (resume after backoff).
  void markUploading() {
    _retryAttempt = 0;
    _setPhase(UploadPhase.uploading);
  }

  /// The transfer is done and the multipart is being finalized.
  void markFinalizing() => _setPhase(UploadPhase.finalizing);

  /// Explicit FULL-RESTART reset → an intentional 0/total snapshot (the only
  /// sanctioned backward move). Totals are kept from the latest snapshot.
  void reset() {
    if (_closed) return;
    _maxBytes = 0;
    _milestonesFired.clear();
    _phase = UploadPhase.uploading;
    _retryAttempt = 0;
    final base = _latest.progress.copyWith(
      status: UploadStatus.inProgress,
      bytesUploaded: 0,
      filesUploaded: 0,
    );
    _latest = UploadProgressView(progress: base);
    _publish(_latest, force: true);
  }

  // ── source handling ─────────────────────────────────────────────────────────

  void _onSource(UploadProgress raw) {
    if (_closed) return;

    // Monotonic guard: never let confirmed bytes/files slide backward (the source
    // is already monotonic; this defends against a stray out-of-order snapshot).
    final bytes = raw.bytesUploaded > _maxBytes ? raw.bytesUploaded : _maxBytes;
    _maxBytes = bytes;
    final base = raw.copyWith(bytesUploaded: bytes);

    final terminal = _isTerminal(raw.status);
    // While transferring, keep the caller-set phase; a terminal status resolves it.
    final phase = terminal ? UploadPhase.uploading : _phase;
    final view = UploadProgressView(
      progress: base,
      phase: phase,
      retryAttempt: phase == UploadPhase.retrying ? _retryAttempt : 0,
    );
    _latest = view;

    if (emitMilestones) _fireMilestones(view.fraction);

    if (terminal) {
      _publish(view, force: true); // always emit the final snapshot
      _close();
      return;
    }
    _publish(view);
  }

  void _setPhase(UploadPhase phase) {
    if (_closed || _phase == phase) return;
    _phase = phase;
    final view = UploadProgressView(
      progress: _latest.progress,
      phase: phase,
      retryAttempt: phase == UploadPhase.retrying ? _retryAttempt : 0,
    );
    _latest = view;
    _publish(view, force: true); // a phase change is always meaningful
  }

  /// Coalescing decision: emit only on a meaningful change.
  void _publish(UploadProgressView view, {bool force = false}) {
    if (_closed) return;
    final prev = _lastEmitted;
    final shouldEmit = force ||
        prev == null ||
        view.filesUploaded != prev.filesUploaded ||
        view.phase != prev.phase ||
        (view.isBytesComplete && !prev.isBytesComplete) ||
        (view.fraction - prev.fraction).abs() >= minFractionDelta;
    if (!shouldEmit) return;
    _lastEmitted = view;
    _out.add(view);
  }

  void _fireMilestones(double fraction) {
    final pct = (fraction * 100).floor();
    for (final m in const [25, 50, 75, 100]) {
      if (pct >= m && _milestonesFired.add(m)) {
        _analytics(AnalyticsEvents.uploadProgressMilestone, {
          'session_id': _sessionId,
          'milestone': m,
          'device_type': _deviceType,
        });
      }
    }
  }

  bool _isTerminal(UploadStatus s) =>
      s == UploadStatus.completed ||
      s == UploadStatus.failed ||
      s == UploadStatus.cancelled;

  void _close() {
    if (_closed) return;
    _closed = true;
    _sub?.cancel();
    _out.close();
  }

  /// Releases the source subscription + closes the stream (idempotent).
  Future<void> dispose() async {
    _close();
  }
}
