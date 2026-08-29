// lib/utils/platform_name.dart
//
// The ONE place the app turns "which platform am I on" into the analytics /
// manifest platform token. Before this existed the ternary
// `defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android'` was inlined
// at ~40 call sites, every one of which silently reported a browser as
// `android` (or `ios`) because `defaultTargetPlatform` on web reports the HOST
// OS, not "web". `kIsWeb` is checked FIRST for exactly that reason.
//
// The token vocabulary is shared with the backend analytics schema
// (`CLIENT_PLATFORMS = ['ios', 'android', 'web']` in
// recapture-api/src/validation/analyticsSchemas.ts) — keep the two in sync.
import 'package:flutter/foundation.dart';

/// `'web' | 'ios' | 'android'` for the running build.
///
/// Web wins over [defaultTargetPlatform]: a Flutter web build running in mobile
/// Safari reports `TargetPlatform.iOS`, which is true of the host OS but false
/// of the *runtime* — and every consumer here (analytics `device_type`, the
/// capture manifest's `device.platform`) means the runtime.
String get appPlatformName {
  if (kIsWeb) return 'web';
  return defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
}
