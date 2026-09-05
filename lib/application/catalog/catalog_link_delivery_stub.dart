// lib/application/catalog/catalog_link_delivery_stub.dart
//
// Compile-time fallback for the platform-split public-link actions. The real
// implementation is chosen by conditional import in catalog_link_service.dart.
// Both capabilities read false here, so a platform with neither `dart:io` nor
// `dart:js_interop` renders no button rather than one that throws.
const bool kCanShareLink = false;
const bool kCanOpenLink = false;

Future<void> shareLinkExternally(String url, {String? subject}) =>
    throw UnsupportedError('Sharing is not supported on this platform.');

Future<void> openLinkExternally(String url) =>
    throw UnsupportedError('Opening a link is not supported on this platform.');
