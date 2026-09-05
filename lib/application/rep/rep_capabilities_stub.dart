// lib/application/rep/rep_capabilities_stub.dart
//
// Compile-time fallback for the rep surface's two platform capabilities. The
// real variant is chosen by conditional import in `rep_capabilities.dart`.
//
// BOTH READ FALSE HERE, which is the safe default in both directions: a target
// with neither `dart:io` nor `dart:js_interop` renders manual code entry and
// the two non-camera dish sources, and offers nothing that would throw when
// tapped. A capability that is absent costs a tap; one that is present and
// broken costs the rep a visit.
const bool kCanScanQrCode = false;
const bool kCanCaptureDish = false;

Future<String?> scanQrCode() =>
    throw UnsupportedError('No QR scanner on this platform.');
