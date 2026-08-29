// lib/platform/capture_ports/web_motion_permission.dart
//
// WEB ONLY (imported exclusively from `*_web.dart` port implementations).
//
// iOS Safari 13+ gates `deviceorientation` / `devicemotion` behind
// `DeviceOrientationEvent.requestPermission()`, which MUST be called from
// inside a user gesture and cannot be re-prompted once denied. Every other
// browser delivers the events with no prompt at all.
//
// That asymmetry is the whole reason this file exists: the app models motion as
// a real permission (`AppPermissionType.motion`) so the Maya/Meshy hard gate can
// show an honest "motion access is required" screen with a retry that
// re-triggers the gesture-gated request — instead of a shutter that is silently
// dead forever.
//
// The resolved state is cached because a second `requestPermission()` call
// after a denial resolves 'denied' without prompting, and because the sensor
// ports need to know the answer without prompting at all.
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Whether this browser implements the iOS-style permission handshake.
///
/// False on Chrome/Android and desktop, where the sensors need no prompt.
bool get motionPermissionPromptRequired {
  final ctor = _deviceOrientationEventCtor;
  if (ctor == null) return false;
  return ctor.has('requestPermission');
}

/// Whether `DeviceOrientationEvent` exists at all in this browser.
bool get deviceOrientationSupported => _deviceOrientationEventCtor != null;

/// Whether `DeviceMotionEvent` exists at all in this browser.
bool get deviceMotionSupported => _globalCtor('DeviceMotionEvent') != null;

/// The last resolved answer: `'granted' | 'denied' | null` (never asked).
///
/// Browsers with no prompt resolve to `'granted'` the first time anything asks.
String? get cachedMotionPermission => _cached;

String? _cached;

/// Resolves the motion permission WITHOUT prompting.
///
/// Returns `'granted'` where no prompt exists, the cached answer once one has
/// been resolved, and `'notRequested'` on a prompt-required browser that has
/// not been asked yet. Never triggers the iOS dialog — [requestMotionPermission]
/// is the only thing that may, and only from a user gesture.
String motionPermissionStatus() {
  if (!deviceOrientationSupported) return 'unavailable';
  if (!motionPermissionPromptRequired) return 'granted';
  return _cached ?? 'notRequested';
}

/// Prompts for motion access (iOS Safari) and resolves the answer.
///
/// MUST be reached from a user gesture — Safari rejects the promise otherwise,
/// which is reported here as `'denied'` so the caller shows its recovery UI
/// rather than hanging. On every other browser this resolves `'granted'`
/// immediately with no dialog.
Future<String> requestMotionPermission() async {
  if (!deviceOrientationSupported) return 'unavailable';
  if (!motionPermissionPromptRequired) {
    _cached = 'granted';
    return 'granted';
  }
  final ctor = _deviceOrientationEventCtor;
  if (ctor == null) return 'unavailable';
  try {
    final result = ctor.callMethod<JSPromise<JSString>>(
      'requestPermission'.toJS,
    );
    final answer = (await result.toDart).toDart;
    _cached = answer == 'granted' ? 'granted' : 'denied';
    return _cached!;
  } catch (_) {
    // Thrown when called outside a user gesture, or in a non-secure context.
    // Deliberately NOT cached: the user can retry from a real gesture.
    return 'denied';
  }
}

/// Test/reset seam — forgets the cached answer (used by the retry path after
/// the user changes Safari's per-site Motion & Orientation setting).
void resetMotionPermissionCache() => _cached = null;

JSObject? get _deviceOrientationEventCtor =>
    _globalCtor('DeviceOrientationEvent');

JSObject? _globalCtor(String name) {
  if (!globalContext.has(name)) return null;
  final value = globalContext.getProperty<JSAny?>(name.toJS);
  return value.isA<JSObject>() ? value as JSObject : null;
}
