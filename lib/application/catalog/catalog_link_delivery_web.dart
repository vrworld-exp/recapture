// lib/application/catalog/catalog_link_delivery_web.dart
//
// Web public-link actions.
//
// OPEN is a new tab, which is what "see my page" means in a browser and needs
// no plugin at all.
//
// SHARE is unsupported: `navigator.share` exists only on some mobile browsers
// and only in a secure context, so a Share button here would work for a
// minority of visitors and silently fail for the rest. Copy link works
// everywhere and is what the screen offers instead.
//
// `noopener,noreferrer` because the opened page is the user's own public
// catalog served from another origin — it has no business holding a handle on
// the authoring app's window.
import 'package:web/web.dart' as web;

const bool kCanShareLink = false;
const bool kCanOpenLink = true;

Future<void> shareLinkExternally(String url, {String? subject}) =>
    throw UnsupportedError('A share sheet does not exist in the browser.');

Future<void> openLinkExternally(String url) async {
  web.window.open(url, '_blank', 'noopener,noreferrer');
}
