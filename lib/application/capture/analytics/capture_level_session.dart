// lib/application/capture/analytics/capture_level_session.dart
//
// The in-memory analytics context for the current capture-level session — the
// glue that lets the three lifecycle events (fired from DIFFERENT screens) share
// one `session_id` and a `started_at`, so the funnel can be stitched and the
// completed event can report `duration_seconds`.
//
// It is app-scoped (a normal provider, not persisted): the capture screen starts
// a session when guided capture begins; the completion screen reads it to emit
// `capture_level_completed` with the same session_id + the elapsed duration. A
// fresh capture entry (including resuming a draft — see the task's funnel policy)
// starts a NEW session, so each guided run is a distinct funnel. If the app is
// killed mid-flow the link is lost (the completed event then carries a synthesized
// empty session_id + 0 duration), which is an accepted edge, not a crash.
//
// The session id is opaque (time + random hex) — NO PII, no device identifiers.
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'capture_level_events.dart';

/// The analytics context for one capture-level session.
class CaptureLevelSession {
  const CaptureLevelSession({
    required this.level,
    required this.projectId,
    required this.sessionId,
    required this.startedAt,
  });

  final CaptureLevel level;
  final String projectId;
  final String sessionId;
  final DateTime startedAt;

  /// Whole seconds from [startedAt] to [now], clamped `>= 0` (a clock skew or a
  /// stale session can't produce a negative duration).
  int durationSecondsUntil(DateTime now) {
    final s = now.difference(startedAt).inSeconds;
    return s < 0 ? 0 : s;
  }
}

/// The result of claiming a completion: whether to emit `capture_level_completed`
/// and the [session] (null when no session was observed — a restart/deep-link).
class CompletionClaim {
  const CompletionClaim({required this.shouldEmit, required this.session});

  final bool shouldEmit;
  final CaptureLevelSession? session;
}

/// The current capture-level analytics session, or null before one starts / after
/// it is cleared. Watched by the completion screen; mutated via the notifier.
final captureLevelSessionProvider =
    NotifierProvider<CaptureLevelSessionNotifier, CaptureLevelSession?>(
  CaptureLevelSessionNotifier.new,
);

class CaptureLevelSessionNotifier extends Notifier<CaptureLevelSession?> {
  @override
  CaptureLevelSession? build() => null;

  /// Latches `capture_level_completed` to once per session: set when a completion
  /// is claimed, reset by [start] (a new session can complete again).
  bool _completionClaimed = false;

  /// Monotonic capture-attempt counter, SHARED by manual + auto triggers so the
  /// funnel has one coherent sequence per session. Reset by [start].
  int _attempts = 0;

  /// The next attempt number (1-based) for a capture trigger. Works even before a
  /// session is started (defensive), so a trigger never lacks a number.
  int nextAttempt() => ++_attempts;

  /// Begins a NEW session (fresh opaque [sessionId] + [startedAt]) and returns
  /// it. [now]/[sessionId] are injectable for deterministic tests.
  CaptureLevelSession start({
    required CaptureLevel level,
    required String projectId,
    DateTime? now,
    String? sessionId,
  }) {
    final at = now ?? DateTime.now();
    final session = CaptureLevelSession(
      level: level,
      projectId: projectId,
      sessionId: sessionId ?? _generateSessionId(at),
      startedAt: at,
    );
    _completionClaimed = false; // a new session can complete again
    _attempts = 0; // a new session restarts the attempt sequence
    state = session;
    return session;
  }

  /// Claims the current session's completion exactly once. Returns
  /// `shouldEmit: true` (with the session, or null when none was observed) on the
  /// FIRST claim per session, and `shouldEmit: false` on any later claim — so a
  /// re-visit of the completion screen for the same session does NOT double-emit
  /// `capture_level_completed` (the latch). Does not mutate [state].
  CompletionClaim claimCompletion() {
    if (_completionClaimed) {
      return const CompletionClaim(shouldEmit: false, session: null);
    }
    _completionClaimed = true;
    return CompletionClaim(shouldEmit: true, session: state);
  }

  /// Returns the current session if it is for [level]; otherwise starts a fresh
  /// one. Used by a retake re-entry so it links to the in-progress session rather
  /// than minting an unrelated id.
  CaptureLevelSession ensure({
    required CaptureLevel level,
    required String projectId,
    DateTime? now,
    String? sessionId,
  }) {
    final current = state;
    if (current != null && current.level == level) return current;
    return start(
        level: level, projectId: projectId, now: now, sessionId: sessionId);
  }

  /// Drops the session (e.g. after the level completes).
  void clear() {
    if (state != null) state = null;
  }

  /// Opaque, non-PII id: microsecond timestamp + 32 random bits, hex-encoded.
  static String _generateSessionId(DateTime at) {
    final micros = at.microsecondsSinceEpoch.toRadixString(16);
    final rand = Random().nextInt(0x7fffffff).toRadixString(16).padLeft(8, '0');
    return '$micros-$rand';
  }
}
