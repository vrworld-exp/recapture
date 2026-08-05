// lib/application/projects/owner_model_state_notifier.dart
//
// Tracks ONE project's model situation as the OWNER sees it, keyed by projectId
// (family): the finished model it has, and the generation it is waiting on.
//
// Why this exists next to [ModelGenerationNotifier] rather than reusing it: that
// one polls `GET /admin/projects/:id/models`, a STAFF endpoint an owner is
// forbidden from calling (403). This one polls the owner's own
// `GET /projects/:id`. Same shape of problem, different audience and different
// route — sharing the notifier would mean sharing an endpoint the owner cannot
// reach.
//
// Automatic generation is what makes this necessary at all: before it, a model
// only ever appeared because the user asked for one, so there was nothing to
// watch. Now a generation can start on its own after a capture, and the app has
// to be able to say "we're building it" without the user having requested
// anything.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/projects_repository.dart';

/// Poll cadence — mirrors the staff notifier: short at first so a quick
/// generation feels immediate, backing off to a cheap steady tick.
const _initialInterval = Duration(seconds: 3);
const _maxInterval = Duration(seconds: 10);

/// Hard stop. At this cadence the cap runs well past the backend's
/// MESHY_TASK_TIMEOUT_MS, after which the worker gives up and the record turns
/// FAILED on its own — a record still pending here means something is wrong,
/// and polling forever would not fix it.
const _maxPolls = 120;

/// A much SHORTER cap for the optimization tail — the polls after the model is
/// already generated and we are only waiting for the web build.
///
/// It is short because the downside is asymmetric. The model already exists and
/// can be shown; every extra poll is a user staring at a progress screen for a
/// model that is sitting there. ~20 polls is a couple of minutes at this
/// cadence, which comfortably covers a real pipeline run, and if the
/// optimization worker is down we fail OPEN to the original rather than hiding
/// a finished model behind a job that is never going to report.
const _maxOptimizationPolls = 20;

class OwnerModelStateNotifier extends FamilyAsyncNotifier<OwnerModelState, String> {
  Timer? _timer;
  int _polls = 0;

  /// Polls spent waiting on the optimization tail specifically — counted apart
  /// from [_polls] because it has its own, much smaller budget.
  int _optimizationPolls = 0;
  Duration _interval = _initialInterval;

  @override
  Future<OwnerModelState> build(String projectId) async {
    // Dies with the screen — never poll on behalf of a route nobody is on.
    ref.onDispose(_stop);
    final state = await ref.read(projectsRepositoryProvider).fetchModelState(projectId);
    _scheduleIfPending(state);
    return state;
  }

  bool get isPolling => _timer != null;

  /// The poll cap ran out while a generation was still pending.
  ///
  /// Exposed because a silent stop is indistinguishable from a frozen screen:
  /// the UI has to be able to say "we've stopped checking" rather than showing
  /// a spinner that will never resolve. Readable on the final rebuild — the
  /// last poll updates state, and the reschedule it declines to make is what
  /// sets this.
  bool get pollsExhausted =>
      _polls >= _maxPolls && (state.valueOrNull?.isGenerating ?? false);

  /// We gave up waiting for the web-optimized build, but the model itself is
  /// finished and openable.
  ///
  /// The screen's cue to stop waiting and show the ORIGINAL: a heavier model
  /// the user can open beats a progress bar for a job that is not reporting.
  /// Distinct from [pollsExhausted], which means the GENERATION itself never
  /// resolved and there is nothing to show at all.
  bool get optimizationWaitExhausted =>
      _optimizationPolls >= _maxOptimizationPolls &&
      (state.valueOrNull?.model?.optimizationPending ?? false);

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _scheduleIfPending(OwnerModelState modelState) {
    _stop();
    if (!modelState.isGenerating) return;
    if (_polls >= _maxPolls) return;
    // Only the optimization tail is left, and its own budget is spent. Stop:
    // [optimizationWaitExhausted] now tells the screen to show what we have.
    if (_isOnlyOptimizing(modelState) && _optimizationPolls >= _maxOptimizationPolls) {
      return;
    }
    _timer = Timer(_interval, _poll);
  }

  /// The generation is done and only the web build is outstanding — the state
  /// the short budget applies to.
  static bool _isOnlyOptimizing(OwnerModelState modelState) =>
      !(modelState.generation?.isPending ?? false) &&
      (modelState.model?.optimizationPending ?? false);

  Future<void> _poll() async {
    _polls++;
    if (_isOnlyOptimizing(state.valueOrNull ?? const OwnerModelState())) {
      _optimizationPolls++;
    }
    try {
      final next = await ref.read(projectsRepositoryProvider).fetchModelState(arg);
      state = AsyncData(next);
      _interval = _interval * 2 > _maxInterval ? _maxInterval : _interval * 2;
      _scheduleIfPending(next);
    } catch (_) {
      // A transient failure must not blank a screen that is already showing a
      // perfectly good model — keep the last good state and retry next tick.
      // A permanent failure just runs out the poll cap.
      final current = state.valueOrNull;
      if (current != null) _scheduleIfPending(current);
    }
  }

  /// Re-reads now and restarts the cadence — for pull-to-refresh and for
  /// returning to the screen after a regenerate.
  Future<void> refresh() async {
    _polls = 0;
    _optimizationPolls = 0;
    _interval = _initialInterval;
    final next = await AsyncValue.guard(
      () => ref.read(projectsRepositoryProvider).fetchModelState(arg),
    );
    state = next;
    final value = next.valueOrNull;
    if (value != null) _scheduleIfPending(value);
  }
}

/// A project's owner-visible model state + live polling while a generation runs.
/// Auto-disposed with the screen.
final ownerModelStateProvider = AsyncNotifierProvider.family<
    OwnerModelStateNotifier, OwnerModelState, String>(
  OwnerModelStateNotifier.new,
);
