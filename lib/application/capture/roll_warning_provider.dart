// lib/application/capture/roll_warning_provider.dart
//
// The roll-constraint advisory state for the Guided Capture HUD (Levels B & C).
// It derives device ROLL from the EXISTING shared smoothed-orientation stream
// (`sharedOrientationProvider` — the SAME source the tilt meter and ring
// segment consume) and applies the pure hysteretic [RollConstraint] rule. NO new
// sensor/orientation subscription is added; this is one more listener on the
// already-shared broadcast stream.
//
// ADVISORY ONLY: nothing reads this to gate capture. It is watched solely by the
// roll-warning overlay; frame acceptance, ring progress, bucketing, and level
// completion never branch on it. autoDispose means it resets per capture screen,
// so a warning can never leak from one ring into the next.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/capture/roll_constraint.dart';
import 'current_tilt_provider.dart' show sharedOrientationProvider;

/// A roll advisory reading for the overlay. [active] is the hysteretic warning
/// flag; [rollDegrees] is the latest SIGNED roll (for the rising-edge analytics);
/// [sensorSupported] is false when the motion sensor is unavailable.
class RollWarningSample {
  const RollWarningSample({
    required this.active,
    required this.rollDegrees,
    required this.sensorSupported,
  });

  /// Whether the ±roll advisory is currently raised.
  final bool active;

  /// The most recent signed roll in degrees (0 and meaningless when
  /// [sensorSupported] is false).
  final double rollDegrees;

  /// False when the motion sensor is unavailable (simulator, sensor off, or a
  /// non-device test host) — the overlay then shows nothing (no false warning).
  final bool sensorSupported;

  /// The inactive / sensor-unavailable reading — never a warning.
  static const RollWarningSample unsupported = RollWarningSample(
    active: false,
    rollDegrees: 0,
    sensorSupported: false,
  );
}

/// The live roll-constraint advisory, derived from [sharedOrientationProvider]
/// with the pure [RollConstraint] hysteresis. Emits a [RollWarningSample] per
/// native tick. A broken (NaN/Infinity) roll sample is dropped — the prior state
/// holds (no flicker, no false clear) — and a stream error (absent sensor) maps
/// to [RollWarningSample.unsupported] rather than an [AsyncError].
final rollWarningProvider =
    StreamProvider.autoDispose<RollWarningSample>((ref) {
  final source = ref.watch(sharedOrientationProvider);
  final controller = StreamController<RollWarningSample>();
  var active = false;

  final sub = source.listen(
    (o) {
      final roll = o.rollDegrees;
      if (roll.isNaN || roll.isInfinite) return; // drop broken reads → hold
      active = RollConstraint.nextActive(active: active, rollDegrees: roll);
      if (!controller.isClosed) {
        controller.add(RollWarningSample(
          active: active,
          rollDegrees: roll,
          sensorSupported: true,
        ));
      }
    },
    onError: (Object _, StackTrace __) {
      active = false; // sensor gone → no warning (never strand a false advisory)
      if (!controller.isClosed) {
        controller.add(RollWarningSample.unsupported);
      }
    },
  );

  ref.onDispose(() {
    sub.cancel();
    controller.close();
  });

  return controller.stream;
});
