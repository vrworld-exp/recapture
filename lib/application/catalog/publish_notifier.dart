// lib/application/catalog/publish_notifier.dart
//
// The publish run, watched (features 36-39, 52, 53, 68, 69).
//
// THE CLIENT HOLDS NO PUBLISH STATE. Every number on the screen comes from
// `GET /catalog/publish/status`; nothing here advances a counter, guesses a
// state, or remembers what it asked for. Two devices watching one run must show
// the same thing, and the only way to guarantee that is to make the server the
// sole author of it.
//
// WHAT THIS FILE IS REALLY ABOUT IS THE POLL LOOP, and the three ways it can go
// wrong:
//   1. never stopping — a timer that outlives the screen keeps a phone awake
//      and keeps hitting an endpoint nobody is reading. Handled by autoDispose
//      plus an explicit cancel in `onDispose`.
//   2. hammering — publishing ten products against a server that may be waking
//      from a sleeping tier can take minutes, and a fixed one-second poll is
//      hundreds of pointless requests. Handled by [_pollBackoff].
//   3. running in a tab nobody is looking at — a browser throttles background
//      timers unpredictably, so a hidden tab both wastes requests AND cannot be
//      trusted to keep time. Handled by the lifecycle listener, which pauses on
//      hide and does an IMMEDIATE catch-up poll on show.
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show immutable, visibleForTesting;
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_failure.dart';
import '../../data/repositories/catalog_repository.dart';
import '../../domain/catalog/publish_gate.dart';
import '../../domain/catalog/publish_request_result.dart';
import '../../domain/catalog/publish_status.dart';
import 'catalog_notifier.dart';

/// How long to wait before each poll of a run in flight.
///
/// Front-loaded and then flat: the interesting moments are the first few
/// seconds (did the run actually start?) and the transition to terminal, and
/// between them a publish is a slow sequence of uploads where a five-second
/// granularity is invisible to a user watching a progress line. The last value
/// repeats for the rest of the run.
const List<Duration> _pollBackoff = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 3),
  Duration(seconds: 5),
  Duration(seconds: 8),
];

/// What the publish screen renders.
///
/// [status] is the server's truth. Everything else is about the CURRENT
/// interaction — a request in flight, the answer to the last one — and none of
/// it survives a status refresh that contradicts it.
@immutable
class PublishScreenState {
  const PublishScreenState({
    this.status = const AsyncLoading(),
    this.isRequesting = false,
    this.actionFailure,
    this.notice,
    this.suggestedName,
    this.isPollingPaused = false,
  });

  final AsyncValue<PublishStatus> status;

  /// A publish / retry / unpublish POST is in flight. Separate from
  /// `status.isLoading` so pressing Publish does not blank the very list the
  /// user is watching.
  final bool isRequesting;

  /// The last action failed for a reason worth showing. Cleared by the next
  /// action and by a successful refresh.
  final CatalogFailure? actionFailure;

  /// A one-line result of the last action ("Nothing left to retry"). Not an
  /// error — the outcomes that are neither a failure nor a new run.
  final String? notice;

  /// From a 409 CATALOG_NAME_TAKEN: the name Mirage will accept. Offered as a
  /// one-tap rename rather than making the user invent a name that might
  /// collide again.
  final String? suggestedName;

  /// The app is backgrounded or the browser tab is hidden. Surfaced so the
  /// screen can say the numbers are from a moment ago instead of quietly
  /// showing stale ones.
  final bool isPollingPaused;

  PublishStatus? get value => status.valueOrNull;

  /// A run is holding the catalog right now.
  bool get isPublishing => value?.isPublishing ?? false;

  /// Whether the Publish button should do anything. Offline is decided by the
  /// SCREEN (it watches connectivity); this is everything else.
  bool get canPublish =>
      !isRequesting && (value?.canPublish ?? false);

  List<PublishGate> get gates => value?.gates ?? const <PublishGate>[];

  PublishScreenState copyWith({
    AsyncValue<PublishStatus>? status,
    bool? isRequesting,
    Object? actionFailure = _unset,
    Object? notice = _unset,
    Object? suggestedName = _unset,
    bool? isPollingPaused,
  }) =>
      PublishScreenState(
        status: status ?? this.status,
        isRequesting: isRequesting ?? this.isRequesting,
        actionFailure: identical(actionFailure, _unset)
            ? this.actionFailure
            : actionFailure as CatalogFailure?,
        notice: identical(notice, _unset) ? this.notice : notice as String?,
        suggestedName: identical(suggestedName, _unset)
            ? this.suggestedName
            : suggestedName as String?,
        isPollingPaused: isPollingPaused ?? this.isPollingPaused,
      );
}

