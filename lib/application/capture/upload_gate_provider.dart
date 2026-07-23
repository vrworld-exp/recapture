// lib/application/capture/upload_gate_provider.dart
//
// The reactive wiring around the pure [UploadGate] — the ONE hard-upload-floor
// evaluator the Summary/upload control reads. It iterates the flow variant's
// ACTIVE level list (captureFlowVariantProvider.levels — never a hardcoded 3,
// so a 2-ring session is never blocked on a missing Level C), reads each level's LIVE
// accepted-shot count from the SAME ledger source the review grids + completion
// gate use (reviewGridItemsProvider — no duplicated counting), and applies BOTH
// per-level floors: the config-driven absolute shot minimum
// (CaptureConfig.uploadMinShots) AND the ring-coverage completion floor
// (minCoveragePct of the variant's segment count — the same floor the backend's
// POST /jobs count range enforces, so a bundle the server would 400 can never
// leave the Summary screen). autoDispose so it recomputes against current data
// on each read/watch — the control enables/disables reactively as accepted
// shots change.
//
// READ-ONLY over capture/review data; the gate mutates nothing. The blocked /
// passed analytics live in [UploadGateAnalyticsNotifier], which dedups the passed
// milestone to the not-eligible→eligible transition.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/capture/level_completion.dart';
import '../../domain/capture/upload_gate.dart';
import '../../domain/entities/capture_config.dart';
import '../../utils/analytics.dart';
import '../config/config_notifier.dart';
import 'analytics/capture_level_events.dart';
import 'capture_flow_variant_provider.dart';
import 'capture_mode_provider.dart';
import 'review_grid_items_provider.dart';

/// The live hard upload gate. Watch it for `eligible` / `shortLevels`; it reflects
/// the current ledger + config every time it is read. Fail-safe: with no levels it
/// reports NOT eligible (upload disabled), never enabling on unknown state.
final uploadGateProvider = Provider.autoDispose<UploadGate>((ref) {
  final config = ref.watch(captureConfigProvider);
  final variant = ref.watch(captureFlowVariantProvider);
  final mode = ref.watch(captureModeProvider);
  return evaluateUploadGate([
    for (final level in activeCaptureLevels(variant, mode))
      () {
        final bandId = pitchBandIdForLevel(level);
        // Live accepted shots — the SAME source the review grids + completion
        // gate read (no duplicated shot-counting).
        final items = ref.watch(reviewGridItemsProvider(bandId));
        final segments = effectiveSegmentsFor(config, variant, bandId, mode: mode);
        // Distinct in-range segments among the accepted shots — the ledger
        // analogue of SegmentCoverage.filledCount (same rule as the upload
        // flow's progressionFromLedger snapshot).
        final filled = items
            .map((i) => i.ringIndex)
            .whereType<int>()
            .where((i) => i >= 0 && i < segments)
            .toSet()
            .length;
        return UploadLevelStatus(
          levelCode: level.code,
          accepted: items.length,
          required: config.uploadMinShots.minShotsFor(level.code),
          filled: filled,
          requiredFilled:
              requiredSegmentsFor(config.thresholds.minCoveragePct, segments),
        );
      }(),
  ]);
});

/// Dedups + emits the upload-gate analytics. Kept as a Notifier so the
/// not-eligible→eligible latch survives across rebuilds: `upload_gate_passed`
/// fires once per transition (the latch resets whenever the gate is observed
/// NOT eligible, so a re-block then re-pass fires again — true edge semantics),
/// while `upload_gate_blocked` is emitted by the screen (on first disabled view +
/// on a blocked action attempt).
final uploadGateAnalyticsProvider =
    NotifierProvider<UploadGateAnalyticsNotifier, void>(
  UploadGateAnalyticsNotifier.new,
);

class UploadGateAnalyticsNotifier extends Notifier<void> {
  /// Whether the current eligible episode already emitted its passed milestone.
  bool _passedLogged = false;

  @override
  void build() {}

  static String get _deviceType =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  /// Reconciles the latch with the observed [gate] and emits `upload_gate_passed`
  /// exactly once on each not-eligible→eligible transition. A not-eligible
  /// observation re-arms the latch. Idempotent while the gate stays eligible.
  void syncPassedMilestone(UploadGate gate, {required String sessionId}) {
    if (!gate.eligible) {
      _passedLogged = false; // re-arm: the next pass is a fresh transition
      return;
    }
    if (_passedLogged) return;
    _passedLogged = true;
    Analytics.logEvent(AnalyticsEvents.uploadGatePassed, {
      'session_id': sessionId,
      'phase': 'upload',
      'device_type': _deviceType,
    });
  }

  /// Emits `upload_gate_blocked` for a blocked upload — either the control was
  /// shown disabled (first view) or an upload attempt was refused. Reports the
  /// short levels + the summed deficit. Also re-arms the passed latch (the gate is
  /// not eligible at this point).
  void logBlocked(UploadGate gate, {required String sessionId}) {
    _passedLogged = false;
    Analytics.logEvent(AnalyticsEvents.uploadGateBlocked, {
      'session_id': sessionId,
      'phase': 'upload',
      'short_levels': gate.shortLevelsLabel,
      'total_deficit': gate.totalDeficit,
      'device_type': _deviceType,
    });
  }
}
