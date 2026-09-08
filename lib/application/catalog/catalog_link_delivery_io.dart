// lib/application/catalog/catalog_link_delivery_io.dart
//
// Native public-link actions.
//
// SHARE is the share sheet (share_plus) — the idiom for "send my customers this
// link" on a phone, and the one place from which the user can put it in
// WhatsApp, print it, or mail it to whoever makes their stickers.
//
// OPEN launches the device browser.
//
// ⚠ THIS USED TO BE UNSUPPORTED, and the reason it changed is worth recording.
// The original note said opening a link needed url_launcher, that the catalog
// brief forbade a new package without justification, and that the share sheet
// already reached every app that could open a URL — so the button was hidden
// rather than shown doing nothing. That reasoning was sound for the OWNER's
// publish screen, where the user is sending their menu to somebody else.
//
// It stopped being sound for the rep's published-standees list, where the whole
// point of tapping a row is to LOOK AT the menu you just put live. "Share it to
// another app and open it from there" is not a preview; it is a workaround. So
// url_launcher is now a dependency, deliberately, and the justification is this
// paragraph.
//
// `externalApplication` rather than an in-app view: the menu is a real customer-
// facing page on another origin, and it should open where a customer would see
// it, with the browser's own chrome and back behaviour.
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

const bool kCanShareLink = true;
const bool kCanOpenLink = true;

Future<void> shareLinkExternally(String url, {String? subject}) =>
    SharePlus.instance.share(ShareParams(
      text: url,
      subject: subject,
    ));

Future<void> openLinkExternally(String url) async {
  // THROWS rather than returning false into a caller that ignores it. Every
  // call site here reports failure with one mapped sentence, and a silent
  // no-op is the version the user reads as a dead button.
  final launched = await launchUrl(
    Uri.parse(url),
    mode: LaunchMode.externalApplication,
  );
  if (!launched) {
    throw UnsupportedError('No app on this device could open the link.');
  }
}
