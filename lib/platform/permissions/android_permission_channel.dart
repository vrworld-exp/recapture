// lib/platform/permissions/android_permission_channel.dart
import 'package:flutter/services.dart';

import '../../utils/constants.dart';

/// Logical permission keys understood by the native Android channel. These MUST
/// match the keys in PermissionMapper.kt (`com.mayasabhaxr.recapture/permissions`).
abstract final class AndroidPermissionKeys {
  static const String camera = 'camera';
  static const String storage = 'storage';
  static const String motion = 'motion';
  // Implemented natively for completeness; the app uses raw-IMU `motion` instead.
  static const String activityRecognition = 'activityRecognition';
}

/// Native status strings the channel returns. The caller maps these to the
/// app's `AppPermissionStatus` (kept as strings here so this wrapper has no
/// dependency on the UI enum).
abstract final class AndroidPermissionStatus {
  static const String granted = 'granted';
  static const String denied = 'denied';
  static const String permanentlyDenied = 'permanentlyDenied';
  static const String restricted = 'restricted';
  static const String limited = 'limited';
}

/// Thin Dart wrapper over the native Android permissions [MethodChannel].
///
/// `check` reports status without prompting; `request` triggers the OS dialog
/// and resolves once the native `onRequestPermissionsResult` callback fires.
/// All failure modes (no Activity, in-flight, teardown, plugin missing) degrade
/// to [AndroidPermissionStatus.denied] so the UI shows a re-promptable state and
/// never crashes — consistent with the gate re-checking on resume.
class AndroidPermissionChannel {
  const AndroidPermissionChannel(
      [this._channel = const MethodChannel(AppConfig.channelPermissions)]);

  final MethodChannel _channel;

  /// Current status of [permission] without prompting.
  Future<String> check(String permission) =>
      _invoke('check', permission);

  /// Prompts for [permission] (where applicable) and resolves with the
  /// aggregated status when the OS callback fires.
  Future<String> request(String permission) =>
      _invoke('request', permission);

  /// Launches this app's settings page — the recovery path for a
  /// permanently-denied permission. Returns whether the screen launched; it
  /// never reports the user's choice (the gate re-checks on resume). Any
  /// failure (no Activity / unresolvable / plugin missing) returns false so the
  /// Dart layer can show its manual-instructions fallback.
  Future<bool> openAppSettings() async {
    try {
      final launched = await _channel.invokeMethod<bool>('openAppSettings');
      return launched ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<String> _invoke(String method, String permission) async {
    try {
      final status = await _channel.invokeMethod<String>(
        method,
        <String, dynamic>{'permission': permission},
      );
      return status ?? AndroidPermissionStatus.denied;
    } on PlatformException {
      // NO_ACTIVITY / ALREADY_IN_FLIGHT / ACTIVITY_DESTROYED / BAD_ARGS.
      return AndroidPermissionStatus.denied;
    } on MissingPluginException {
      // Channel not registered (e.g. a unit-test host with no native side).
      return AndroidPermissionStatus.denied;
    }
  }
}
