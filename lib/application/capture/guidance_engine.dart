// lib/application/capture/guidance_engine.dart
//
// The application layer over the pure [resolveGuidance] resolver: an anti-thrash
// dwell wrapper, the analytics emission on committed-instruction changes, and the
// Riverpod wiring that combines the upstream signal providers into the single
// [GuidanceOutput] the banner + arrow consume.
//
// DWELL: signals can oscillate at their boundaries. A change to a DIFFERENT,
// lower-priority instruction id (direction / capture / capture-next) is only
// committed after it has persisted for [minDwell]; higher-priority warnings
// (tilt / stability) and the terminal 'complete' PREEMPT immediately (safety/
// quality cues must appear fast). Same-id content changes (e.g. "Tilt up"→"Tilt
// down", or arrow urgency) commit immediately — the banner won't re-animate on a
// same-id update, so there is nothing to thrash. Upstream tilt/stability already
// have hysteresis, so this dwell is light.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/capture/guidance_inputs.dart';
import '../../domain/capture/guidance_output.dart';
import '../../domain/capture/guidance_resolver.dart';
import '../../domain/entities/capture_config.dart';
import '../../domain/entities/capture_readiness.dart' show CaptureMode;
import '../../domain/entities/tilt_target.dart';
import '../../utils/analytics.dart';
import '../config/config_notifier.dart';
import 'current_tilt_provider.dart';
import 'ring_progress_provider.dart' show ringDirectionStateProvider;
import 'stability_provider.dart';

/// Instruction ids that preempt the dwell (commit immediately): the two warnings
/// plus the terminal completion state.
const Set<String> _preemptiveIds = {'tilt', 'stability', 'complete'};

/// Stateful anti-thrash wrapper over [resolveGuidance]. Deterministic with an
/// injected [now] clock for testing.
class GuidanceDwell {
  GuidanceDwell({
    this.minDwell = const Duration(milliseconds: 300),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration minDwell;
  final DateTime Function() _now;

  GuidanceOutput? _committed;
  String? _pendingId;
  DateTime? _pendingSince;

  /// The currently committed output, or null before the first tick.
  GuidanceOutput? get committed => _committed;

  /// Resolves [inputs] and returns the committed output for this tick, applying
  /// the dwell to lower-priority id changes.
  GuidanceOutput tick(GuidanceInputs inputs) {
    final candidate = resolveGuidance(inputs);
    final committed = _committed;

    // First tick → commit immediately.
    if (committed == null) return _commit(candidate);

    // Same logical instruction → update content now (no re-animate, no thrash).
    if (candidate.instruction.id == committed.instruction.id) {
      return _commit(candidate);
    }

    // Different id: warnings/complete preempt the dwell.
    if (_preemptiveIds.contains(candidate.instruction.id)) {
      return _commit(candidate);
    }

    // Lower-priority change → require it to persist for [minDwell].
    final t = _now();
    if (_pendingId != candidate.instruction.id) {
      _pendingId = candidate.instruction.id;
      _pendingSince = t;
    }
    if (t.difference(_pendingSince!) >= minDwell) {
      return _commit(candidate);
    }
    return committed; // hold the previous instruction until the dwell elapses
  }

  GuidanceOutput _commit(GuidanceOutput output) {
    _committed = output;
    _pendingId = null;
    _pendingSince = null;
    return output;
  }
}

/// [GuidanceDwell] + throttled analytics: emits [AnalyticsEvents
/// .guidanceInstructionChanged] only when the COMMITTED instruction id changes
/// (never per tick).
class GuidanceEngine {
  GuidanceEngine({
    Duration minDwell = const Duration(milliseconds: 300),
    DateTime Function()? now,
  }) : _dwell = GuidanceDwell(minDwell: minDwell, now: now);

  final GuidanceDwell _dwell;
  String? _lastEmittedId;

  GuidanceOutput tick(GuidanceInputs inputs, {required String deviceType}) {
    final output = _dwell.tick(inputs);
    final id = output.instruction.id;
    if (id != _lastEmittedId) {
      _lastEmittedId = id;
      Analytics.logEvent(AnalyticsEvents.guidanceInstructionChanged, {
        'instruction': id,
        'sensor_supported': inputs.sensorSupported,
        'device_type': deviceType,
      });
    }
    return output;
  }
}

// ─── providers ──────────────────────────────────────────────────────────────

/// The current capture mode (guided = auto-capture, manual = tap). Stubbed to
/// [CaptureMode.guided]; OVERRIDE from the real source (project mode / auto-
/// capture setting) when that wiring lands — the capture-branch message reads it.
final captureModeProvider =
    Provider<CaptureMode>((ref) => CaptureMode.guided);

// The live `ringDirectionStateProvider` now lives in ring_progress_provider.dart
// (the real yaw→RingDirectionState resolver), imported above. It replaced the
// former stub that returned [RingDirectionState.pending].

/// Holds the single [GuidanceEngine] (its dwell state persists across rebuilds).
final guidanceEngineProvider = Provider<GuidanceEngine>((ref) => GuidanceEngine());

/// The single resolved guidance for the HUD: the banner watches
/// `guidanceProvider.instruction`, the arrow watches `.direction`. Recomputes on
/// every upstream signal change (each recompute is one engine tick).
final guidanceProvider = Provider<GuidanceOutput>((ref) {
  final tiltSample = ref.watch(currentTiltProvider).valueOrNull;
  final stabilitySample = ref.watch(stabilityProvider).valueOrNull;
  final config = ref.watch(captureConfigProvider);
  final ring = ref.watch(ringDirectionStateProvider);
  final mode = ref.watch(captureModeProvider);

  final tiltSupported = tiltSample?.sensorSupported ?? false;
  final stabilitySupported = stabilitySample?.sensorSupported ?? false;
  // Trust the sensor branches only when BOTH IMU-derived signals are usable;
  // otherwise the resolver skips tilt/stability (fail-through), never stranding
  // the user on an impossible cue.
  final sensorSupported = tiltSupported && stabilitySupported;

  final target = _eyeRingTarget(config);
  final tilt = (tiltSample != null && tiltSupported)
      ? tiltStateFor(tiltSample.tiltDegrees, target)
      : TiltState.inBand; // moot when !sensorSupported (tilt branch skipped)
  final stability = stabilitySample?.stability ?? Stability.unknown;

  final inputs = GuidanceInputs(
    sensorSupported: sensorSupported,
    tilt: tilt,
    stability: stability,
    ring: ring,
    mode: mode,
  );
  return ref.read(guidanceEngineProvider).tick(inputs, deviceType: _deviceType);
});

/// Level A Eye Ring target band (the 'mid' band — same one the tilt meter
/// targets), falling back to the first band, then a sane default.
TiltTarget _eyeRingTarget(CaptureConfig config) {
  for (final b in config.pitchBands) {
    if (b.id == 'mid') return TiltTarget.fromBand(b);
  }
  if (config.pitchBands.isNotEmpty) {
    return TiltTarget.fromBand(config.pitchBands.first);
  }
  // Last-resort floor: the bundled `mid` band on the 0–180° camera-tilt scale.
  return const TiltTarget(minDegrees: 60, maxDegrees: 120, bandId: 'mid');
}

String get _deviceType => switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      _ => 'unknown',
    };
