// lib/platform/capture_ports/stability_math.dart
//
// Pure Dart — NO Flutter, NO dart:io, NO dart:js_interop. A port of the native
// stability gate (android/app/src/main/kotlin/.../sensors/StabilityGate.kt) so
// the browser's `devicemotion` stream is judged by exactly the same rule as the
// phone's gyro + linear-accel fusion:
//
//   STABLE  <=>  |gyro| < gyroThresh (rad/s)
//           AND  |linear accel| < accelThresh (default 0.15 g)
//           held CONTINUOUSLY for dwellMs, measured from sample timestamps.
//
// Same strict `<`, same dt-aware dwell, same gap-reset, same geometric-mean
// stillness score, same defaults. That is what "calibrated to emit stable under
// roughly the same physical steadiness as native" actually means here: not a
// hand-tuned browser threshold, but the identical decision function fed the
// browser's equivalent signals.
//
// The one genuine difference is upstream of this file: `devicemotion` reports
// `rotationRate` in **degrees/second** and may report `acceleration` as null on
// devices without gravity separation, in which case [GravityEstimator] (also a
// port of the native fallback) subtracts an estimated gravity vector from
// `accelerationIncludingGravity`.
import 'dart:math' as math;

import 'orientation_math.dart' show OrientationMath;

/// Magnitude / unit helpers and the continuous stillness score.
abstract final class StabilityMath {
  /// Standard gravity (m/s²) used to convert the g threshold to SI.
  static const double gravityMs2 = 9.81;

  /// Euclidean magnitude of a 3-vector.
  static double magnitude(double x, double y, double z) =>
      math.sqrt(x * x + y * y + z * z);

  /// Converts a g value (e.g. 0.15) to m/s² (0.15 × 9.81 ≈ 1.47).
  static double gToMs2(double g) => g * gravityMs2;

  /// Continuous stillness score in [0, 1] for a UI meter: 1.0 when perfectly
  /// still, falling to 0.0 as EITHER signal reaches its threshold. The
  /// geometric mean of the two clamped proximity-to-threshold partials, so one
  /// signal alone can collapse it — mirroring the gate's AND. An INSTANTANEOUS
  /// display signal, never the debounced gate decision.
  static double score(
    double gyroMag,
    double linAccelMag,
    double gyroThresh,
    double accelThresh,
  ) =>
      math.sqrt(
          _partial(gyroMag, gyroThresh) * _partial(linAccelMag, accelThresh));

  static double _partial(double value, double threshold) {
    if (!value.isFinite || threshold <= 0.0) return 0.0;
    return 1.0 - (value / threshold).clamp(0.0, 1.0);
  }
}

/// Gravity-removal fallback for sources lacking a gravity-free acceleration
/// (`DeviceMotionEvent.acceleration` is null on a number of Android browsers):
/// a dt-aware low-pass estimates gravity from the raw vector and subtracts it.
/// The first sample is assumed to be pure gravity (linear ≈ 0).
class GravityEstimator {
  GravityEstimator({this.tauNs = defaultGravityTauNs});

  /// Slow gravity tracker (~0.5 s) — tracks gravity, rejects brief motion.
  static const double defaultGravityTauNs = 500000000.0;

  final double tauNs;

  final List<double> _gravity = List<double>.filled(3, 0);
  bool _hasState = false;
  int _prevTimestampNs = 0;

  void reset() => _hasState = false;

  /// Updates the estimate from a raw accel sample; returns |linear accel|.
  double linearMagnitude(double ax, double ay, double az, int timestampNs) {
    if (!_hasState) {
      _gravity[0] = ax;
      _gravity[1] = ay;
      _gravity[2] = az;
      _hasState = true;
      _prevTimestampNs = timestampNs;
      return 0.0;
    }
    final dt = (timestampNs - _prevTimestampNs).toDouble();
    _prevTimestampNs = timestampNs;
    final a = OrientationMath.alpha(dt, tauNs);
    _gravity[0] += a * (ax - _gravity[0]);
    _gravity[1] += a * (ay - _gravity[1]);
    _gravity[2] += a * (az - _gravity[2]);
    return StabilityMath.magnitude(
      ax - _gravity[0],
      ay - _gravity[1],
      az - _gravity[2],
    );
  }
}

/// Validated stability thresholds. Build via [StabilityConfig.build] to apply
/// the same defaults/clamps the native side applies.
class StabilityConfig {
  const StabilityConfig({
    required this.gyroThreshRadS,
    required this.accelThreshMs2,
    required this.dwellNs,
    this.gapResetNs = defaultGapResetNs,
  });

  static const double defaultGyroThreshRadS = 0.8;
  static const double defaultAccelThreshG = 0.15;
  static const int defaultDwellMs = 250;

  /// Beyond this inter-sample gap, the dwell breaks (pause/dropped samples).
  static const int defaultGapResetNs = 500000000;

  /// Linear-accel threshold in **m/s²** (converted from the g input).
  final double gyroThreshRadS;
  final double accelThreshMs2;
  final int dwellNs;
  final int gapResetNs;

