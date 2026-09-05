// lib/application/rep/web_dish_camera_stub.dart
//
// Default variant of the browser dish camera. The real one is chosen by
// conditional import in `web_dish_camera.dart`.
//
// UNSUPPORTED HERE, and on `_io` too — this seam exists for exactly one target.
// A phone does not need it: it has the 6-photo RING, driven by the IMU, which
// is a better capture in every way this app cares about. The browser gets this
// because it has `getUserMedia` and no gyroscope, not because it is an
// improvement on anything.
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// A live browser camera, opened for as long as a capture screen is on screen.
///
/// The seam is an INTERFACE rather than free functions because the browser
/// implementation is stateful — a `MediaStream` has to be started, drawn from,
/// and stopped, and leaking one leaves the laptop's camera light on after the
/// rep has moved on.
abstract interface class WebDishCamera {
  /// Begins the preview. Throws [WebDishCameraException] when the browser
  /// refuses — denied permission, no device, or an insecure origin.
  Future<void> start();

  /// The live preview, sized by its parent.
  Widget preview();

  /// Grabs the current frame as JPEG bytes.
  Future<Uint8List> grabFrame();

  /// Stops the stream and releases the device. Safe to call twice.
  Future<void> stop();
}

/// Why the camera would not start, in words a rep can act on.
class WebDishCameraException implements Exception {
  const WebDishCameraException(this.message);

  final String message;

  @override
  String toString() => 'WebDishCameraException: $message';
}

/// Whether this target has a browser camera at all. False everywhere but web.
const bool kHasWebDishCamera = false;

/// Builds the camera for this target.
WebDishCamera createWebDishCamera() =>
    throw UnsupportedError('No browser camera on this platform.');
