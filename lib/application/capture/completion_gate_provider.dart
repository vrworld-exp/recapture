// lib/application/capture/completion_gate_provider.dart
//
// The reactive wiring around the pure [SummaryGate] — the ONE evaluator every
// consumer (router gate + Summary screen) reads, so "guided capture is done"
// lives in exactly one place. It iterates the flow variant's ACTIVE level list
// (captureFlowVariantProvider.levels — never a hardcoded 3), reads each level's LIVE accepted
// frame count from the same ledger source the review grids use
// (reviewGridItemsProvider), and applies the config-driven per-level thresholds
// (CaptureConfig.completionThresholds). autoDispose so it recomputes against
// current data on each read/watch — never a stale snapshot.
//
// READ-ONLY over capture/review data; the gate mutates nothing. The unlock /
// blocked analytics live in [SummaryGateAnalyticsNotifier], which dedups the
// milestone to the locked→unlocked transition.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/capture/completion_gate.dart';
import '../../utils/analytics.dart';
import '../config/config_notifier.dart';
import 'analytics/capture_level_events.dart';
import 'capture_flow_variant_provider.dart';
import 'capture_mode_provider.dart';
import 'review_grid_items_provider.dart';
import '../../utils/platform_name.dart';

/// The live final completion gate. Watch it for `isUnlocked` / per-level status;
/// it reflects the current ledger + config + flow variant every time it is read
/// (a 2-ring session unlocks after Level B — Level C is never demanded).
final completionGateProvider = Provider.autoDispose<SummaryGate>((ref) {
  final thresholds =
      ref.watch(captureConfigProvider.select((c) => c.completionThresholds));
  final variant = ref.watch(captureFlowVariantProvider);
  final mode = ref.watch(captureModeProvider);
  return evaluateSummaryGate([
    for (final level in activeCaptureLevels(variant, mode))
      LevelCompletionStatus(
        levelCode: level.code,
        // Live accepted frames — the SAME source the review grids + summary read.
        acceptedCount: ref
            .watch(reviewGridItemsProvider(pitchBandIdForLevel(level)))
            .length,
        minAcceptedFrames: thresholds.minAcceptedFramesFor(level.code),
      ),
  ]);
});

/// Dedups + emits the gate analytics. Kept as a Notifier so the locked→unlocked
/// latch survives across rebuilds: the unlock milestone fires once per transition
/// (the latch resets whenever the gate is observed LOCKED, so a re-lock then
/// re-unlock fires again — true edge semantics), while a blocked Summary-access
/// attempt always reports which levels remain.
final summaryGateAnalyticsProvider =
    NotifierProvider<SummaryGateAnalyticsNotifier, void>(
  SummaryGateAnalyticsNotifier.new,
);

class SummaryGateAnalyticsNotifier extends Notifier<void> {
  /// Whether the current unlocked episode already emitted its milestone.
  bool _unlockLogged = false;

  @override
  void build() {}

  static String get _deviceType => appPlatformName;

  /// Reconciles the latch with the observed [gate] and emits BOTH
  /// `guided_capture_summary_unlocked` AND the funnel-end
  /// `capture_session_complete` exactly once on each locked→unlocked transition
  /// (the same latch gates both). A locked observation re-arms the latch.
  /// Idempotent while the gate stays unlocked (no per-evaluation spam).
  void syncUnlockMilestone(
    SummaryGate gate, {
    required String sessionId,
  }) {
    if (!gate.isUnlocked) {
      _unlockLogged = false; // re-arm: the next unlock is a fresh transition
      return;
    }
    if (_unlockLogged) return;
    _unlockLogged = true;
    Analytics.logEvent(AnalyticsEvents.guidedCaptureSummaryUnlocked, {
      'session_id': sessionId,
      'phase': 'guided_capture',
      'levels_total': gate.levelsTotal,
      'device_type': _deviceType,
    });
    // The funnel-end event: the whole guided session (every level) is complete.
    // Same transition + same latch ⇒ exactly once per session; it can only run
    // here, so a double-confirm / back-and-reconfirm / rebuild cannot duplicate it.
    _logSessionComplete(gate, sessionId: sessionId);
  }

  /// Emits `capture_session_complete` with totals derived ENTIRELY from the gate
  /// (no new measurement): per-level accepted frame counts → `total_frame_count`
  /// (their sum) + a flat `level_<code>_frame_count` per configured level (built by
  /// iterating the gate's levels, so it stays config-driven, not a hardcoded A/B/C).
  ///
  /// `session_duration_ms` is intentionally OMITTED: the funnel has no whole-session
  /// start timestamp (the analytics session restarts per level), and per the brief's
  /// edge rule a missing duration is omitted rather than sent as a misleading
  /// per-level value.
  void _logSessionComplete(SummaryGate gate, {required String sessionId}) {
    var total = 0;
    final perLevel = <String, Object?>{};
    for (final l in gate.levels) {
      total += l.acceptedCount;
      perLevel['level_${l.levelCode.toLowerCase()}_frame_count'] =
          l.acceptedCount;
    }
    Analytics.logEvent(AnalyticsEvents.captureSessionComplete, {
      'session_id': sessionId,
      'phase': 'guided_capture',
      'levels_total': gate.levelsTotal,
      'levels_completed': gate.levelsComplete,
      'total_frame_count': total,
      ...perLevel,
      'device_type': _deviceType,
    });
  }

  /// Emits `guided_capture_summary_blocked` for a blocked Summary-access attempt,
  /// reporting the still-incomplete levels. Also re-arms the unlock latch (the
  /// gate is locked at this point).
  void logBlockedAttempt(
    SummaryGate gate, {
    required String sessionId,
  }) {
    _unlockLogged = false;
    Analytics.logEvent(AnalyticsEvents.guidedCaptureSummaryBlocked, {
      'session_id': sessionId,
      'phase': 'guided_capture',
      'incomplete_levels': gate.incompleteLevelsLabel,
      'device_type': _deviceType,
    });
  }
}
