// lib/application/catalog/catalog_link_delivery_io.dart
//
// Native public-link actions.
//
// SHARE is the share sheet (share_plus, already in the tree) — the idiom for
// "send my customers this link" on a phone, and the one place from which the
// user can put it in WhatsApp, print it, or mail it to whoever makes their
// stickers.
//
// OPEN is deliberately UNSUPPORTED. Launching an external browser needs
// url_launcher, and the catalog brief forbids a new package without
// justification in the PR. The share sheet already reaches every app that can
// open a URL, so the missing button costs a tap, not a capability — and the
// screen hides it rather than showing one that does nothing.
import 'package:share_plus/share_plus.dart';

const bool kCanShareLink = true;
const bool kCanOpenLink = false;

Future<void> shareLinkExternally(String url, {String? subject}) =>
    SharePlus.instance.share(ShareParams(
      text: url,
      subject: subject,
    ));

Future<void> openLinkExternally(String url) =>
    throw UnsupportedError('Opening a link is not supported on this platform.');
