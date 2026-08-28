// lib/domain/upload/upload_flow_steps.dart
//
// Pure Dart — NO Flutter / IO imports. The STEP TIMELINE contract for the real
// upload flow (Screen 9's live step tracker): the five orchestrator stages —
// pack → POST /projects → POST /jobs → transfer → finalize — as an immutable
// state machine the flow transitions and the screen renders.
//
// Invariants (enforced here, in one place):
//   • steps run IN ORDER: a step can only start when every earlier step is
//     done and no other step is running;
//   • starting a step never completes anything implicitly;
//   • a failed or cancelled step is TERMINAL for the whole timeline — no
//     further transition is accepted;
//   • an invalid transition is a defensive NO-OP (returns `this`), never a
//     throw: a tracker bookkeeping bug must not be able to fail a real upload.
//
// Display privacy split: [UploadFlowStepState.info] is the prod-safe line
// (counts/sizes only — rendered in every flavor); [devDetail] carries raw
// diagnostics (ids, paths, exception text) and is rendered ONLY in non-prod
// flavors. The PRODUCER additionally gates devDetail collection on the flavor
// (see upload_flow.dart) so production builds never even hold the strings.

/// The five stages of the real upload flow, in execution order.
enum UploadFlowStepId { prepare, createProject, createJob, transfer, finalize }

/// One step's lifecycle. [cancelled] mirrors the flow's transfer-aborted
/// semantics: the step was abandoned at the user's request, not failed.
enum UploadStepStatus { pending, running, done, failed, cancelled }

/// Immutable snapshot of one step.
class UploadFlowStepState {
  const UploadFlowStepState({
    required this.id,
    this.status = UploadStepStatus.pending,
    this.startedAt,
    this.endedAt,
    this.info,
    this.devDetail = const [],
  });

  final UploadFlowStepId id;
  final UploadStepStatus status;
  final DateTime? startedAt;
  final DateTime? endedAt;

  /// Prod-safe display line (counts/sizes only) — e.g. "37 files · 4.2 MB".
  final String? info;

  /// Raw diagnostic lines (ids, key prefixes, exception text). Rendered only
  /// in non-production flavors; never in the prod UI.
  final List<String> devDetail;

  bool get isPending => status == UploadStepStatus.pending;
  bool get isRunning => status == UploadStepStatus.running;
  bool get isDone => status == UploadStepStatus.done;
  bool get isFailed => status == UploadStepStatus.failed;
  bool get isCancelled => status == UploadStepStatus.cancelled;

  UploadFlowStepState _copyWith({
    UploadStepStatus? status,
    DateTime? startedAt,
    DateTime? endedAt,
    String? info,
    bool clearInfo = false,
    List<String>? devDetail,
  }) =>
      UploadFlowStepState(
        id: id,
        status: status ?? this.status,
        startedAt: startedAt ?? this.startedAt,
        endedAt: endedAt ?? this.endedAt,
        info: clearInfo ? null : (info ?? this.info),
        devDetail: devDetail ?? this.devDetail,
      );

  @override
  String toString() => 'UploadFlowStepState(${id.name}: ${status.name}'
      '${info == null ? '' : ', "$info"'})';
}

/// The whole flow's step list — an immutable value; every transition returns
/// a new timeline (or `this` unchanged when the transition is invalid).
class UploadFlowTimeline {
  UploadFlowTimeline._(this.steps);

  /// All five steps pending, in canonical order.
  factory UploadFlowTimeline.initial() => UploadFlowTimeline._(
        List.unmodifiable(UploadFlowStepId.values
            .map((id) => UploadFlowStepState(id: id))),
      );

  /// Steps in canonical execution order (index == [UploadFlowStepId.index]).
  final List<UploadFlowStepState> steps;

  UploadFlowStepState operator [](UploadFlowStepId id) => steps[id.index];

  /// The step currently running, if any.
  UploadFlowStepId? get runningId {
    for (final s in steps) {
      if (s.isRunning) return s.id;
    }
    return null;
  }

  bool get hasFailure => steps.any((s) => s.isFailed);
  bool get isCancelled => steps.any((s) => s.isCancelled);
  bool get isAllDone => steps.every((s) => s.isDone);

