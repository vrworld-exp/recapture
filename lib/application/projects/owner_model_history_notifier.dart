// lib/application/projects/owner_model_history_notifier.dart
//
// One project's model history for the OWNER surface, keyed by projectId
// (family) — the owner-safe twin of [ModelGenerationNotifier].
//
// A separate notifier rather than a role flag on the staff one, for the same
// reason the repository keeps two list methods: they poll DIFFERENT ROUTES
// returning DIFFERENT PAYLOADS. One notifier switching on a role would hold
// state whose shape depends on who is looking, and every reader downstream
// would have to know which variant it got. Two notifiers each hold one shape.
//
// The polling contract is deliberately identical to the staff notifier's, since
// it is the same backend job queue being watched: poll while anything is
// pending, back off toward a ceiling, and stop at a hard cap so a stuck record
// degrades into a quiet loop rather than hammering the route forever.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/live_projects_repository.dart';
import '../../domain/entities/project_model.dart';

/// Poll cadence — same shape as the staff notifier: short at first so a quick
/// optimization feels instant, easing off to [_maxInterval].
const _initialInterval = Duration(seconds: 3);
const _maxInterval = Duration(seconds: 10);

/// Hard stop. Well past the backend's own worker timeouts, after which a record
/// turns FAILED on its own — a record still pending here means something is
/// wrong that more polling cannot fix.
const _maxPolls = 120;

class OwnerModelHistoryNotifier
    extends AutoDisposeFamilyAsyncNotifier<List<ProjectModelView>, String> {
  Timer? _timer;
  int _polls = 0;
  Duration _interval = _initialInterval;

  @override
  Future<List<ProjectModelView>> build(String projectId) async {
    // AUTO-DISPOSE IS LOAD-BEARING, not an optimization. `ref.onDispose` is
    // what stops the timer, and on a keep-alive family it would never run: the
    // notifier outlives every screen that watched it and keeps polling a route
    // nobody is looking at. That is reachable from the product form, where the
    // user can pick a capture with a regenerate in flight and then switch the
    // product to a photo — the picker unmounts, and without this the poll loop
    // would carry on regardless.
    ref.onDispose(_stop);
    final models =
        await ref.read(liveProjectsRepositoryProvider).listOwnerModels(projectId);
    _scheduleIfPending(models);
    return models;
  }

  /// Whether the poll loop is currently armed — the tests' stop-condition hook.
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
      final models =
          await ref.read(liveProjectsRepositoryProvider).listOwnerModels(arg);
      state = AsyncData(models);
      _interval = _interval * 2 > _maxInterval ? _maxInterval : _interval * 2;
      _scheduleIfPending(models);
    } catch (_) {
      // A transient failure must not blank the list the user is looking at —
      // keep the last good state and try again on the next tick. A permanent
      // failure simply runs out the poll cap.
      _scheduleIfPending(state.valueOrNull ?? const []);
    }
  }

  /// Re-reads the history now and restarts the polling cadence.
  Future<void> refresh() async {
    _polls = 0;
    _interval = _initialInterval;
    final next = await AsyncValue.guard(
      () => ref.read(liveProjectsRepositoryProvider).listOwnerModels(arg),
    );
    state = next;
    _scheduleIfPending(next.valueOrNull ?? const []);
  }

  /// Asks the backend to optimize [modelId] through the OWNER route, then
  /// refreshes so the new pending `OPT` row appears immediately.
  ///
  /// Goes through [LiveProjectsRepository.optimizeOwnerModel] — the same
  /// owner-scoped, rate-limited endpoint the viewer uses. There is deliberately
  /// no path from this screen to the `/admin` optimize route: an owner hitting
  /// it would only ever 403, and routing around the owner endpoint would be a
  /// bypass of the very scoping that makes this surface safe.
  ///
  /// The refresh is the only wiring needed: the existing poll loop already
  /// drives any pending record to done, and the OPT record is pending like any
  /// other. Rethrows [LiveProjectsException] so the caller renders mapped copy.
  Future<void> optimize(String modelId) async {
    await ref
        .read(liveProjectsRepositoryProvider)
        .optimizeOwnerModel(arg, modelId);
    await refresh();
  }
}

/// An OWNER's model history for one of their own projects, with live polling.
/// Auto-disposed with the last widget watching it — see [build] for why that is
/// a correctness property here and not a memory tweak.
final ownerModelHistoryProvider = AsyncNotifierProvider.autoDispose.family<
    OwnerModelHistoryNotifier, List<ProjectModelView>, String>(
  OwnerModelHistoryNotifier.new,
);
