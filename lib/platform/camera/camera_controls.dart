// lib/platform/camera/camera_controls.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../utils/constants.dart';

/// The supported range for manual focus distance, as reported by the device.
///
/// The UNIT is platform-specific — callers should treat this as an opaque range
/// (clamp [setManualFocusDistance] inputs to `[min, max]`) and not assume a unit:
///  - **Android**: diopters, `[0, minFocusDistance]` where 0 = infinity (far).
///  - **iOS**: a normalized `lensPosition`, `[0, 1]` where 0 ≈ near, 1 ≈ far
///    (NOT diopters — AVFoundation exposes only this normalized position).
@immutable
class FocusDistanceRange {
  const FocusDistanceRange({required this.min, required this.max});

  final double min;
  final double max;
}

/// Device-reported support for the focus/exposure lock controls on the currently
/// bound camera. Used to show/hide UI; all flags default to false (hide).
@immutable
class CameraControlCapabilities {
  const CameraControlCapabilities({
    this.aeLock = false,
    this.awbLock = false,
    this.manualFocus = false,
    this.focusDistanceRange,
  });

  final bool aeLock;
  final bool awbLock;
  final bool manualFocus;
  final FocusDistanceRange? focusDistanceRange;

  static const CameraControlCapabilities none = CameraControlCapabilities();

  factory CameraControlCapabilities.fromMap(Map<String, dynamic> map) {
    final range = (map['focusDistanceRange'] as Map?)?.cast<String, dynamic>();
    return CameraControlCapabilities(
      aeLock: map['aeLock'] == true,
      awbLock: map['awbLock'] == true,
      manualFocus: map['manualFocus'] == true,
      focusDistanceRange: range == null
          ? null
          : FocusDistanceRange(
              min: (range['min'] as num?)?.toDouble() ?? 0.0,
              max: (range['max'] as num?)?.toDouble() ?? 0.0,
            ),
    );
  }
}

/// Dart wrapper for the manual focus / exposure **lock** controls on the native
/// `com.mayasabhaxr.recapture/camera_preview` channel.
///
/// Operates on the camera session owned by the preview side — it shares the
/// channel name but, unlike the preview controller, NEVER registers a method-call
/// handler (that would steal the preview controller's native-push handler).
///
/// Every call degrades gracefully: an unbound camera, an unsupported control, a
/// missing plugin (tests / non-Android) resolve without throwing —
/// [getCapabilities] returns [CameraControlCapabilities.none] and the setters
/// report success=false rather than propagating a [PlatformException].
class CameraControls {
  CameraControls([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel(AppConfig.channelCameraPreview);

  final MethodChannel _channel;

  /// Hardware support for the current session; safe to call any time.
  Future<CameraControlCapabilities> getCapabilities() async {
    try {
      final res = await _channel
          .invokeMapMethod<String, dynamic>('getCameraControlCapabilities');
      if (res == null) return CameraControlCapabilities.none;
      return CameraControlCapabilities.fromMap(res);
    } on PlatformException {
      return CameraControlCapabilities.none;
    } on MissingPluginException {
      return CameraControlCapabilities.none;
    }
  }

  /// Locks/unlocks auto-exposure (`CONTROL_AE_LOCK`). Returns whether it applied.
  Future<bool> setExposureLock(bool locked) =>
      _invokeVoid('setExposureLock', {'locked': locked});

  /// Locks/unlocks auto white balance (`CONTROL_AWB_LOCK`), if supported.
  Future<bool> setAutoWhiteBalanceLock(bool locked) =>
      _invokeVoid('setAutoWhiteBalanceLock', {'locked': locked});

  /// Holds the current focus (no hunting); `false` resumes auto-focus and clears
  /// any manual focus distance.
  Future<bool> setFocusLocked(bool locked) =>
      _invokeVoid('setFocusLocked', {'locked': locked});

  /// Sets manual focus distance, in the units of the device-reported
  /// [CameraControlCapabilities.focusDistanceRange] (Android: diopters, 0 =
  /// infinity; iOS: normalized `lensPosition` `[0, 1]`, 0 ≈ near). The native
  /// side clamps to the supported range. Only meaningful when [manualFocus] is
  /// true — pass values within the reported range rather than assuming a unit.
  Future<bool> setManualFocusDistance(double distance) =>
      _invokeVoid('setManualFocusDistance', {'distance': distance});

  /// Restores auto AE/AF/AWB and clears manual options.
  Future<bool> unlockAll() => _invokeVoid('unlockAll', null);

  Future<bool> _invokeVoid(String method, Map<String, dynamic>? args) async {
    try {
      await _channel.invokeMethod<void>(method, args);
      return true;
    } on PlatformException {
      // NO_CAMERA / UNSUPPORTED — defensive no-op, UI should have gated this.
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
