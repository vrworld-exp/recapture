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
//
// Both real targets now answer true to both — see the `_io` and `_web`
// variants. This file stays false anyway: it exists for the target nobody has
// named yet, and guessing generously on that one's behalf is exactly the
// mistake the comment above describes.
const bool kCanScanQrCode = false;
const bool kCanCaptureDish = false;