  /// No further transition is accepted once true.
  bool get isTerminal => hasFailure || isCancelled || isAllDone;

  /// The flow's first activity (drives the summary duration).
  DateTime? get firstStartedAt {
    for (final s in steps) {
      if (s.startedAt != null) return s.startedAt;
    }
    return null;
  }

  /// The last recorded step end (null while nothing has ended).
  DateTime? get lastEndedAt {
    DateTime? last;
    for (final s in steps) {
      final e = s.endedAt;
      if (e != null && (last == null || e.isAfter(last))) last = e;
    }
    return last;
  }

  UploadFlowTimeline _replace(UploadFlowStepId id, UploadFlowStepState next) =>
      UploadFlowTimeline._(List.unmodifiable([
        for (final s in steps) s.id == id ? next : s,
      ]));

  /// Starts [id]. Valid only when the timeline is not terminal, [id] is
  /// pending, every earlier step is done, and nothing else is running.
  UploadFlowTimeline start(
    UploadFlowStepId id, {
    DateTime? at,
    List<String> devDetail = const [],
  }) {
    if (isTerminal || !this[id].isPending || runningId != null) return this;
    for (var i = 0; i < id.index; i++) {
      if (!steps[i].isDone) return this;
    }
    return _replace(
      id,
      this[id]._copyWith(
        status: UploadStepStatus.running,
        startedAt: at ?? DateTime.now(),
        devDetail: devDetail.isEmpty ? null : devDetail,
      ),
    );
  }

  /// Completes the RUNNING step [id] (no-op from any other state).
  UploadFlowTimeline complete(
    UploadFlowStepId id, {
    String? info,
    List<String> devDetail = const [],
    DateTime? at,
  }) {
    if (isTerminal || !this[id].isRunning) return this;
    return _replace(
      id,
      this[id]._copyWith(
        status: UploadStepStatus.done,
        endedAt: at ?? DateTime.now(),
        info: info,
        devDetail:
            devDetail.isEmpty ? null : [...this[id].devDetail, ...devDetail],
      ),
    );
  }

  /// Updates the RUNNING step's info line (the transfer step's transient
  /// "Retrying…" note). `null` clears it. No-op unless [id] is running.
  UploadFlowTimeline updateInfo(UploadFlowStepId id, String? info) {
    if (isTerminal || !this[id].isRunning || this[id].info == info) {
      return this;
    }
    return _replace(
      id,
      this[id]._copyWith(info: info, clearInfo: info == null),
    );
  }

  /// Fails [id] — terminal for the whole timeline. Valid from running or
  /// pending (a step can fail before its start transition landed).
  UploadFlowTimeline fail(
    UploadFlowStepId id, {
    String? info,
    List<String> devDetail = const [],
    DateTime? at,
  }) {
    final s = this[id];
    if (isTerminal || (!s.isRunning && !s.isPending)) return this;
    return _replace(
      id,
      s._copyWith(
        status: UploadStepStatus.failed,
        endedAt: at ?? DateTime.now(),
        info: info,
        devDetail: devDetail.isEmpty ? null : [...s.devDetail, ...devDetail],
      ),
    );
  }

  /// Fails the running step; when none is running, the first pending step
  /// (a failure landing between steps still gets pinned somewhere honest).
  UploadFlowTimeline failRunning({
    String? info,
    List<String> devDetail = const [],
    DateTime? at,
  }) {
    if (isTerminal) return this;
    final id = runningId ??
        steps.where((s) => s.isPending).map((s) => s.id).firstOrNull;
    if (id == null) return this;
    return fail(id, info: info, devDetail: devDetail, at: at);
  }

  /// Cancels the running + pending steps — terminal for the whole timeline.
  UploadFlowTimeline cancelRemaining({DateTime? at}) {
    if (isTerminal) return this;
    final when = at ?? DateTime.now();
    return UploadFlowTimeline._(List.unmodifiable([
      for (final s in steps)
        if (s.isRunning || s.isPending)
          s._copyWith(status: UploadStepStatus.cancelled, endedAt: when)
        else
          s,
    ]));
  }

  @override
  String toString() =>
      'UploadFlowTimeline(${steps.map((s) => '${s.id.name}=${s.status.name}').join(', ')})';
}
