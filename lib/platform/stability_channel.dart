// lib/platform/stability_channel.dart
//
// EventChannel wrapper for the native stability gate (gyro + gravity-removed
// linear-accel motion detector). Emits a debounced stable/unstable STATE on
// transitions, plus a "stable" TRIGGER the auto-capture flow consumes. The gate:
// gyroMag < gyroThresh AND linAccelMag < accelThresh, held continuously for
// dwellMs. Channel name: com.mayasabhaxr.recapture/stability
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/constants.dart';

/// A native stability event. Discriminated by the native `type`.
@immutable
sealed class StabilityEvent {
  const StabilityEvent();

  /// Parses a native event map; returns null for an unknown/malformed shape.
  static StabilityEvent? fromEvent(Object? event) {
    if (event is! Map) return null;
    final map = event.cast<String, dynamic>();
    switch (map['type']) {
      case 'state':
        final stable = map['stable'];
        if (stable is! bool) return null;
        return StabilityStateEvent(
          stable: stable,
          gyroMag: (map['gyroMag'] as num?)?.toDouble() ?? 0,
          linAccelMag: (map['linAccelMag'] as num?)?.toDouble() ?? 0,
          timestampNs: (map['timestampNs'] as num?)?.toInt() ?? 0,
        );
      case 'trigger':
        return StabilityTriggerEvent(
          timestampNs: (map['timestampNs'] as num?)?.toInt() ?? 0,
        );
      case 'score':
        final score = (map['score'] as num?)?.toDouble();
        if (score == null) return null;
        return StabilityScoreEvent(
          score: score,
          gyroMag: (map['gyroMag'] as num?)?.toDouble() ?? 0,
          linAccelMag: (map['linAccelMag'] as num?)?.toDouble() ?? 0,
          timestampNs: (map['timestampNs'] as num?)?.toInt() ?? 0,
        );
      default:
        return null;
    }
  }
}

/// A debounced state transition (entered or left STABLE). [gyroMag]/[linAccelMag]
/// are the magnitudes at the transition, for a UI indicator.
@immutable
class StabilityStateEvent extends StabilityEvent {
  const StabilityStateEvent({
    required this.stable,
    required this.gyroMag,
    required this.linAccelMag,
    required this.timestampNs,
  });

  final bool stable;

  /// Gyro magnitude (rad/s) at the transition.
  final double gyroMag;

  /// Gravity-removed linear-accel magnitude (m/s²) at the transition.
  final double linAccelMag;

  /// Camera-aligned (CLOCK_MONOTONIC) sensor timestamp of the transition.
  final int timestampNs;
}

/// Fired when the gate ENTERS stable — the auto-capture trigger.
@immutable
class StabilityTriggerEvent extends StabilityEvent {
  const StabilityTriggerEvent({required this.timestampNs});

  /// Camera-aligned (CLOCK_MONOTONIC) sensor timestamp the gate opened at.
  final int timestampNs;
}

/// A continuous (non-debounced) stillness score, emitted throttled (~10 Hz) for a
/// UI stillness meter. [score] ∈ [0, 1]: 1.0 perfectly still, falling to 0.0 as
/// gyro or gravity-removed linear-accel reaches its threshold — it crosses ~0
/// around the same boundary the debounced gate flips, but is NOT the gate
/// decision itself (use [StabilityTriggerEvent] for auto-capture).
@immutable
class StabilityScoreEvent extends StabilityEvent {
  const StabilityScoreEvent({
    required this.score,
    required this.gyroMag,
    required this.linAccelMag,
    required this.timestampNs,
  });

  /// Stillness in [0, 1] (1.0 = perfectly still).
  final double score;

  /// Gyro magnitude (rad/s) at this sample.
  final double gyroMag;

  /// Gravity-removed linear-accel magnitude (m/s²) at this sample.
  final double linAccelMag;

  /// Camera-aligned (CLOCK_MONOTONIC) sensor timestamp of this sample.
  final int timestampNs;
}

/// Streams native stability events over the [EventChannel].
///
/// Thresholds are best-effort hints with native defaults (0.8 rad/s, 0.15 g,
/// 250 ms) and may be sourced from remote config by the caller. An absent sensor
/// surfaces as a `PlatformException('STABILITY_UNAVAILABLE')`.
class StabilityGateStream {
  StabilityGateStream([EventChannel? channel])
      : _channel = channel ?? const EventChannel(AppConfig.channelStability);

  final EventChannel _channel;

  static const double defaultGyroThreshRadS = 0.8;
  static const double defaultAccelThreshG = 0.15;
  static const int defaultDwellMs = 250;

  /// All stability events (state transitions + triggers). Malformed events are
  /// filtered. [gyroThresh] rad/s, [accelThresh] in g, [dwellMs] are forwarded to
  /// the native gate (invalid values fall back to the native defaults).
  Stream<StabilityEvent> events({
    double gyroThresh = defaultGyroThreshRadS,
    double accelThresh = defaultAccelThreshG,
    int dwellMs = defaultDwellMs,
  }) {
    return _channel
        .receiveBroadcastStream(<String, dynamic>{
          'gyroThresh': gyroThresh,
          'accelThresh': accelThresh,
          'dwellMs': dwellMs,
        })
        .map(StabilityEvent.fromEvent)
        .where((e) => e != null)
        .cast<StabilityEvent>();
  }

  /// Only the "stable" triggers (for an auto-capture driver that ignores state).
  Stream<StabilityTriggerEvent> triggers({
    double gyroThresh = defaultGyroThreshRadS,
    double accelThresh = defaultAccelThreshG,
    int dwellMs = defaultDwellMs,
  }) =>
      events(gyroThresh: gyroThresh, accelThresh: accelThresh, dwellMs: dwellMs)
          .where((e) => e is StabilityTriggerEvent)
          .cast<StabilityTriggerEvent>();

  /// Only the continuous score samples (for a UI stillness meter that ignores
  /// the debounced state/trigger). Throttled (~10 Hz) by the native side.
  Stream<StabilityScoreEvent> scores({
    double gyroThresh = defaultGyroThreshRadS,
    double accelThresh = defaultAccelThreshG,
    int dwellMs = defaultDwellMs,
  }) =>
      events(gyroThresh: gyroThresh, accelThresh: accelThresh, dwellMs: dwellMs)
          .where((e) => e is StabilityScoreEvent)
          .cast<StabilityScoreEvent>();
}
