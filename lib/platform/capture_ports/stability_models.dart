// lib/platform/capture_ports/stability_models.dart
//
// The stability event types, moved out of lib/platform/stability_channel.dart
// (which re-exports them) so the port interface and BOTH implementations can
// depend on them without an import cycle. The shapes, the `type` discriminator
// and the `fromEvent` parsing are unchanged — the web port builds the same
// events from `devicemotion` via the ported gate in stability_math.dart.
import 'package:flutter/foundation.dart';

/// A stability event. Discriminated by the native `type`.
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

  /// Camera-aligned (CLOCK_MONOTONIC on native, `performance.now()` on web)
  /// sensor timestamp of the transition.
  final int timestampNs;
}

/// Fired when the gate ENTERS stable — the auto-capture trigger.
@immutable
class StabilityTriggerEvent extends StabilityEvent {
  const StabilityTriggerEvent({required this.timestampNs});

  /// Sensor timestamp the gate opened at.
  final int timestampNs;
}

/// A continuous (non-debounced) stillness score, emitted throttled (~10 Hz) for
/// a UI stillness meter. [score] ∈ [0, 1]: 1.0 perfectly still, falling to 0.0
/// as gyro or gravity-removed linear-accel reaches its threshold — it crosses ~0
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

  /// Sensor timestamp of this sample.
  final int timestampNs;
}
