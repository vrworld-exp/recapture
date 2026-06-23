// lib/application/capture/current_pitch_provider.dart
//
// Smoothed current-pitch source for the Level A tilt meter. Wraps the native
// smoothed-orientation stream (`imu_orientation` → SmoothedOrientation, already
// low-pass filtered in the quaternion domain natively) and exposes it as a tiny
// [PitchSample] (pitch in degrees + a sensor-supported flag). A light secondary
// EMA removes residual jitter so the needle never flickers; an absent/failed
// sensor (PlatformException('SENSOR_UNAVAILABLE'), MissingPluginException on a
// non-device host) degrades to an unsupported sample instead of an error state.
//
// This is the SAME pitch convention `CaptureConfig.pitchBands` are defined
// against (SmoothedOrientation.pitchDegrees — see capture_pitch_guide.dart), so
// the meter's needle and its target band share one coordinate frame.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/imu_rotation_channel.dart';

/// A smoothed pitch reading for the tilt meter.
class PitchSample {
  const PitchSample({
    required this.pitchDegrees,
    required this.sensorSupported,
  });

  /// Smoothed device pitch in degrees (SmoothedOrientation convention). Zero and
  /// meaningless when [sensorSupported] is false.
  final double pitchDegrees;

  /// False when the motion sensor is unavailable (simulator, sensor off, or a
  /// non-device test host) — the meter shows a non-blocking fallback.
  final bool sensorSupported;
}

/// Light secondary low-pass factor applied on top of the native smoothing. Small
/// enough to stay responsive; large enough to absorb residual single-sample
/// jitter. Tunable; could later move to [CaptureConfig].
const double kPitchEmaAlpha = 0.2;

/// One exponential-moving-average step. [prev] null ⇒ seed with [raw].
double emaStep(double? prev, double raw, {double alpha = kPitchEmaAlpha}) =>
    prev == null ? raw : alpha * raw + (1 - alpha) * prev;

/// Injectable seam: the raw smoothed-orientation source. Production wires the
/// native [ImuOrientationStream]; tests override this with a controlled stream
/// (no platform channels needed).
final orientationSourceProvider =
    Provider.autoDispose<Stream<SmoothedOrientation>>(
  (ref) => ImuOrientationStream().orientation(),
);

/// Smoothed current pitch for the tilt meter. Emits a [PitchSample] per native
/// tick; a stream error (absent sensor) is mapped to an unsupported sample so
/// consumers see a graceful fallback rather than an [AsyncError]. NaN/Infinity
/// samples (broken reads) are dropped, never forwarded.
final currentPitchProvider = StreamProvider.autoDispose<PitchSample>((ref) {
  final source = ref.watch(orientationSourceProvider);
  final controller = StreamController<PitchSample>();
  double? smoothed;

  final sub = source.listen(
    (s) {
      final raw = s.pitchDegrees;
      if (raw.isNaN || raw.isInfinite) return; // drop broken reads
      smoothed = emaStep(smoothed, raw);
      if (!controller.isClosed) {
        controller.add(
          PitchSample(pitchDegrees: smoothed!, sensorSupported: true),
        );
      }
    },
    onError: (Object _, StackTrace __) {
      // Absent/failed sensor → non-blocking fallback, not an error state.
      if (!controller.isClosed) {
        controller.add(
          const PitchSample(pitchDegrees: 0, sensorSupported: false),
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
