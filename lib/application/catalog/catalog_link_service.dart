// lib/application/catalog/catalog_link_service.dart
//
// What the user can DO with the public catalog link.
//
// Three actions, three different stories about platform support, and the screen
// must not guess any of them:
//   • COPY works everywhere. Flutter's own `Clipboard` uses the async clipboard
//     API in a secure context and falls back to `execCommand` where it is
//     missing, so the web path is handled inside the engine rather than by a
//     branch here. The CONFIRMATION is this app's job — a copy with no visible
//     acknowledgement reads as a dead button.
//   • SHARE is the mobile share sheet. There is no equivalent in a browser.
//   • OPEN is a new browser tab. On a phone it would need url_launcher, a new
//     package, so it is not offered there — see catalog_link_delivery_io.dart.
//
// The two capability flags are compile-time constants from the conditionally
// imported delivery, so the screen ASKS rather than testing `kIsWeb`. That
// distinction matters the day a desktop target lands with a different mix.
//
// The URL is `catalog.publicUrl` VERBATIM at every step. Nothing here parses,
// normalises, appends to or rebuilds it: it is what every printed QR resolves
// through, and a client that "tidied" it would break stickers already on
// tables.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'catalog_link_delivery_stub.dart'
    if (dart.library.io) 'catalog_link_delivery_io.dart'
    if (dart.library.js_interop) 'catalog_link_delivery_web.dart';

/// Seam over the public link's actions, so tests can assert what was copied,
/// shared or opened without a clipboard, a share sheet or a browser.
abstract interface class CatalogLinkActions {
  /// Whether a share sheet exists on this platform.
  bool get canShare;

  /// Whether a link can be opened in a new tab/window.
  bool get canOpen;

  Future<void> copy(String url);
  Future<void> share(String url, {String? subject});
  Future<void> open(String url);
}

class PlatformCatalogLinkActions implements CatalogLinkActions {
  const PlatformCatalogLinkActions();

  @override
  bool get canShare => kCanShareLink;

  @override
  bool get canOpen => kCanOpenLink;

  @override
  Future<void> copy(String url) =>
      Clipboard.setData(ClipboardData(text: url));

  @override
  Future<void> share(String url, {String? subject}) =>
      shareLinkExternally(url, subject: subject);

  @override
  Future<void> open(String url) => openLinkExternally(url);
}

/// App-wide public-link actions. Overridden with a fake in tests.
final catalogLinkActionsProvider = Provider<CatalogLinkActions>(
  (ref) => const PlatformCatalogLinkActions(),
);
