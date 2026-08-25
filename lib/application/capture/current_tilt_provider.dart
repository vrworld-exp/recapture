// lib/application/capture/current_tilt_provider.dart
//
// Smoothed current camera-tilt source for the guided capture (tilt meter,
// shutter gate, auto-capture). Wraps the native smoothed-orientation stream
// (`imu_orientation` → SmoothedOrientation, already low-pass filtered in the
// quaternion domain natively), derives the 0–180° camera-tilt scalar from the
// smoothed quaternion (`SmoothedOrientation.cameraTiltDegrees` — see
// lib/domain/capture/camera_tilt.dart) and exposes it as a tiny [TiltSample].
// A light secondary EMA removes residual jitter so the needle never flickers
// (safe on tilt: [0, 180] has no wraparound); an absent/failed sensor
// (PlatformException('SENSOR_UNAVAILABLE'), MissingPluginException on a
// non-device host) degrades to an unsupported sample instead of an error state.
//
// This is the SAME 0–180° scale `CaptureConfig.pitchBands` are defined against
// (see capture_pitch_guide.dart), so the meter's needle, its target band, the
// shutter gate, and the auto-capture trigger share ONE coordinate frame.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/imu_rotation_channel.dart';

/// A smoothed camera-tilt reading for the guided-capture band logic.
class TiltSample {
  const TiltSample({
    required this.tiltDegrees,
    required this.sensorSupported,
  });

  /// Smoothed camera tilt in degrees on the 0–180° scale (0 = camera at the
  /// sky, 90 = horizon, ~180 = at the ground). Zero and meaningless when
  /// [sensorSupported] is false.
  final double tiltDegrees;

  /// False when the motion sensor is unavailable (simulator, sensor off, or a
  /// non-device test host) — the meter shows a non-blocking fallback.
  final bool sensorSupported;
}

/// Light secondary low-pass factor applied on top of the native smoothing. Small
/// enough to stay responsive; large enough to absorb residual single-sample
/// jitter. Tunable; could later move to [CaptureConfig].
const double kTiltEmaAlpha = 0.2;

/// One exponential-moving-average step. [prev] null ⇒ seed with [raw].
double emaStep(double? prev, double raw, {double alpha = kTiltEmaAlpha}) =>
    prev == null ? raw : alpha * raw + (1 - alpha) * prev;

/// Injectable seam: the raw smoothed-orientation source. Production wires the
/// native [ImuOrientationStream]; tests override this with a controlled stream
/// (no platform channels needed).
final orientationSourceProvider =
    Provider.autoDispose<Stream<SmoothedOrientation>>(
  (ref) => ImuOrientationStream().orientation(),
);

/// The SHARED, multi-listenable smoothed-orientation stream. Both
/// [currentTiltProvider] (tilt) and the ring-progress resolver
/// (`currentRingSegmentProvider`) consume THIS — so the raw
/// [orientationSourceProvider] is listened to exactly ONCE regardless of how many
/// HUD consumers exist (the "single shared sensor subscription" rule), and a
/// single-subscription test stream is never double-listened. `asBroadcastStream`
/// is a no-op when the source is already a broadcast stream.
final sharedOrientationProvider =
    Provider.autoDispose<Stream<SmoothedOrientation>>(
  (ref) => ref.watch(orientationSourceProvider).asBroadcastStream(),
);

/// Smoothed current camera tilt for the guided capture. Emits a [TiltSample]
/// per native tick; a stream error (absent sensor) is mapped to an unsupported
/// sample so consumers see a graceful fallback rather than an [AsyncError].
/// NaN/Infinity tilts (broken reads, missing/degenerate quaternion) are
/// dropped, never forwarded.
final currentTiltProvider = StreamProvider.autoDispose<TiltSample>((ref) {
  final source = ref.watch(sharedOrientationProvider);
  final controller = StreamController<TiltSample>();
  double? smoothed;

  final sub = source.listen(
    (s) {
      final raw = s.cameraTiltDegrees;
      if (raw.isNaN || raw.isInfinite) return; // drop broken reads
      smoothed = emaStep(smoothed, raw);
      if (!controller.isClosed) {
        controller.add(
          TiltSample(tiltDegrees: smoothed!, sensorSupported: true),
        );
      }
    },
    onError: (Object _, StackTrace __) {
      // Absent/failed sensor → non-blocking fallback, not an error state.
      if (!controller.isClosed) {
        controller.add(
          const TiltSample(tiltDegrees: 0, sensorSupported: false),
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
