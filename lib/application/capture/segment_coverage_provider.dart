// lib/application/capture/segment_coverage_provider.dart
//
// Thin reactive wrapper over the pure [SegmentCoverage] state model for the
// Level A guided-capture HUD. All the derivation/selection logic lives in the
// immutable model (and is unit-tested without Riverpod); this notifier only
// holds the current snapshot and forwards the model's transforms so the HUD can
// `watch` it.
//
// The ring shape (N) is seeded from `captureConfigProvider.eyeRingSegments` —
// the SAME source the ring map and tilt meter use — so the fill state and the
// rendered ring can never disagree on segment count. It re-seeds if remote
// config changes N (via `reconfigure`, which drops now-meaningless indices).
//
// Wiring to the live capture flow (calling [recordCapture] on a successful
// capture in the engine's current segment, and [updatePosition] from the ring
// engine's `currentSegment`) is the consumer's responsibility — see the capture
// trigger / ring-progress resolver tasks. This provider just exposes the state.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/segment_coverage.dart';
import '../config/config_notifier.dart';

/// The eye-ring segment-fill state for the current Level A session. Watch for
/// the derived `filled` / `missingSegments` / `currentTarget` / `progress`.
final segmentCoverageProvider =
    NotifierProvider<SegmentCoverageNotifier, SegmentCoverage>(
  SegmentCoverageNotifier.new,
);

class SegmentCoverageNotifier extends Notifier<SegmentCoverage> {
  @override
  SegmentCoverage build() {
    // Seed N from the eye-ring band and keep it in sync with remote config. A
    // change in segment count re-inits (old indices no longer map); a no-op
    // otherwise. fillThreshold stays at the model default (1) — there is no
    // per-segment fill requirement in CaptureConfig yet.
    final n = ref.watch(
      captureConfigProvider.select((c) => c.eyeRingSegments),
    );
    final current = stateOrNull;
    if (current != null && current.segmentCount == n) return current;
    return SegmentCoverage.initial(segmentCount: n);
  }

  /// Fills the segment captured (the engine's current segment at capture time).
  void recordCapture(int segmentIndex) =>
      state = state.recordCapture(segmentIndex);

  /// Removes one capture from [segmentIndex] (decrement) when a photo is deleted.
  /// Returns whether the segment is now MISSING (dropped below the fill
  /// threshold) — the caller uses this to retarget guidance to a freed segment.
  bool removeCapture(int segmentIndex) {
    state = state.removeCapture(segmentIndex);
    return state.missingSegments.contains(segmentIndex);
  }

  /// Re-aims the target at the new position (from the ring engine). Fills
  /// nothing.
  void updatePosition(int currentSegment) =>
      state = state.updatePosition(currentSegment);

  /// Clears coverage for a new run (keeps the ring shape).
  void reset() => state = state.reset();

  /// Re-inits for a new ring shape (e.g. a config-driven N or threshold change).
  void reconfigure({required int segmentCount, int fillThreshold = 1}) =>
      state = state.reconfigure(
        segmentCount: segmentCount,
        fillThreshold: fillThreshold,
      );
}