  static final StabilityConfig defaults = StabilityConfig(
    gyroThreshRadS: defaultGyroThreshRadS,
    accelThreshMs2: StabilityMath.gToMs2(defaultAccelThreshG),
    dwellNs: defaultDwellMs * 1000000,
  );

  /// Applies defaults for any missing/invalid input (non-finite or non-positive
  /// thresholds, negative dwell). [accelThreshG] is in g and converted to m/s²
  /// HERE — the single, explicit unit conversion.
  static StabilityConfig build({
    double? gyroThreshRadS,
    double? accelThreshG,
    int? dwellMs,
  }) {
    final gyro = (gyroThreshRadS != null &&
            gyroThreshRadS.isFinite &&
            gyroThreshRadS > 0)
        ? gyroThreshRadS
        : defaultGyroThreshRadS;
    final accelG =
        (accelThreshG != null && accelThreshG.isFinite && accelThreshG > 0)
            ? accelThreshG
            : defaultAccelThreshG;
    final dwell = (dwellMs != null && dwellMs >= 0) ? dwellMs : defaultDwellMs;
    return StabilityConfig(
      gyroThreshRadS: gyro,
      accelThreshMs2: StabilityMath.gToMs2(accelG),
      dwellNs: dwell * 1000000,
    );
  }
}

/// A debounced stability transition: produced only when `stable` flips.
class StabilityTransition {
  const StabilityTransition({
    required this.stable,
    required this.gyroMag,
    required this.linAccelMag,
    required this.timestampNs,
  });

  final bool stable;
  final double gyroMag;
  final double linAccelMag;
  final int timestampNs;
}

/// An instantaneous (non-debounced) reading for the UI stillness meter.
class StabilityReading {
  const StabilityReading({
    required this.score,
    required this.gyroMag,
    required this.linAccelMag,
  });

  final double score;
  final double gyroMag;
  final double linAccelMag;
}

/// dt-aware dwell state machine. Fed the latest gyro / linear-accel magnitude
/// as each sample arrives; returns a [StabilityTransition] ONLY when the
/// debounced state flips, never per sample.
class StabilityGate {
  StabilityGate([StabilityConfig? config])
      : config = config ?? StabilityConfig.defaults;

  StabilityConfig config;

  double _gyroMag = double.nan;
  double _linAccelMag = double.nan;
  bool _haveGyro = false;
  bool _haveAccel = false;

  /// Sample timestamp when the combined condition first became true, or null.
  int? _conditionStartTs;
  bool _stable = false;
  int? _lastSampleTs;

  bool get isStable => _stable;

  void reset() {
    _gyroMag = double.nan;
    _linAccelMag = double.nan;
    _haveGyro = false;
    _haveAccel = false;
    _conditionStartTs = null;
    _stable = false;
    _lastSampleTs = null;
  }

  StabilityTransition? onGyro(double magnitude, int timestampNs) {
    _gyroMag = magnitude;
    _haveGyro = true;
    return _evaluate(timestampNs);
  }

  StabilityTransition? onLinearAccel(double magnitude, int timestampNs) {
    _linAccelMag = magnitude;
    _haveAccel = true;
    return _evaluate(timestampNs);
  }

  /// The current instantaneous reading, or null until BOTH signals have
  /// reported (so an early, misleading score is never surfaced).
  StabilityReading? currentReading() {
    if (!_haveGyro || !_haveAccel) return null;
    return StabilityReading(
      score: StabilityMath.score(
        _gyroMag,
        _linAccelMag,
        config.gyroThreshRadS,
        config.accelThreshMs2,
      ),
      gyroMag: _gyroMag,
      linAccelMag: _linAccelMag,
    );
  }

  StabilityTransition? _evaluate(int ts) {
    final last = _lastSampleTs;
    _lastSampleTs = ts;
    // A large inter-sample gap breaks dwell continuity (pause / dropped run).
    if (last != null && ts - last > config.gapResetNs) {
      _conditionStartTs = null;
      if (_stable) {
        _stable = false;
        return _transition(false, ts);
      }
    }

    final condition = _haveGyro &&
        _haveAccel &&
        _gyroMag < config.gyroThreshRadS &&
        _linAccelMag < config.accelThreshMs2;

    if (!condition) {
      _conditionStartTs = null;
      if (_stable) {
        _stable = false;
        return _transition(false, ts);
      }
      return null;
    }

    final start = _conditionStartTs;
    if (start == null) {
      _conditionStartTs = ts;
      return null;
    }
    if (!_stable && ts - start >= config.dwellNs) {
      _stable = true;
      return _transition(true, ts);
    }
    return null;
  }

  StabilityTransition _transition(bool becameStable, int ts) =>
      StabilityTransition(
        stable: becameStable,
        gyroMag: _gyroMag.isFinite ? _gyroMag : 0.0,
        linAccelMag: _linAccelMag.isFinite ? _linAccelMag : 0.0,
        timestampNs: ts,
      );
}
