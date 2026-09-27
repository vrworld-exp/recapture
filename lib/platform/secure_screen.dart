// lib/platform/secure_screen.dart
//
// Keeps a screen out of screenshots and screen recordings, where the platform
// allows it.
//
// ANDROID ONLY, AND SAYS SO. FLAG_SECURE on the window blanks screenshots,
// recordings and the recents thumbnail. iOS has no supported API that blocks a
// screenshot (it can only report one after the fact), and a browser has none
// at all — so on those this is a no-op, and the owner's QR screen relies on
// drawing the square small instead. A phone camera pointed at the display
// defeats every one of these; the counted A4 download is the real control.
//
// Never throws: a missing channel (tests, an old build) must not take the
// screen down with it.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/constants.dart';

abstract final class SecureScreen {
  static const _channel = MethodChannel(AppConfig.channelSecureScreen);

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Blocks screenshots until [disable] is called.
  static Future<void> enable() => _call('enable');

  /// Lifts the block again. Call it from the screen's `dispose`.
  static Future<void> disable() => _call('disable');

  static Future<void> _call(String method) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>(method);
    } catch (_) {
      // No channel on this build — nothing to guard with.
    }
  }
}
