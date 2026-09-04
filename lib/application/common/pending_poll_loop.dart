// lib/application/common/pending_poll_loop.dart
import 'dart:async';

/// The app's ONE polling cadence for "something is generating, watch it".
///
/// Extracted from `model_generation_notifier.dart`, which proved these exact
/// numbers in production against the same backend. Two notifiers now share it
/// rather than carrying a copy each: two copies of a backoff drift, and the
/// day someone tunes one of them the other keeps the old behaviour with nothing
/// to say so.
///
/// The properties every caller inherits, and why each is not optional:
///
///   • BACKOFF 3s → 10s. Short first, so a fast generation feels instant.
///     Capped at 10s and no higher because the surfaces show live progress, and
///     a bar that moves every 20s reads as frozen.
///   • A HARD POLL CAP. At this cadence the cap covers well past the backend's
///     own generation timeout, after which the worker gives up and the record
///     turns FAILED. A still-pending record past the cap means something is
///     wrong, and polling forever would not fix it — it would just keep a
///     rate-limited endpoint busy on behalf of a screen nobody is reading.
///   • TEARDOWN. The owner wires [stop] into `ref.onDispose`, so the loop dies
///     with the screen instead of polling for a route that is gone.
///   • LAST-GOOD-STATE ON FAILURE. A dropped request must not blank a grid a
///     rep is reading in a restaurant with bad wifi. A transient failure
///     reschedules against the state already on screen; a permanent one simply
///     runs out the cap.
class PendingPollLoop {
  PendingPollLoop({
    required Future<bool> Function() poll,
    Duration initialInterval = kPendingPollInitialInterval,
    Duration maxInterval = kPendingPollMaxInterval,
    int maxPolls = kPendingPollMaxPolls,
  })  : _poll = poll,
        _initialInterval = initialInterval,
        _maxInterval = maxInterval,
        _maxPolls = maxPolls,
        _interval = initialInterval;

  /// Runs one poll and reports whether anything is STILL pending.
  ///
  /// Returning false stops the loop — the caller decides what "pending" means,
  /// which is the only part that differs between surfaces. It must not throw:
  /// swallow transient failures and answer from the last known state, which is
  /// what keeps the screen populated.
  final Future<bool> Function() _poll;

  final Duration _initialInterval;
  final Duration _maxInterval;
  final int _maxPolls;

  Timer? _timer;
  int _polls = 0;
  Duration _interval;

  /// Whether a tick is scheduled. Exposed for tests and for a screen that wants
  /// to show "watching for updates".
  bool get isRunning => _timer != null;

  /// Polls performed so far — the cap's counter.
  int get polls => _polls;

  /// Schedules the next tick when [isPending], stops otherwise.
  ///
  /// Called once with the value the owner already has (so a screen that opens
  /// on nothing pending never polls at all), and again after every tick.
  void scheduleIfPending({required bool isPending}) {
    stop();
    if (!isPending) return;
    if (_polls >= _maxPolls) return;
    _timer = Timer(_interval, _tick);
  }

  /// Cancels any scheduled tick. Idempotent, and safe to call after disposal.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Restarts the cadence from the beginning — after an action that creates
  /// something new to wait for, so the first result appears quickly rather than
  /// at whatever interval the previous wait had backed off to.
  void reset() {
    _polls = 0;
    _interval = _initialInterval;
  }

  Future<void> _tick() async {
    _polls++;
    final stillPending = await _poll();
    // Ease off only while we keep waiting.
    final doubled = _interval * 2;
    _interval = doubled > _maxInterval ? _maxInterval : doubled;
    scheduleIfPending(isPending: stillPending);
  }
}

/// Starts short — a fast generation should feel instant.
const Duration kPendingPollInitialInterval = Duration(seconds: 3);

/// The ceiling. Not higher: these surfaces render live progress.
const Duration kPendingPollMaxInterval = Duration(seconds: 10);

/// Hard stop, well past the backend's own generation timeout.
const int kPendingPollMaxPolls = 120;
