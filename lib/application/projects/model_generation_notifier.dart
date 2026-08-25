// lib/application/projects/model_generation_notifier.dart
//
// Tracks one project's Meshy model generations for the staff surface, keyed by
// projectId (family).
//
// Meshy takes MINUTES, and the backend is poll-based (no push), so this polls
// `GET /admin/projects/:id/models` while any record is QUEUED/PROCESSING and
// stops the moment nothing is pending. The backoff + attempt cap exist so a
// stuck generation degrades into a quiet, cheap loop rather than hammering a
// rate-limited staff endpoint forever.
//
// State is the full HISTORY (newest first) — the artist compares attempts and
// approves one.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/live_projects_repository.dart';
import '../../domain/entities/project_model.dart';

/// Poll cadence. Starts short (a fast generation feels instant) and backs off
/// toward [_maxInterval]. Capped at 10s (not higher): each poll now carries the
/// record's live `progress`, and a progress bar that only moves every 20s+
/// reads as frozen.
const _initialInterval = Duration(seconds: 3);
const _maxInterval = Duration(seconds: 10);

/// Hard stop. At this cadence the cap covers well past the backend's
/// MESHY_TASK_TIMEOUT_MS (10 min), after which the worker itself gives up and
/// the record turns FAILED — so a still-pending record here means something is
/// wrong and polling forever would not fix it.
const _maxPolls = 120;

class ModelGenerationNotifier
    extends FamilyAsyncNotifier<List<ProjectModelView>, String> {
  Timer? _timer;
  int _polls = 0;
  Duration _interval = _initialInterval;

  @override
  Future<List<ProjectModelView>> build(String projectId) async {
    // Auto-disposed with the screen; make sure the loop dies with it rather
    // than polling on behalf of a route nobody is looking at.
    ref.onDispose(_stop);
    final models = await ref.read(liveProjectsRepositoryProvider).listModels(projectId);
    _scheduleIfPending(models);
    return models;
  }

  /// Whether any record is still expected to change — the loop's stop condition.
  bool get isPolling => _timer != null;

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _scheduleIfPending(List<ProjectModelView> models) {
    _stop();
    if (!models.any((m) => m.status.isPending)) return;
    if (_polls >= _maxPolls) return;
    _timer = Timer(_interval, _poll);
  }

  Future<void> _poll() async {
    _polls++;
    try {
      final models = await ref.read(liveProjectsRepositoryProvider).listModels(arg);
      state = AsyncData(models);
      // Ease off only while we keep waiting; a fresh request resets the cadence.
      _interval = _interval * 2 > _maxInterval ? _maxInterval : _interval * 2;
      _scheduleIfPending(models);
    } catch (_) {
      // A transient failure must not blank the list the user is looking at —
      // keep the last good state and try again on the next tick. A permanent
      // failure simply runs out the poll cap.
      _scheduleIfPending(state.valueOrNull ?? const []);
    }
  }

  /// Re-reads the history now and restarts the polling cadence — used after a
  /// Create Model request so the new QUEUED record appears immediately.
  Future<void> refresh() async {
    _polls = 0;
    _interval = _initialInterval;
    final next = await AsyncValue.guard(
      () => ref.read(liveProjectsRepositoryProvider).listModels(arg),
    );
    state = next;
    _scheduleIfPending(next.valueOrNull ?? const []);
  }

  /// Requests a generation from [keys] (3–4 photos), then refreshes so the
  /// caller can watch it. Rethrows [LiveProjectsException] for mapped copy.
  Future<ProjectModelView> createModel(
    List<String> keys, {
    required String idempotencyKey,
  }) async {
    final model = await ref
        .read(liveProjectsRepositoryProvider)
        .createModel(arg, keys, idempotencyKey: idempotencyKey);
    await refresh();
    return model;
  }

  /// Asks the backend to optimize [modelId], then refreshes so the new pending
  /// `OPT` row appears immediately.
  ///
  /// The refresh is the ONLY wiring this needs: the existing poll loop already
  /// drives any pending record to done, and the OPT record is pending like any
  /// other. A second loop for optimization would be two things racing to write
  /// the same state.
  ///
  /// Rethrows [LiveProjectsException] so the caller can render mapped copy.
  Future<void> optimize(String modelId) async {
    await ref.read(liveProjectsRepositoryProvider).optimizeModel(arg, modelId);
    await refresh();
  }

  /// Approves [modelId] and reflects it locally without a re-fetch.
  Future<void> approve(String modelId) async {
    final approved =
        await ref.read(liveProjectsRepositoryProvider).approveModel(arg, modelId);
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData([
      for (final m in current) if (m.id == approved.id) approved else m,
    ]);
  }
}

/// A project's model-generation history + live polling. Auto-disposed with the
/// screen (the poll loop stops with it).
final modelGenerationProvider = AsyncNotifierProvider.family<
    ModelGenerationNotifier, List<ProjectModelView>, String>(
  ModelGenerationNotifier.new,
);
