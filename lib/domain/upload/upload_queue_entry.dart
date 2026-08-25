// lib/domain/upload/upload_queue_entry.dart
//
// Pure Dart — NO Flutter / IO. The durable JOB model of the offline upload
// queue: one entry per upload session, carrying the session spec (so the job is
// re-runnable after a restart), its lifecycle state, and its FIFO order.
//
// THE KEY DISTINCTION this model exists to keep durable: [UploadJobState.userPaused]
// (explicit user intent — never auto-resumed) vs [UploadJobState.offlineQueued]
// ("waiting for connection" — auto-resumed when connectivity returns). A
// connectivity event must never override user intent, so the distinction is part
// of the persisted record, not transient coordinator memory.
//
// The byte-level resume point (server uploadId + confirmed part ETags + offset)
// is NOT here — that stays in the resumable [UploadProgressStore] keyed by the
// same sessionId; this entry is the queue-level bookkeeping ABOVE it. Auto-resume
// re-runs the job and the engine continues from that persisted state.
import 'upload_failure.dart';
import 'upload_session_spec.dart';

/// The queue-level lifecycle of one upload job.
///
/// [userPaused] and [offlineQueued] are deliberately distinct: the first is user
/// intent (stays paused when connectivity returns; only a manual resume clears
/// it), the second is a connectivity wait (auto-resumes on restore).
enum UploadJobState {
  /// The job is being transferred right now (first run).
  uploading,

  /// The user explicitly paused. STAYS paused across connectivity restores and
  /// restarts — only a manual resume moves it on.
  userPaused,

  /// Waiting for connection: the device was offline at start, or a transfer hit
  /// a network failure. Auto-resumes (from the persisted offset/ETags) when
  /// connectivity is restored. This is NOT a failure state.
  offlineQueued,

  /// A re-run after a previous network interruption (attempts > 0) is in flight.
  retrying,

  /// Terminal: the whole session finished.
  completed,

  /// Terminal: a NON-network failure the auto-retry layer could not recover
  /// (Screen 9F's territory). Network failures never land here — they queue.
  failed,

  /// Terminal: the user aborted the transfer. Local captured data is retained.
  cancelled;

  /// Wire/persistence name (stable; do not rename members without a migration).
  String get wire => name;

  static UploadJobState fromWire(Object? raw) => UploadJobState.values
      .firstWhere((s) => s.name == raw, orElse: () => UploadJobState.offlineQueued);
}

/// One durable queue entry. Immutable; transitions produce a new entry via
/// [copyWith].
class UploadQueueEntry {
  const UploadQueueEntry({
    required this.jobId,
    required this.spec,
    required this.state,
    required this.seq,
    this.attempts = 0,
    this.lastErrorCategory,
  });

  /// The job id — the upload session id (also the [UploadProgressStore] key).
  final String jobId;

  /// The full session payload, persisted so the job is re-runnable after an app
  /// restart without any in-memory context.
  final UploadSessionSpec spec;

  final UploadJobState state;

  /// FIFO order: entries drain in ascending [seq] (multiple queued jobs resume
  /// in the order they were enqueued).
  final int seq;

  /// Queue-level run count (times a drain has picked this job up). Drives the
  /// uploading-vs-retrying presentation; the transfer/backoff retries themselves
  /// live in the engine + session-retry layers.
  final int attempts;

  /// The classified category of the last failure (set for [UploadJobState.failed];
  /// informational otherwise). Never a raw error — the 9F privacy invariant.
  final UploadErrorCategory? lastErrorCategory;

  /// "Waiting for connection" — the state the UI surfaces instead of a failure.
  bool get isWaitingForConnection => state == UploadJobState.offlineQueued;

  /// Auto-resume applies ONLY to offline-queued jobs — never [UploadJobState.userPaused].
  bool get isAutoResumable => state == UploadJobState.offlineQueued;

  bool get isTerminal =>
      state == UploadJobState.completed ||
      state == UploadJobState.failed ||
      state == UploadJobState.cancelled;

  UploadQueueEntry copyWith({
    UploadJobState? state,
    int? attempts,
    UploadErrorCategory? lastErrorCategory,
  }) =>
      UploadQueueEntry(
        jobId: jobId,
        spec: spec,
        state: state ?? this.state,
        seq: seq,
        attempts: attempts ?? this.attempts,
        lastErrorCategory: lastErrorCategory ?? this.lastErrorCategory,
      );

  // ── persistence codec (repo convention: JSON in a Box<String>) ─────────────

  Map<String, Object?> toJson() => {
        'jobId': jobId,
        'state': state.wire,
        'seq': seq,
        'attempts': attempts,
        if (lastErrorCategory != null)
          'lastErrorCategory': lastErrorCategory!.wireName,
        'spec': {
          'sessionId': spec.sessionId,
          'files': [
            for (final f in spec.files)
              {'path': f.path, 'key': f.key, 'size': f.size},
          ],
        },
      };

  /// Strict on the fields that make the job re-runnable (id + spec); tolerant on
  /// the rest. Throws [FormatException] on an unreplayable blob — the store
  /// catches it and treats the entry as absent (corruption policy).
  factory UploadQueueEntry.fromJson(Map<String, Object?> json) {
    final jobId = json['jobId'];
    final specRaw = json['spec'];
    if (jobId is! String || specRaw is! Map) {
      throw const FormatException('unreplayable upload queue entry');
    }
    final sessionId = specRaw['sessionId'];
    final filesRaw = specRaw['files'];
    if (sessionId is! String || filesRaw is! List) {
      throw const FormatException('unreplayable upload session spec');
    }
    final files = <UploadFileSpec>[
      for (final f in filesRaw)
        if (f is Map)
          UploadFileSpec(
            path: f['path'] as String? ?? '',
            key: f['key'] as String? ?? '',
            size: (f['size'] as num?)?.toInt() ?? 0,
          ),
    ];
    return UploadQueueEntry(
      jobId: jobId,
      spec: UploadSessionSpec(sessionId: sessionId, files: files),
      state: UploadJobState.fromWire(json['state']),
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
      lastErrorCategory: _categoryFromWire(json['lastErrorCategory']),
    );
  }

  static UploadErrorCategory? _categoryFromWire(Object? raw) {
    if (raw is! String) return null;
    for (final c in UploadErrorCategory.values) {
      if (c.wireName == raw) return c;
    }
    return null;
  }
}

/// The offline-queued entries in FIFO ([UploadQueueEntry.seq]-ascending) order —
/// exactly the set (and order) a connectivity restore auto-resumes. User-paused
/// and terminal entries are excluded by definition.
List<UploadQueueEntry> autoResumableJobs(Iterable<UploadQueueEntry> entries) {
  final out = [
    for (final e in entries)
      if (e.isAutoResumable) e,
  ]..sort((a, b) => a.seq.compareTo(b.seq));
  return out;
}

/// Restart reconciliation for one restored entry:
///   • a job persisted as running ([uploading]/[retrying]) was interrupted by the
///     kill — it is NOT running now, so it re-queues as [offlineQueued] (the
///     resume point survives in the resumable store);
///   • [userPaused] survives untouched (user intent outlives the process);
///   • terminal states return null — a finished/cancelled job has no business
///     being restored into the queue (stale row → drop).
UploadQueueEntry? reconcileOnRestore(UploadQueueEntry entry) {
  if (entry.isTerminal) return null;
  if (entry.state == UploadJobState.uploading ||
      entry.state == UploadJobState.retrying) {
    return entry.copyWith(state: UploadJobState.offlineQueued);
  }
  return entry; // userPaused / offlineQueued restore as-is
}
