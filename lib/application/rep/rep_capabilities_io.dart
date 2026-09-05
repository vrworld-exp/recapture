// lib/application/rep/rep_capabilities_io.dart
//
// Native rep capabilities. Both true.
//
// CAPTURE is TRUE. The camera pipeline is this app's whole reason to exist on a
// phone — a bespoke `MethodChannel` (see lib/platform/camera), not the `camera`
// plugin — and the rep add-dish flow reuses it completely unmodified.
//
// SCAN is TRUE as of the scanner stage. It was false for a long time, and the
// reasoning that kept it false is worth keeping because it is what the change
// had to answer:
//
//   • "No QR package, and the phase forbids adding one without a written
//     justification." — The justification now exists, in pubspec.yaml. The
//     deciding argument was that `mobile_scanner` covers android, ios, macos
//     AND web from one call site, so the alternative was not "add a package
//     instead of native work" but "add a package instead of MLKit plus Vision
//     plus a browser story" — three implementations of one screen.
//   • "The camera is a bespoke channel built for the 6-photo ring, not a
//     generic preview surface." — Still true, and untouched. The scanner does
//     not extend that channel; the plugin owns its own short-lived preview and
//     disposes it with the route. Nothing in lib/platform changed.
//   • "The rep's OS camera ALREADY scans the standee." — It does, and that path
//     still works: the resolver's "not live yet" page still deep-links back
//     with `?code=`. What it does not do is work while the rep is already
//     standing in the activation screen, which is where they actually are.
//
// Manual entry stays on every target regardless — a damaged or badly-lit
// sticker needs it, and it is still what the screen leads with.
const bool kCanScanQrCode = true;
const bool kCanCaptureDish = true;
