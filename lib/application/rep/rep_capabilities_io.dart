// lib/application/rep/rep_capabilities_io.dart
//
// Native rep capabilities.
//
// CAPTURE is TRUE. The camera pipeline is this app's whole reason to exist on a
// phone — a bespoke `MethodChannel` (see lib/platform/camera), not the `camera`
// plugin — and the rep add-dish flow reuses it completely unmodified.
//
// SCAN is FALSE, on this target too, and that is a real answer rather than an
// oversight. Read the reasoning before flipping it:
//
//   • There is no QR-decoding package in `pubspec.yaml`, and the phase forbids
//     adding one without a written justification.
//   • The camera is a bespoke channel built for the 6-photo capture ring, not a
//     generic preview surface. Decoding in it is new native work on two
//     platforms, not a flag.
//   • The rep's OS camera ALREADY scans the standee. It opens
//     `{PUBLIC_RESOLVER_BASE_URL}/r/{code}`, which for an unassigned code is
//     stage 3's "not live yet" page — and that page carries a one-tap
//     "Activate this code" link straight back into this app with the code
//     prefilled (note J). So the scanning experience exists; it just does not
//     run inside our process.
//
// Keeping it false on BOTH targets is what makes this stage's parity claim
// honest: manual entry is the offered path everywhere, identically. If an
// in-app scanner is ever built, flipping this one constant is the entire client
// change — `rep_web_parity_test.dart` already asserts both renderings.
const bool kCanScanQrCode = false;
const bool kCanCaptureDish = true;

Future<String?> scanQrCode() =>
    throw UnsupportedError('No in-app QR scanner in this build.');
