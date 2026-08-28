// lib/domain/catalog/business_profile_validators.dart
//
// Field validation and normalisation for the business profile (features 58-60).
//
// Pure Dart, no Flutter — the same discipline as `auth_input_validators.dart`,
// so every rule here is unit-testable without pumping a widget.
//
// The bounds are the BACKEND's, mirrored (`kMaxContact*Length`,
// `catalogSchemas.ts`). Checking them here does not make the server's check
// redundant: it makes the failure land beside the field the user is typing in
// rather than as a 400 over a form they then have to re-read. Where the two
// could ever disagree, the server wins.
import '../entities/business_profile.dart';

/// A pragmatic email shape check: something, an @, something with a dot in it.
///
/// Deliberately loose. The backend stores any string up to 254 characters and
/// nothing in ReCapture sends mail, so this exists to catch a typo — not to
/// adjudicate RFC 5322, which no regex does correctly and which would reject
/// addresses that genuinely work.
final RegExp _emailShape = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// A scheme at the front of a URL (`https://`, `mailto:`, …).
final RegExp _hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:');

/// Something that could plausibly be a host — a dot with label characters on
/// both sides. Used only to decide whether prefixing a scheme is sensible.
final RegExp _looksLikeHost = RegExp(r'^[^\s/]+\.[^\s/]{2,}');

/// The business/storefront name (required).
///
/// This is the ONE required field on the profile: it becomes the public
/// catalog's title, so an empty one is not "not filled in yet", it is a
/// storefront with no name on it.
String? validateCatalogName(String? value) {
  final trimmed = (value ?? '').trim();
  if (trimmed.isEmpty) return 'Give your storefront a name.';
  if (trimmed.length > kMaxCatalogNameLength) {
    return 'Keep this under $kMaxCatalogNameLength characters.';
  }
  return null;
}

/// Every other text field: optional, bounded.
///
/// [label] names the field in the message, because "Too long" over a form of
/// nine inputs does not say which one.
String? validateOptionalLength(String? value, int max, String label) {
  final trimmed = (value ?? '').trim();
  if (trimmed.isEmpty) return null; // clearing a field is legitimate
  if (trimmed.length > max) return 'Keep $label under $max characters.';
  return null;
}

String? validateBusinessName(String? value) =>
    validateOptionalLength(value, kMaxBusinessNameLength, 'the business name');

String? validatePhone(String? value) =>
    validateOptionalLength(value, kMaxContactPhoneLength, 'the phone number');

String? validateAddress(String? value) =>
    validateOptionalLength(value, kMaxContactAddressLength, 'the address');

String? validateEmail(String? value) {
  final trimmed = (value ?? '').trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.length > kMaxContactEmailLength) {
    return 'Keep the email under $kMaxContactEmailLength characters.';
  }
  if (!_emailShape.hasMatch(trimmed)) {
    return 'That does not look like an email address.';
  }
  return null;
}

/// The website, validated against what will actually be STORED.
///
/// The bound is checked on the NORMALISED value, not on what was typed: a
/// 199-character host normalises to 207 characters with `https://` in front of
/// it, and a form that accepts a value the save then rejects is worse than one
/// that never accepted it.
String? validateWebsite(String? value) {
  final normalised = normalizeWebsite(value);
  if (normalised == null) return null;
  if (normalised.length > kMaxContactWebsiteLength) {
    return 'Keep the website under $kMaxContactWebsiteLength characters.';
  }
  return null;
}

String? validateSocial(String? value, String label) =>
    validateOptionalLength(value, kMaxSocialLinkLength, label);

String? validateWhatsapp(String? value) =>
    validateOptionalLength(value, kMaxWhatsappLength, 'the WhatsApp number');

/// The website as it should be STORED, or null when the field is empty.
///
/// A bare `mystore.in` is what people type and is not a link — a public page
/// rendering it verbatim in an `href` resolves it against its own origin. So a
/// scheme is added here, once, at the domain boundary, rather than by whichever
/// consumer happens to notice.
///
/// Only when the value plausibly IS a host: `about me` gets no scheme, because
/// `https://about me` would be a worse lie than the text the user typed. And an
/// existing scheme is never rewritten — a business that deliberately typed
/// `http://` for a site with no TLS keeps it.
String? normalizeWebsite(String? value) {
  final trimmed = (value ?? '').trim();
  if (trimmed.isEmpty) return null;
  if (_hasScheme.hasMatch(trimmed)) return trimmed;
  if (_looksLikeHost.hasMatch(trimmed)) return 'https://$trimmed';
  return trimmed;
}

/// The website as it should be SHOWN — the stored value with the scheme and any
/// trailing slash taken off, which is how a business writes its own address on
/// a card.
///
/// Display only. Never store this: it is not resolvable.
String displayWebsite(String stored) {
  var text = stored.trim();
  text = text.replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '');
  if (text.endsWith('/')) text = text.substring(0, text.length - 1);
  return text;
}

/// Trims [value] and returns null when nothing is left.
///
/// The whole contact block is REPLACED on every save, so "empty" has to become
/// an absent key rather than an empty string — that is what makes clearing a
/// field possible at all.
String? trimToNull(String? value) {
  final trimmed = (value ?? '').trim();
  return trimmed.isEmpty ? null : trimmed;
}
