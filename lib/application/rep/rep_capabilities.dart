// lib/application/rep/rep_capabilities.dart
//
// What the rep surface can DO on the target it is running on.
//
// ⚠ CAPABILITIES, READ THROUGH A PROVIDER — NEVER `kIsWeb`.
//
// The two flags are compile-time constants from a conditionally imported
// variant, exposed as ordinary provider state. That indirection is the whole
// point, and it buys two things:
//
//   • The unsupported path is NOT COMPILED IN. `dart:io` cannot reach a web
//     build even by accident, which is the failure `flutter test` can never
//     catch and `flutter build web` catches months later.
//   • ONE widget test asserts BOTH platforms. A `kIsWeb` branch is untestable
//     by construction — the untaken half is not in the test binary at all — so
//     the other target's rendering would be unverifiable from the single
//     `flutter test` run CI does. `test/rep/rep_web_parity_test.dart` overrides
//     this provider and drives both.
//
// It also keeps the structural guard in `test/catalog/web_parity_test.dart`
// happy, which forbids `kIsWeb` across the rep tree for exactly this reason.
//
// The mix is genuinely per-capability, not per-platform: see the three variant
// files for why scan is false on mobile too.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'rep_capabilities_stub.dart'
    if (dart.library.io) 'rep_capabilities_io.dart'
    if (dart.library.js_interop) 'rep_capabilities_web.dart';

/// The rep surface's platform answers, as one value a screen can `watch`.
class RepCapabilities {
  const RepCapabilities({required this.canScan, required this.canCaptureDish});

  /// Whether to OFFER an in-app QR scan at all.
  ///
  /// HIDDEN, never disabled, when false. A disabled button on web is a promise
  /// the browser can never keep and it invites a rep to keep tapping it; the
  /// screen simply leads with manual entry instead, which is present on every
  /// target and is the fallback a damaged or badly-lit sticker needs anyway.
  final bool canScan;

  /// Whether "Capture this dish now" is one of the add-dish sources.
  ///
  /// False in a browser — there is no capture pipeline there, only a camera.
  /// The other two sources work on every target, so a rep at a desk can still
  /// author and publish a whole menu.
  final bool canCaptureDish;

  /// What this build actually compiled in. The default; tests override it.
  static const platform = RepCapabilities(
    canScan: kCanScanQrCode,
    canCaptureDish: kCanCaptureDish,
  );

  /// Neither capability — the shape a browser reports, named for tests that
  /// want the web rendering without caring which target produced it.
  static const none = RepCapabilities(canScan: false, canCaptureDish: false);
}

/// The rep surface's capabilities. Overridden in tests to assert every
/// rendering from one run.
final repCapabilitiesProvider = Provider<RepCapabilities>(
  (ref) => RepCapabilities.platform,
);