const Object _unset = Object();

class PublishNotifier extends AutoDisposeNotifier<PublishScreenState> {
  Timer? _poll;
  int _pollAttempt = 0;
  bool _disposed = false;
  AppLifecycleListener? _lifecycle;

  /// Held across a FAILED publish attempt so the retry cannot start a second
  /// run against a catalog the first attempt already claimed.
  ///
  /// A lost 202 is the case this exists for: the run was enqueued, the response
  /// never arrived, and the user presses Publish again. With the same key the
  /// server recognises the request; with a fresh one it would race its own
  /// worker. Cleared only once an attempt gets a definitive answer.
  String? _idempotencyKey;

  CatalogRepository get _repo => ref.read(catalogRepositoryProvider);

  @override
  PublishScreenState build() {
    // Reset first: Riverpod reuses the notifier INSTANCE across a rebuild, so a
    // flag left true from a previous life would make every guard below trip and
    // the screen would sit on its loading state forever.
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _cancelPoll();
      _lifecycle?.dispose();
      _lifecycle = null;
    });

    // Pausing on hide is not only about saving requests: a browser throttles
    // background timers on its own schedule, so a hidden tab's poll loop cannot
    // be trusted to keep time either. On show, catch up IMMEDIATELY rather than
    // waiting out a backoff step the user did not see start.
    _lifecycle = AppLifecycleListener(
      onHide: _pausePolling,
      onPause: _pausePolling,
      onShow: _resumePolling,
      onRestart: _resumePolling,
    );

    scheduleMicrotask(_loadStatus);
    return const PublishScreenState();
  }

  // ── Reading ───────────────────────────────────────────────────────────────

  /// First load and explicit retry. Shows the loading state; there is nothing
  /// behind it yet.
  Future<void> reload() async {
    state = state.copyWith(status: const AsyncLoading());
    await _loadStatus();
  }

  /// Re-reads without blanking the screen — the poll loop, pull-to-refresh, and
  /// the return from a screen where the user fixed a gate.
  Future<void> refresh() => _loadStatus();

  Future<void> _loadStatus() async {
    try {
      final status = await _repo.publishStatus();
      if (_disposed) return;
      state = state.copyWith(status: AsyncData(status), actionFailure: null);
      _syncPollingTo(status);
      // The catalog header's own chips (Published / Draft changes / Publishing)
      // read the catalog notifier, not this one. Keeping them in step here is
      // what stops the shell claiming a publish is still running after this
      // screen has watched it finish.
      _refreshCatalog();
    } on CatalogFailure catch (failure, stack) {
      if (_disposed) return;
      // A failed POLL must not destroy a run the user is watching — only a
      // failure with nothing behind it takes the screen.
      if (state.value == null) {
        state = state.copyWith(status: AsyncError(failure, stack));
      } else {
        state = state.copyWith(actionFailure: failure);
        // Keep polling: a single dropped request during a multi-minute run is
        // ordinary, and giving up would freeze the progress line for good.
        _scheduleNextPoll();
      }
    }
  }

  // ── Polling ───────────────────────────────────────────────────────────────

  /// Starts, continues or stops the loop to match [status].
  void _syncPollingTo(PublishStatus status) {
    final inFlight = status.isPublishing || (status.run?.state.isInFlight ?? false);
    if (!inFlight) {
      // TERMINAL. Stop, and reset the backoff so the next run starts responsive
      // again instead of inheriting the last one's eight-second cadence.
      _cancelPoll();
      _pollAttempt = 0;
      return;
    }
    _scheduleNextPoll();
  }

  void _scheduleNextPoll() {
    _poll?.cancel();
    if (_disposed || state.isPollingPaused) return;
    final delay = _pollBackoff[min(_pollAttempt, _pollBackoff.length - 1)];
    _pollAttempt++;
    _poll = Timer(delay, () {
      if (_disposed) return;
      _loadStatus();
    });
  }

  void _cancelPoll() {
    _poll?.cancel();
    _poll = null;
  }

  void _pausePolling() {
    if (_disposed || state.isPollingPaused) return;
    _cancelPoll();
    state = state.copyWith(isPollingPaused: true);
  }

  void _resumePolling() {
    if (_disposed || !state.isPollingPaused) return;
    state = state.copyWith(isPollingPaused: false);
    // Catch up now, not after a backoff step: the run may well have finished
    // while the tab was hidden, and the first thing back on screen should be
    // the truth rather than the last frame from before.
    _pollAttempt = 0;
    unawaited(_loadStatus());
  }

  /// Test seam for the lifecycle transitions — a widget test cannot make a
  /// browser tab hide, and the real signal arrives from the engine.
  @visibleForTesting
  void debugSetHidden(bool hidden) => hidden ? _pausePolling() : _resumePolling();

  // ── Acting ────────────────────────────────────────────────────────────────

  /// Publish (feature 36).
  Future<void> publish() =>
      _act(() => _repo.publish(idempotencyKey: _keyForAttempt()));

  /// Retry only the failed rows (feature 53).
  Future<void> retryFailed() => _act(_repo.retryFailedPublish);

  Future<void> _act(Future<PublishRequestResult> Function() request) async {
    if (state.isRequesting) return;
    state = state.copyWith(
      isRequesting: true,
      actionFailure: null,
      notice: null,
      suggestedName: null,
    );

    try {
      final result = await request();
      if (_disposed) return;

      switch (result) {
        case PublishQueued():
        case PublishAlreadyRunning():
          // Both mean the same thing to this screen: a run is going, watch it.
          // A second press answering 409 is NOT an error — it is the run the
          // user asked for, already under way.
          _idempotencyKey = null;
          state = state.copyWith(isRequesting: false);
          _pollAttempt = 0;
          await _loadStatus();

        case PublishBlocked():
          // Re-read rather than adopting the 422's own gate list: the status
          // endpoint evaluates the identical set, and taking it from one place
          // is what stops the checklist and the button disagreeing.
          _idempotencyKey = null;
          state = state.copyWith(
            isRequesting: false,
            notice: 'Fix the items below, then publish again.',
          );
          await _loadStatus();

        case PublishNameTaken(:final suggestedName):
          _idempotencyKey = null;
          state = state.copyWith(
            isRequesting: false,
            suggestedName: suggestedName,
          );

        case PublishNothingToRetry():
          _idempotencyKey = null;
          state = state.copyWith(
            isRequesting: false,
            notice: 'Nothing left to retry — every product is up to date.',
          );
          await _loadStatus();
      }
    } on CatalogFailure catch (failure) {
      if (_disposed) return;
      // The key is KEPT: this attempt may well have reached the server and lost
      // its response, and the next press must be the same request, not a
      // second one.
      state = state.copyWith(isRequesting: false, actionFailure: failure);
    }
  }

  /// Renames the catalog to the server's suggestion and publishes again — the
  /// one-tap way out of a Mirage name collision.
  Future<void> renameAndPublish(String name) async {
    if (state.isRequesting) return;
    state = state.copyWith(isRequesting: true, actionFailure: null);
    try {
      await ref.read(catalogProvider.notifier).updateMetadata(name: name);
      if (_disposed) return;
      state = state.copyWith(isRequesting: false, suggestedName: null);
      await publish();
    } on CatalogFailure catch (failure) {
      if (_disposed) return;
      state = state.copyWith(isRequesting: false, actionFailure: failure);
    }
  }

  /// Takes the catalog offline (feature 39).
  Future<void> unpublish() async {
    if (state.isRequesting) return;
    state = state.copyWith(
      isRequesting: true,
      actionFailure: null,
      notice: null,
    );

    try {
      final result = await _repo.unpublish();
      if (_disposed) return;

      state = state.copyWith(
        isRequesting: false,
        notice: switch (result) {
          UnpublishQueued() => 'Taking your catalog offline…',
          UnpublishAlreadyRunning() =>
            'Finishing the run that is already going, then try again.',
          UnpublishNotPublished() => 'This catalog was not live.',
        },
      );
      _pollAttempt = 0;
      await _loadStatus();
    } on CatalogFailure catch (failure) {
      if (_disposed) return;
      state = state.copyWith(isRequesting: false, actionFailure: failure);
    }
  }

  void dismissNotice() =>
      state = state.copyWith(notice: null, actionFailure: null);

  /// The key for the attempt about to be made — a fresh one, unless a previous
  /// attempt failed without a definitive answer and left one behind.
  String _keyForAttempt() =>
      _idempotencyKey ??= 'pub-${DateTime.now().microsecondsSinceEpoch}-'
          '${Random().nextInt(1 << 32).toRadixString(16)}';

  /// Best-effort: this screen has just learned something the catalog shell's
  /// header shows too. A failed refresh must never look like a failed publish.
  void _refreshCatalog() {
    unawaited(ref.read(catalogProvider.notifier).refresh().catchError((_) {}));
  }
}

/// The publish screen's state.
///
/// autoDispose is LOAD-BEARING, not tidiness: it is what guarantees the poll
/// loop dies with the screen. A kept-alive provider would keep timing, keep
/// requesting and keep a phone's radio busy for a run nobody is watching.
final publishProvider =
    AutoDisposeNotifierProvider<PublishNotifier, PublishScreenState>(
  PublishNotifier.new,
);
