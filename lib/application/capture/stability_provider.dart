// lib/application/capture/stability_provider.dart
//
// Stability source for the Level A stability indicator. It consumes the EXISTING
// native stability gate (`StabilityGateStream`, channel `stability`) — the same
// debounced gate the auto-capture trigger uses — rather than re-deriving motion
// from raw sensor samples in Dart. That gate already does the hard part natively:
// it fuses gyro (rad/s) AND gravity-removed linear-accel (g), low-pass smooths
// them, and applies hysteresis + a dwell window (defaults 0.8 rad/s, 0.15 g,
// 250 ms) so "unstable" shows promptly while "stable" requires a sustained calm.
// Driving the indicator from the SAME gate guarantees the dot the user sees
// matches the decision that actually opens the shutter — a parallel Dart
// classifier over `sensorStream.accelerometer` (no gyro) would drift from it.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/stability_channel.dart';

/// Coarse stability for the UI. [unknown] is the pre-first-transition / sensor-
/// unavailable state.
enum Stability { unknown, stable, unstable }

/// A stability reading for the indicator.
class StabilitySample {
  const StabilitySample({
    required this.stability,
    required this.sensorSupported,
  });

  final Stability stability;

  /// False when the motion sensor is unavailable (simulator, sensor off, or a
  /// non-device test host) — the indicator shows a non-blocking fallback.
  final bool sensorSupported;
}

/// Injectable seam: the native stability-gate event source. Production wires the
/// real [StabilityGateStream]; tests override this with a controlled stream (no
/// platform channels needed). Thresholds use the gate's native defaults — there
/// is no motion threshold in [CaptureConfig.thresholds] to source instead, and
/// the gate's thresholds are already server-tunable on the native side.
final stabilityEventSourceProvider =
    Provider.autoDispose<Stream<StabilityEvent>>(
  (ref) => StabilityGateStream().events(),
);

/// Smoothed + debounced stability for the indicator. Only the native gate's
/// debounced [StabilityStateEvent] drives the label (the continuous score and
/// the auto-capture trigger events are ignored here). A stream error (absent
/// sensor → `STABILITY_UNAVAILABLE`) degrades to an unsupported [unknown] sample
/// instead of surfacing as an [AsyncError]; until the first state transition the
/// provider is simply loading (the widget renders [unknown]).
final stabilityProvider = StreamProvider.autoDispose<StabilitySample>((ref) {
  final source = ref.watch(stabilityEventSourceProvider);
  final controller = StreamController<StabilitySample>();

  final sub = source.listen(
    (event) {
      // Transition-only debounced state. Trigger/score events are not the label.
      if (event is StabilityStateEvent && !controller.isClosed) {
        controller.add(
          StabilitySample(
            stability: event.stable ? Stability.stable : Stability.unstable,
            sensorSupported: true,
          ),
        );
      }
    },
    onError: (Object _, StackTrace __) {
      if (!controller.isClosed) {
        controller.add(
          const StabilitySample(
            stability: Stability.unknown,
            sensorSupported: false,
          ),
        );
      }
    },
  );

  ref.onDispose(() {
    sub.cancel();
    controller.close();
  });

  return controller.stream;
});
