// lib/application/rep/rep_publish_notifier.dart
//
// "Put this menu online", from the rep's side of the table.
//
// A SEPARATE notifier from `repCatalogProductsProvider` on purpose. That one
// owns the pending-model poll loop — the most delicate thing on the rep detail
// screen — and threading a publish action through it would mean touching the
// loop's lifecycle to add a flag it has no use for. This holds the publish
// action, the run watch, and one follow-up.
//
// ── THE RACE THIS FILE EXISTS TO GET RIGHT ─────────────────────────────────
//
// A publish takes about a minute. A rep does not stand still for it: they fix a
// price, swap a photo, or rename a dish while the run is going. That edit is
// NOT in the run — the run planned from a snapshot taken when Publish was
// pressed (see publishSnapshot.ts) — so the menu that goes live is the one from
// a minute ago, and the fix the rep just made is not on it.
//
// Nothing told them. The screen said "Publishing…", the button was disabled,
// and when the run finished the page went green. The rep left believing the
// correction was live. That is the failure this file and [_PublishBar] split
// between them: the bar SAYS the running publish is stale, and this notifier
// makes pressing Publish actually deliver.
//
// WE CANNOT CANCEL THE RUNNING PUBLISH, AND MUST NOT WANT TO. The server holds
// a lock (`activePublishRunId`) because Mirage's writes are not idempotent and
// not atomic; killing a run mid-flight would leave the customer page half
// updated, which is worse than the stale page it replaced. There is no cancel
// endpoint for that reason. So "publish my latest changes" is not "interrupt
// the run" — it is "run again, immediately after this one", and that is what
// [publish] arranges when the server answers 409.
//
// A 409 IS NO LONGER UNCONDITIONALLY A SUCCESS. It used to be, and the reasoning
// was sound for the case it was written for: a 3D dish finishes generating, the
// server starts a run on its own, the rep presses Publish, and telling them
// "409, already running" would report our concurrency control as their problem
// when the menu really is going live. That reasoning holds ONLY while the
// running publish carries what the rep is asking to publish. When it does not —
// `hasChangesSincePublishStarted` — the same confirmation is a lie, and the rep
// walks away on it. So the 409 branch now asks the catalog which case it is in.
import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/catalog_failure.dart';
import '../../data/repositories/rep_repository.dart';
import '../../domain/catalog/publish_gate.dart';
import '../../domain/entities/catalog.dart';
import '../common/pending_poll_loop.dart';
import 'rep_restaurant_notifier.dart';

@immutable
class RepPublishState {
  const RepPublishState({
    this.publishing = false,
    this.queuedBehindRun = false,
    this.outcome,
    this.gates = const [],
    this.failure,
    this.notice,
  });

  /// A publish request from THIS device is in flight. Not the same as the
  /// catalog's `isPublishing`, which is true for any run from any source.
  final bool publishing;

  /// The rep asked to publish while a run they cannot join held the lock, and
  /// we have taken responsibility for republishing the moment it clears.
  ///
  /// Only ever set when the running publish is known NOT to carry the rep's
  /// latest edits. A 409 on a run that DOES carry them stays what it always
  /// was: the outcome the rep wanted, reported as success.
  final bool queuedBehindRun;

  /// Set once a publish has been asked for and answered.
  final RepPublishOutcome? outcome;

  /// Why the menu cannot go live yet. Every failing gate, not the first.
  final List<PublishGate> gates;

  final CatalogFailure? failure;
  final String? notice;

  bool get isBlocked => gates.isNotEmpty;

  RepPublishState copyWith({
    bool? publishing,
    bool? queuedBehindRun,
    Object? outcome = _unset,
    List<PublishGate>? gates,
    Object? failure = _unset,
    Object? notice = _unset,
  }) =>
      RepPublishState(
        publishing: publishing ?? this.publishing,
        queuedBehindRun: queuedBehindRun ?? this.queuedBehindRun,
        outcome: identical(outcome, _unset)
            ? this.outcome
            : outcome as RepPublishOutcome?,
        gates: gates ?? this.gates,
        failure: identical(failure, _unset)
            ? this.failure
            : failure as CatalogFailure?,
        notice: identical(notice, _unset) ? this.notice : notice as String?,
      );
}

