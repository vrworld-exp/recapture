// lib/platform/capture_ports/orientation_port_web.dart
//
// WEB implementation of [OrientationPort]: `DeviceOrientationEvent` converted
// into the app's body-to-world quaternion (orientation_math.dart) and smoothed
// by the Dart port of the native `OrientationFilter`, so band gating, ring
// progress and the Meshy `[60, 180)` window behave the same in a browser as on
// a phone.
//
// Three things this file is careful about, each a real browser failure the app
// would otherwise show as a dead shutter:
//
//  1. **iOS Safari's permission handshake.** `deviceorientation` simply never
//     fires until `DeviceOrientationEvent.requestPermission()` has been granted
//     from a user gesture. A denied/unasked state errors the stream with
//     `SENSOR_UNAVAILABLE` immediately rather than waiting forever.
//  2. **Desktop browsers have no sensors at all.** The listener attaches fine
//     and no event ever arrives, so a watchdog errors the stream after
//     [_firstSampleTimeout] instead of leaving the guide permanently "loading".
//  3. **Screen rotation.** The event angles are always in the device's natural
//     frame, so `screen.orientation.angle` is composed in
//     ([deviceOrientationQuaternion] documents why that leaves camera tilt
//     invariant).
//
// One shared DOM listener serves every subscriber ([_OrientationHub]); each
// subscriber runs its own filter instance because tau is per-call.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;

import 'orientation_math.dart';
import 'orientation_port.dart';
import 'web_motion_permission.dart';

/// Selected by the conditional import in lib/platform/imu_rotation_channel.dart
/// on a web build. The channel arguments exist only to satisfy the shared
/// factory signature; a browser has no platform channels to talk to.
OrientationPort createOrientationPort({
  EventChannel? rotationChannel,
  EventChannel? orientationChannel,
}) =>
    const WebOrientationPort();

/// `deviceorientation`-backed [OrientationPort].
class WebOrientationPort implements OrientationPort {
  const WebOrientationPort();

  @override
  Stream<ImuRotationSample> samples({int rateHz = 100}) =>
      _OrientationHub.instance.subscribe().map(
            (s) => ImuRotationSample(
              qx: s.q.x,
              qy: s.q.y,
              qz: s.q.z,
              qw: s.q.w,
              // The browser exposes no accuracy value. `absolute` (Earth-
              // referenced, i.e. magnetometer-backed) is the closest honest
              // proxy: high when true, low when the frame is device-arbitrary.
              accuracy: s.absolute ? 3 : 1,
              timestampNs: s.timestampNs,
            ),
          );

  @override
  Stream<SmoothedOrientation> orientation({
    int rateHz = 100,
    double tauMs = 100.0,
  }) {
    final filter = DartOrientationFilter(
      tauNs: (tauMs < 0 ? 0.0 : tauMs) * 1000000.0,
    );
    return _OrientationHub.instance.subscribe().map((s) {
      final q = filter.filter(s.q.components, s.timestampNs);
      final e = OrientationMath.toEuler(q[0], q[1], q[2], q[3]);
      return SmoothedOrientation(
        yaw: e[0],
        pitch: e[1],
        roll: e[2],
        qx: q[0],
        qy: q[1],
        qz: q[2],
        qw: q[3],
        timestampNs: s.timestampNs,
      );
    });
  }
}

/// One raw `deviceorientation` reading, already in the app's frame.
class _RawOrientation {
  const _RawOrientation(this.q, this.timestampNs, this.absolute);

  final DeviceQuaternion q;
  final int timestampNs;
  final bool absolute;
}

/// How long to wait for the FIRST event before declaring the sensor absent.
/// Phones deliver at ~60 Hz, so anything past this is a desktop browser, a
/// blocked sensor, or an iframe without the `accelerometer;gyroscope` permission
/// policy — all of which must surface as an error, not as silence.
const Duration _firstSampleTimeout = Duration(seconds: 3);

/// Owns the single `window.deviceorientation` listener and fans it out.
class _OrientationHub {
  _OrientationHub._();

  static final _OrientationHub instance = _OrientationHub._();

  final _controller = StreamController<_RawOrientation>.broadcast(
    onListen: () => instance._attach(),
    onCancel: () => instance._detachIfIdle(),
  );

  JSFunction? _listener;
  Timer? _watchdog;
  bool _sawSample = false;

  Stream<_RawOrientation> subscribe() {
    final status = motionPermissionStatus();
    if (status != 'granted') {
      // 'unavailable' (no DeviceOrientationEvent), 'notRequested' or 'denied'
      // on iOS Safari. Identical shape to the native absent-sensor error so
      // currentTiltProvider's existing onError path handles it unchanged.
      return Stream<_RawOrientation>.error(
        PlatformException(
          code: 'SENSOR_UNAVAILABLE',
          message: status == 'unavailable'
              ? 'This browser does not report device orientation.'
              : 'Motion access has not been granted for this site.',
        ),
      );
    }
    return _controller.stream;
  }

  void _attach() {
    if (_listener != null) return;
    _sawSample = false;
    _listener = ((web.DeviceOrientationEvent e) => _onEvent(e)).toJS;
    web.window.addEventListener('deviceorientation', _listener);
    _watchdog = Timer(_firstSampleTimeout, () {
      if (_sawSample) return;
      _controller.addError(
        PlatformException(
          code: 'SENSOR_UNAVAILABLE',
          message: 'No device-orientation events on this device.',
        ),
      );
    });
  }

  void _detachIfIdle() {
    if (_controller.hasListener) return;
    _watchdog?.cancel();
    _watchdog = null;
    final listener = _listener;
    if (listener != null) {
      web.window.removeEventListener('deviceorientation', listener);
      _listener = null;
    }
  }

  void _onEvent(web.DeviceOrientationEvent e) {
    final beta = e.beta;
    final gamma = e.gamma;
    // A sample with neither tilt axis is not a pose — some browsers fire one
    // empty event on subscribe. `alpha` alone may legitimately be null (no
    // magnetometer): yaw degrades, tilt does not, so it defaults to 0.
    if (beta == null && gamma == null) return;
    _sawSample = true;
    _watchdog?.cancel();
    _watchdog = null;

    final q = deviceOrientationQuaternion(
      alphaDeg: e.alpha ?? 0,
      betaDeg: beta ?? 0,
      gammaDeg: gamma ?? 0,
      screenAngleDeg: _screenAngleDegrees(),
    );
    if (_controller.isClosed) return;
    _controller.add(
      _RawOrientation(q, _nowNanos(), e.absolute),
    );
  }
}

/// `performance.now()` (sub-millisecond, monotonic since page load) in
/// nanoseconds — the same units and the same monotonic guarantee the native
/// CLOCK_MONOTONIC timestamps carry, so the sensor/frame join key stays
/// meaningful on web.
int _nowNanos() => (web.window.performance.now() * 1000000).round();

/// `screen.orientation.angle`, with the legacy `window.orientation` fallback
/// for older iOS Safari. Returns 0 when neither exists (desktop).
double _screenAngleDegrees() {
  try {
    final screen = web.window.screen;
    if (screen.has('orientation')) {
      return screen.orientation.angle.toDouble();
    }
  } catch (_) {
    // Some embedders throw on `screen.orientation` access; fall through.
  }
  if (web.window.has('orientation')) {
    final legacy = web.window.getProperty<JSAny?>('orientation'.toJS);
    if (legacy.isA<JSNumber>()) return (legacy as JSNumber).toDartDouble;
  }
  return 0;
}
