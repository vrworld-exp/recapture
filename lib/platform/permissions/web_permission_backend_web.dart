// lib/platform/permissions/web_permission_backend_web.dart
//
// Browser implementation of the app's permission backend, speaking the same
// native status-string vocabulary the Android channel does so
// `normalizeNativeStatus` maps it unchanged and the permissions screen needs no
// new states.
//
// Per capability:
//
//  • **camera** — `navigator.permissions.query({name: 'camera'})` where it
//    exists (Chrome/Edge). Safari does not implement the camera descriptor and
//    throws, so status degrades to `denied` (re-promptable) rather than
//    guessing. `request` calls `getUserMedia` — the ONLY way to raise the
//    browser's camera prompt — and immediately stops the tracks it was granted
//    so the request does not leave a camera light on. `NotAllowedError` after a
//    site-level block maps to `permanentlyDenied`, because the browser will not
//    prompt again and the recovery really is "change it in site settings".
//
//  • **motion** — iOS Safari's `DeviceOrientationEvent.requestPermission()`
//    handshake (see ../capture_ports/web_motion_permission.dart). Everywhere
//    else the sensors need no prompt, so this is `granted`. This is the
//    permission Maya/Meshy's hard tilt gate depends on: denied here means the
//    shutter stays blocked, which is correct, and the UI must say so rather
//    than silently ungating.
//
//  • **photos** — permission-free on web (a file input needs no grant).
//
// There is no app-settings deep link in a browser, so [webOpenPermissionSettings]
// reports false and the UI falls back to its manual-instructions surface.
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import '../capture_ports/web_motion_permission.dart';
import 'android_permission_channel.dart';

Future<String> webPermissionStatus(String permission) async {
  switch (permission) {
    case AndroidPermissionKeys.camera:
      return _cameraStatus();
    case AndroidPermissionKeys.motion:
      return _mapMotion(motionPermissionStatus());
    case AndroidPermissionKeys.storage:
      // Media access on web is a file input / the capture pipeline itself —
      // there is no OS grant to hold.
      return AndroidPermissionStatus.granted;
    default:
      return AndroidPermissionStatus.denied;
  }
}

Future<String> webPermissionRequest(String permission) async {
  switch (permission) {
    case AndroidPermissionKeys.camera:
      return _requestCamera();
    case AndroidPermissionKeys.motion:
      // MUST be reached from a user gesture on iOS Safari; the permissions
      // screen's button is one, and the retry path re-triggers it.
      return _mapMotion(await requestMotionPermission());
    case AndroidPermissionKeys.storage:
      return AndroidPermissionStatus.granted;
    default:
      return AndroidPermissionStatus.denied;
  }
}

Future<bool> webOpenPermissionSettings() async => false;

String _mapMotion(String status) => switch (status) {
      'granted' => AndroidPermissionStatus.granted,
      // Safari never re-prompts once denied — the only way back is the per-site
      // "Motion & Orientation Access" toggle, which is exactly what
      // `permanentlyDenied` means to the UI.
      'denied' => AndroidPermissionStatus.permanentlyDenied,
      'unavailable' => 'unavailable',
      _ => AndroidPermissionStatus.denied,
    };

/// Reads the camera permission without prompting, where the browser supports it.
Future<String> _cameraStatus() async {
  if (!web.window.isSecureContext) {
    // getUserMedia does not exist off a secure origin, so there is nothing to
    // grant. Reported as unavailable rather than denied: no prompt will help.
    return 'unavailable';
  }
  try {
    final permissions = web.window.navigator.permissions;
    // `query` takes a bare descriptor object; package:web models it as a plain
    // JSObject because the dictionary is open-ended per permission name.
    final descriptor = JSObject()..setProperty('name'.toJS, 'camera'.toJS);
    final result = await permissions.query(descriptor).toDart;
    return switch (result.state) {
      'granted' => AndroidPermissionStatus.granted,
      'denied' => AndroidPermissionStatus.permanentlyDenied,
      _ => AndroidPermissionStatus.denied,
    };
  } catch (_) {
    // Safari (and any browser without the 'camera' descriptor) throws here.
    // `denied` is the honest, re-promptable answer — the real state is only
    // discoverable by calling getUserMedia, which would prompt.
    return AndroidPermissionStatus.denied;
  }
}

/// Raises the browser's camera prompt by briefly opening a stream, then closes
/// it. The capture screen opens its own stream afterwards; leaving this one
/// running would keep the camera indicator lit on a screen showing no preview.
Future<String> _requestCamera() async {
  if (!web.window.isSecureContext) return 'unavailable';
  try {
    final stream = await web.window.navigator.mediaDevices
        .getUserMedia(
          web.MediaStreamConstraints(
            audio: false.toJS,
            video: web.MediaTrackConstraints(facingMode: 'environment'.toJS),
          ),
        )
        .toDart;
    for (final track in stream.getTracks().toDart) {
      track.stop();
    }
    return AndroidPermissionStatus.granted;
  } catch (e) {
    return switch (_errorName(e)) {
      'NotAllowedError' ||
      'SecurityError' =>
        AndroidPermissionStatus.permanentlyDenied,
      // No camera at all: no prompt can fix it, and `restricted` is the app's
      // existing "settings won't help either" state.
      'NotFoundError' ||
      'OverconstrainedError' =>
        AndroidPermissionStatus.restricted,
      _ => AndroidPermissionStatus.denied,
    };
  }
}

String _errorName(Object error) {
  // A DOMException reaches Dart as a JS object; `isA` is the
  // platform-consistent way to narrow it once we know it is one.
  // ignore: invalid_runtime_check_with_js_interop_types
  if (error is! JSAny) return 'UnknownError';
  if (!error.isA<JSObject>()) return 'UnknownError';
  final name = (error as JSObject).getProperty<JSAny?>('name'.toJS);
  return name.isA<JSString>() ? (name as JSString).toDart : 'UnknownError';
}
