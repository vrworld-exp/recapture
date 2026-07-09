// lib/application/capture/ring_progress_provider.dart
//
// The LIVE ring-progress wiring for Level A: turns the shared smoothed-orientation
// stream (yaw) into the current eye-ring segment and the [RingDirectionState] the
// guidance engine + direction arrow consume. This replaces the stub
// `ringDirectionStateProvider` that guidance_engine.dart previously defined.
//
// SINGLE SENSOR SUBSCRIPTION: it reuses [orientationSourceProvider] (the same
// native stream `currentPitchProvider` consumes) — no second IMU subscription.
//
// FAIL-OPEN: before the first valid yaw, or when the sensor is unavailable, the
// state is [RingDirectionState.pending] (the engine falls through to the capture
// branch) — guided guidance never strands the user on an impossible cue.
//
// FILL STATE is read from [segmentCoverageProvider] (the single source of truth);
// this layer never marks captures. The optional [ringPositionBinderProvider] keeps
// `SegmentCoverage.position` synced to the live segment so the ring map highlights
// the right target — the capture screen activates it by watching it.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/capture/guidance_inputs.dart' show RingDirectionState;
import '../../domain/capture/ring_progress.dart';
import 'capture_flow_variant_provider.dart';
import 'current_pitch_provider.dart' show sharedOrientationProvider;
import 'segment_coverage_provider.dart';

/// A live yaw→segment sample. [currentSegment] is null before the first valid yaw
/// or when the sensor is unavailable (fail-open).
class RingSegmentSample {
  const RingSegmentSample({
    required this.currentSegment,
    required this.sensorSupported,
  });

  /// The eye-ring segment the user currently points at, or null (pending/unsupported).
  final int? currentSegment;

  /// False when the motion sensor is unavailable (simulator / sensor off / non-device).
  final bool sensorSupported;

  /// Sensor unavailable — no usable segment.
  static const RingSegmentSample unsupported =
      RingSegmentSample(currentSegment: null, sensorSupported: false);
}

/// The per-ring yaw reference — the `yawStart` against which ring position and
/// frame bucketing are measured (segment 0 == this heading). `null` means UNSET:
/// no valid yaw has been seen since the last reset, so downstream stays pending
/// (no segment, no progress) until it is established.
///
/// It is RESET at each ring begin (by the shared capture screen, level-agnostic —
/// see [RingYawBaselineNotifier.reset]) so Level C measures from Level C's OWN
/// start heading, never Level B's stale one. This is the same `yawStart` baseline
/// that used to live as a closure-local inside [currentRingSegmentProvider],
/// promoted to addressable state ONLY so the reset can be deterministic and
/// single-sited — it is NOT a second, parallel reference.
final ringYawBaselineProvider =
    NotifierProvider<RingYawBaselineNotifier, double?>(
  RingYawBaselineNotifier.new,
);

class RingYawBaselineNotifier extends Notifier<double?> {
  @override
  double? build() => null;

  /// Establishes the baseline on the FIRST valid yaw after a reset (when unset);
  /// later samples leave it untouched. Returns the effective baseline so the
  /// caller can bucket the same sample that seeded it.
  double seedIfUnset(double yawDegrees) {
    final current = state;
    if (current != null) return current;
    state = yawDegrees;
    return yawDegrees;
  }

  /// Clears the baseline so the next valid yaw re-establishes it — the ring-begin
  /// reset. Idempotent (a no-op when already unset, so it never churns).
  void reset() {
    if (state != null) state = null;
  }
}

/// The live eye-ring segment from smoothed yaw, measured against the per-ring
/// [ringYawBaselineProvider] baseline (segment 0's start). The FIRST valid yaw
/// AFTER A RESET seeds that baseline; subsequent samples map wraparound-safe via
/// [ringSegmentForYaw]. Broken (NaN/Infinity) reads are dropped; a stream error
/// (absent sensor) degrades to [RingSegmentSample.unsupported] — never an AsyncError.
///
/// The baseline lives in a separate notifier (not a closure-local) so a ring begin
/// can reset it deterministically even though this provider is pinned alive across
/// the session by [ringDirectionStateProvider] (a plain provider) — which is
/// exactly why a closure-local baseline never reset between Level B and Level C.
final currentRingSegmentProvider =
    StreamProvider.autoDispose<RingSegmentSample>((ref) {
  final source = ref.watch(sharedOrientationProvider);
  // The ACTIVE ring's effective N (config × variant × band) — the same source
  // the fill state uses, so yaw→segment and coverage can never disagree (and
  // Levels B/C bucket against THEIR count, not the Eye Ring's).
  final n = ref.watch(activeLevelSegmentCountProvider);
  // Read (not watch) the notifier: seeding the baseline must not rebuild this
  // stream, and a ring-begin reset is observed on the next sample, not via rebuild.
  final baseline = ref.read(ringYawBaselineProvider.notifier);
  final controller = StreamController<RingSegmentSample>();

  final sub = source.listen(
    (o) {
      final yaw = o.yawDegrees;
      if (yaw.isNaN || yaw.isInfinite) return; // drop broken reads
      final yawStart = baseline.seedIfUnset(yaw); // first valid yaw post-reset
      final seg = ringSegmentForYaw(
        yawDegrees: yaw,
        yawStartDegrees: yawStart,
        segmentCount: n,
      );
      if (!controller.isClosed) {
        controller.add(
          RingSegmentSample(currentSegment: seg, sensorSupported: true),
        );
      }
    },
    onError: (Object _, StackTrace __) {
      if (!controller.isClosed) controller.add(RingSegmentSample.unsupported);
    },
  );

  ref.onDispose(() {
    sub.cancel();
    controller.close();
  });

  return controller.stream;
});

/// The single resolved [RingDirectionState] for the guidance engine + direction
/// arrow. Combines the live segment ([currentRingSegmentProvider]) with the live
/// fill state ([segmentCoverageProvider]). Pending/unsupported → fail-open
/// [RingDirectionState.pending]. (Plain provider — kept alive by its watchers, the
/// same way `currentPitchProvider` is, so the sensor stays subscribed during capture.)
final ringDirectionStateProvider = Provider<RingDirectionState>((ref) {
  final seg = ref.watch(currentRingSegmentProvider).valueOrNull?.currentSegment;
  final coverage = ref.watch(segmentCoverageProvider);
  if (seg == null) return RingDirectionState.pending;
  return resolveRingDirection(currentSegment: seg, coverage: coverage);
});

/// Side-effecting binder: keeps [SegmentCoverage.position] synced to the live
/// segment so the ring map's highlighted target (and nearest-missing targeting)
/// stay live. The capture screen activates it by `watch`-ing it; it auto-disposes
/// when the screen leaves (releasing the binding). `updatePosition` is a no-op when
/// the segment is unchanged, so this never churns the coverage state.
final ringPositionBinderProvider = Provider.autoDispose<void>((ref) {
  ref.listen<AsyncValue<RingSegmentSample>>(currentRingSegmentProvider,
      (prev, next) {
    final seg = next.valueOrNull?.currentSegment;
    if (seg != null) {
      ref.read(segmentCoverageProvider.notifier).updatePosition(seg);
    }
  });
});
