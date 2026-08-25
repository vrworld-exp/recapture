// lib/native/sensor_stream.dart
import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../utils/constants.dart';
import 'event_channel.dart';

/// Thrown by [SensorStreamPayload.fromMap] when a native event cannot be decoded
/// (wrong root type, missing/invalid `timestamp`, or a malformed sub-map). It is
/// caught per-event by [SensorStreamChannel] so a single bad frame is skipped
/// rather than terminating the live sensor subscription.
class SensorParseException implements Exception {
  const SensorParseException(this.message);

  final String message;

  @override
  String toString() => 'SensorParseException: $message';
}

/// Device orientation angles in degrees (mirrors Web DeviceOrientationEvent).
final class OrientationAngles {
  const OrientationAngles({
    required this.alpha,
    required this.beta,
    required this.gamma,
  });

  final double alpha;
  final double beta;
  final double gamma;
}

/// Raw accelerometer reading in m/s².
final class AccelerometerVector {
  const AccelerometerVector({
    required this.x,
    required this.y,
    required this.z,
  });

  final double x;
  final double y;
  final double z;
}

/// Payload emitted on every sensor tick from the native IMU pipeline.
final class SensorStreamPayload {
  const SensorStreamPayload({
    required this.timestamp,
    required this.orientation,
    required this.accelerometer,
    required this.deviceMotionSupported,
  });

  /// Decodes a raw native event. Throws [SensorParseException] (never a raw
  /// `TypeError`) on a malformed event, so callers can isolate a bad frame.
  /// Well-formed events decode exactly as before: missing sub-maps default to
  /// zeros, and int-valued numbers from the standard codec coerce to double.
  factory SensorStreamPayload.fromMap(dynamic raw) {
    if (raw is! Map) {
      throw SensorParseException('Expected a Map event, got ${raw.runtimeType}');
    }
    final ts = raw['timestamp'];
    if (ts is! num) {
      throw const SensorParseException('Missing or non-numeric "timestamp"');
    }
    final orient = _subMap(raw['orientation'], 'orientation');
    final accel = _subMap(raw['accelerometer'], 'accelerometer');
    return SensorStreamPayload(
      timestamp: ts.toInt(),
      orientation: OrientationAngles(
        alpha: (orient['alpha'] as num? ?? 0).toDouble(),
        beta: (orient['beta'] as num? ?? 0).toDouble(),
        gamma: (orient['gamma'] as num? ?? 0).toDouble(),
      ),
      accelerometer: AccelerometerVector(
        x: (accel['x'] as num? ?? 0).toDouble(),
        y: (accel['y'] as num? ?? 0).toDouble(),
        z: (accel['z'] as num? ?? 0).toDouble(),
      ),
      deviceMotionSupported: (raw['deviceMotionSupported'] as bool?) ?? false,
    );
  }

  /// A nested sub-map (`orientation`/`accelerometer`): absent ⇒ empty (zeros, as
  /// before); present-but-not-a-Map ⇒ [SensorParseException] (was a `TypeError`).
  static Map<dynamic, dynamic> _subMap(dynamic value, String key) {
    if (value == null) return const {};
    if (value is Map) return value;
    throw SensorParseException('Field "$key" must be a Map, got ${value.runtimeType}');
  }

  final int timestamp;
  final OrientationAngles orientation;
  final AccelerometerVector accelerometer;
  final bool deviceMotionSupported;
}

/// Typed [NativeEventChannel] that streams [SensorStreamPayload] from the
/// native IMU sensor pipeline.
class SensorStreamChannel extends NativeEventChannel<SensorStreamPayload> {
  SensorStreamChannel()
      : super(AppConfig.channelSensors, SensorStreamPayload.fromMap);

  /// Per-event parse-error isolation: a single malformed native frame is dropped
  /// (logged in debug) instead of terminating the subscription — a transient
  /// platform glitch can't kill the live sensor feed. Real channel errors
  /// (e.g. `PlatformException` from sensor hardware) still propagate downstream;
  /// only [MissingPluginException] is swallowed (by [rawStream]).
  @override
  Stream<SensorStreamPayload> get stream => rawStream.transform(
        StreamTransformer<dynamic, SensorStreamPayload>.fromHandlers(
          handleData: (raw, sink) {
            try {
              sink.add(SensorStreamPayload.fromMap(raw));
            } on SensorParseException catch (e) {
              if (kDebugMode) {
                developer.log(e.message, name: 'SensorStream');
              }
            }
          },
        ),
      );
}
