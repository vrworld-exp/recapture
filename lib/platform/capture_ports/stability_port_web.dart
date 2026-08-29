// lib/platform/capture_ports/stability_port_web.dart
//
// WEB implementation of [StabilityPort]: `devicemotion` fed into the Dart port
// of the native dwell gate (stability_math.dart).
//
// Signal mapping — the only place web and native differ, and each difference is
// forced by the DOM API, not chosen:
//
//  • **gyro** ← `DeviceMotionEvent.rotationRate`, which is in **degrees/second**
//    (the native gyroscope is rad/s). Converted here, once. A browser that
//    reports no `rotationRate` at all (rare, but real on some Android WebViews)
//    contributes 0 rad/s, which is the honest reading for "no gyro data" and
//    leaves the accel half of the AND doing the gating.
//  • **linear accel** ← `acceleration` when the browser separates gravity;
//    otherwise `accelerationIncludingGravity` minus the [GravityEstimator]'s
//    low-passed gravity vector — the same fallback the native side uses on
//    devices without TYPE_LINEAR_ACCELERATION.
//  • **timestamps** ← `performance.now()`, matching the still-capture and
//    orientation ports so the dwell window and the frame join key share a clock.
//
// Thresholds, dwell, hysteresis and the score formula are the ported native
// ones, so "stable" means the same physical steadiness on both platforms.
import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;

import 'stability_math.dart';
import 'stability_port.dart';
import 'web_motion_permission.dart';

/// Selected by the conditional import in lib/platform/stability_channel.dart on
/// a web build. The channel argument exists only to match the shared factory
/// signature.
StabilityPort createStabilityPort([EventChannel? channel]) =>
    const WebStabilityPort();

/// `devicemotion`-backed [StabilityPort].
class WebStabilityPort implements StabilityPort {
  const WebStabilityPort();

  /// Score emissions are throttled to ~10 Hz, matching the native stream.
  static const Duration scoreInterval = Duration(milliseconds: 100);

  /// No `devicemotion` within this window means the device has no motion
  /// sensors (desktop) or they are policy-blocked — an error, not silence.
  static const Duration firstSampleTimeout = Duration(seconds: 3);

  @override
  Stream<StabilityEvent> events({
    double gyroThresh = StabilityConfig.defaultGyroThreshRadS,
    double accelThresh = StabilityConfig.defaultAccelThreshG,
    int dwellMs = StabilityConfig.defaultDwellMs,
  }) {
    if (!deviceMotionSupported || motionPermissionStatus() != 'granted') {
      return Stream<StabilityEvent>.error(
        PlatformException(
          code: 'STABILITY_UNAVAILABLE',
          message: deviceMotionSupported
              ? 'Motion access has not been granted for this site.'
              : 'This browser does not report device motion.',
        ),
      );
    }

    final gate = StabilityGate(
      StabilityConfig.build(
        gyroThreshRadS: gyroThresh,
        accelThreshG: accelThresh,
        dwellMs: dwellMs,
      ),
    );
    final gravity = GravityEstimator();
    late final StreamController<StabilityEvent> controller;
    JSFunction? listener;
    Timer? watchdog;
    var lastScoreMs = 0.0;

    void onMotion(web.DeviceMotionEvent e) {
      watchdog?.cancel();
      watchdog = null;
      final nowMs = web.window.performance.now();
      final ts = (nowMs * 1000000).round();

      final rate = e.rotationRate;
      final gyroMag = rate == null
          ? 0.0
          : StabilityMath.magnitude(
                _finite(rate.alpha),
                _finite(rate.beta),
                _finite(rate.gamma),
              ) *
              _degToRad;

      final linear = e.acceleration;
      final double accelMag;
      if (linear != null && linear.x != null) {
        accelMag = StabilityMath.magnitude(
          _finite(linear.x),
          _finite(linear.y),
          _finite(linear.z),
        );
      } else {
        final raw = e.accelerationIncludingGravity;
        accelMag = raw == null
            ? 0.0
            : gravity.linearMagnitude(
                _finite(raw.x),
                _finite(raw.y),
                _finite(raw.z),
                ts,
              );
      }

      if (controller.isClosed) return;
      // Feed both halves at the same timestamp — unlike Android's two
      // independent sensor streams, `devicemotion` carries them together.
      final t1 = gate.onGyro(gyroMag, ts);
      final t2 = gate.onLinearAccel(accelMag, ts);
      for (final t in [t1, t2]) {
        if (t == null) continue;
        controller.add(StabilityStateEvent(
          stable: t.stable,
          gyroMag: t.gyroMag,
          linAccelMag: t.linAccelMag,
          timestampNs: t.timestampNs,
        ));
        if (t.stable) {
          controller.add(StabilityTriggerEvent(timestampNs: t.timestampNs));
        }
      }

      if (nowMs - lastScoreMs >= scoreInterval.inMilliseconds) {
        lastScoreMs = nowMs;
        final reading = gate.currentReading();
        if (reading != null) {
          controller.add(StabilityScoreEvent(
            score: reading.score,
            gyroMag: reading.gyroMag,
            linAccelMag: reading.linAccelMag,
            timestampNs: ts,
          ));
        }
      }
    }

    controller = StreamController<StabilityEvent>(
      onListen: () {
        listener = ((web.DeviceMotionEvent e) => onMotion(e)).toJS;
        web.window.addEventListener('devicemotion', listener);
        watchdog = Timer(firstSampleTimeout, () {
          if (controller.isClosed) return;
          controller.addError(
            PlatformException(
              code: 'STABILITY_UNAVAILABLE',
              message: 'No device-motion events on this device.',
            ),
          );
        });
      },
      onCancel: () {
        watchdog?.cancel();
        final l = listener;
        if (l != null) {
          web.window.removeEventListener('devicemotion', l);
          listener = null;
        }
      },
    );
    return controller.stream;
  }
}

const double _degToRad = 3.141592653589793 / 180.0;

double _finite(double? v) => (v == null || !v.isFinite) ? 0.0 : v;