const Object _unset = Object();

class RepPublishNotifier
    extends AutoDisposeFamilyNotifier<RepPublishState, String> {
  bool _disposed = false;

  /// Watches the in-flight run to its end. The SHARED cadence (see
  /// [PendingPollLoop]) rather than a second one, and lazily created: a screen
  /// opened on a catalog nobody is publishing never starts a timer.
  PendingPollLoop? _runWatch;

  @override
  RepPublishState build(String catalogId) {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _runWatch?.stop();
    });
    return const RepPublishState();
  }

  /// Asks for the menu to go live.
  ///
  /// Three answers, and the third is the one this method exists for:
  ///
  ///   • QUEUED — a run started. Ordinary success.
  ///   • 409, and the running publish CARRIES the draft — success, reported the
  ///     same as a fresh run. The rep's question is "is this menu going up" and
  ///     the answer is yes; our concurrency control is not their problem.
  ///   • 409, and the running publish DOES NOT carry the rep's latest edits —
  ///     NOT a success, however much it looks like one. The menu going live is
  ///     the wrong menu. We take responsibility instead: [queuedBehindRun], and
  ///     a republish the moment the lock clears.
  Future<void> publish() async {
    if (state.publishing) return;
    state = state.copyWith(
      publishing: true,
      failure: null,
      notice: null,
      gates: const [],
    );

    try {
      final result = await ref.read(repRepositoryProvider).publish(arg);
      if (_disposed) return;

      if (result.outcome == RepPublishOutcome.alreadyRunning) {
        await _handleAlreadyRunning();
        return;
      }

      state = state.copyWith(
        publishing: false,
        queuedBehindRun: false,
        outcome: result.outcome,
        notice: 'The menu is going live. Scan the standee in a minute.',
      );
      // Our own run now holds the catalog. Watch it out so the screen stops
      // saying "Publishing…" on its own rather than waiting for a pull-down.
      _startRunWatch();
    } on RepPublishBlocked catch (blocked) {
      if (_disposed) return;
      // The gate list is the useful half — it names what to fix while the rep
      // is still standing in the restaurant and can fix it.
      //
      // A blocked republish also ENDS the follow-up: the menu cannot go live
      // until a human fixes something, and a loop that keeps retrying a publish
      // the server keeps refusing is a loop that never ends.
      state = state.copyWith(
        publishing: false,
        queuedBehindRun: false,
        gates: blocked.gates,
        failure: blocked,
      );
      _runWatch?.stop();
    } on CatalogFailure catch (failure) {
      if (_disposed) return;
      state = state.copyWith(
        publishing: false,
        queuedBehindRun: false,
        failure: failure,
      );
      _runWatch?.stop();
    }
  }

  /// The 409 branch: decide whether the run already in flight is the one the
  /// rep is asking for.
  Future<void> _handleAlreadyRunning() async {
    // Ask the SERVER, not the widget that called us. The bar's copy of the
    // catalog can be a poll old, and being wrong here in the optimistic
    // direction is exactly the bug this whole change is about.
    //
    // ANY throw means "cannot tell", not just a mapped CatalogFailure: this is
    // a read taken purely to choose a sentence, and letting it decide whether
    // publish() itself succeeds would make a publish that WORKED look failed.
    Catalog? catalog;
    try {
      catalog = await ref.read(repRepositoryProvider).catalog(arg);
    } catch (_) {
      catalog = null;
    }
    if (_disposed) return;

    if (catalog != null && !catalog.hasChangesSincePublishStarted) {
      // The running publish carries the draft. Unchanged from the behaviour
      // this branch has always had, and for the unchanged reason: the rep
      // asked whether the menu is going up, and it is.
      state = state.copyWith(
        publishing: false,
        queuedBehindRun: false,
        outcome: RepPublishOutcome.alreadyRunning,
        notice: 'The menu is going live. Scan the standee in a minute.',
      );
      _startRunWatch();
      return;
    }

    // Either the run is known stale, or the read failed and we cannot tell.
    // Both queue a republish — the follow-up re-checks before it fires, so a
    // wrong guess here costs nothing — but they are NOT told the same thing.
    // Claiming "without your latest changes" on a read we could not make would
    // be inventing the very fact we failed to establish.
    state = state.copyWith(
      publishing: false,
      queuedBehindRun: true,
      outcome: RepPublishOutcome.alreadyRunning,
      // Neither sentence promises the rep can leave. This notifier dies with
      // the screen, so a rep who walks away leaves the republish undone —
      // recoverable, because the bar says so the moment they come back, but
      // not something to promise away here.
      notice: catalog == null
          ? 'A publish is already running. Yours follows as soon as it '
              'finishes — keep this screen open.'
          : 'A publish is already running without your latest changes. '
              'They go up as soon as it finishes — keep this screen open.',
    );
    _startRunWatch();
  }

  /// Follows the in-flight run until the lock clears.
  ///
  /// Doing this at all is what makes the publish bar self-correcting. Without
  /// it the screen holds whatever it read when it opened: a finished run still
  /// reads as "Publishing…", a failed one never reappears as work to do, and a
  /// rep is left pulling down to refresh a screen that never told them to.
  void _startRunWatch() {
    (_runWatch ??= PendingPollLoop(poll: _watchRun))
      ..reset()
      ..scheduleIfPending(isPending: true);
  }

  /// One tick. Returns whether the run is still worth watching.
  ///
  /// MUST NOT THROW — [PendingPollLoop] has no error path, and a rep on
  /// restaurant wifi drops requests. A failed read reschedules against the
  /// state already on screen rather than blanking it.
  Future<bool> _watchRun() async {
    ref.invalidate(repCatalogDocumentProvider(arg));

    final Catalog catalog;
    try {
      catalog = await ref.read(repCatalogDocumentProvider(arg).future);
    } catch (_) {
      // Transient. Keep watching; the cap ends a permanently broken read.
      return !_disposed;
    }
    if (_disposed) return false;

    if (catalog.isPublishing) return true;

    // The lock cleared. Either we owe a republish, or the watch is done and
    // the freshly-invalidated document has already moved the bar.
    if (!state.queuedBehindRun) return false;

    state = state.copyWith(queuedBehindRun: false);

    // RE-CHECK BEFORE REPUBLISHING. The queue may have been taken out on a
    // guess — a 409 whose catalog read failed — and the run we waited behind
    // may have carried everything after all. Publishing anyway would spend a
    // whole run to change nothing, and tell the rep a second time that their
    // menu is going live.
    if (!catalog.hasUnpublishedChanges) {
      state = state.copyWith(
        notice: 'Everything is live, including your latest changes.',
      );
      return false;
    }

    // Straight back through the front door: publish() re-runs every gate, and
    // a republish that skipped them would be a second, unguarded publish path.
    await publish();
    return false;
  }

  /// Watches a run this notifier did not start — one the catalog document
  /// reports, from a finished 3D model or from the owner's own device.
  ///
  /// Idempotent and cheap to call on every document change: it starts nothing
  /// when nothing is running, and will not restart a watch already ticking.
  void watchRunIfPublishing({required bool isPublishing}) {
    if (_disposed) return;
    if (!isPublishing) {
      _runWatch?.stop();
      return;
    }
    if (_runWatch?.isRunning ?? false) return;
    _startRunWatch();
  }

  /// Drops a queued republish the rep no longer wants.
  ///
  /// The bar offers this the moment [queuedBehindRun] is set, because a rep who
  /// queued a republish by reflex and then decided the visit is over should not
  /// have to keep a screen open to stop a publish they do not want.
  void cancelQueuedRepublish() {
    if (_disposed || !state.queuedBehindRun) return;
    state = state.copyWith(
      queuedBehindRun: false,
      notice: 'Your changes stay in the draft. Press Publish when you want '
          'them live.',
    );
  }

  void dismissNotice() =>
      state = state.copyWith(notice: null, failure: null, gates: const []);
}

/// Publish state for one delegated catalog.
final repPublishProvider = AutoDisposeNotifierProviderFamily<RepPublishNotifier,
    RepPublishState, String>(
  RepPublishNotifier.new,
);
