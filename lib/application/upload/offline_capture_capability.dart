// lib/application/upload/offline_capture_capability.dart
//
// Whether this build can keep a finished capture on the device and upload it
// later ("offline capture"). Native: yes. Web: no — web capture stays
// online-only, unchanged.
//
// ⚠ A CAPABILITY, READ THROUGH A PROVIDER — NEVER `kIsWeb` (AGENTS.md §Platform
// seams). The flag is a compile-time constant from a conditionally imported
// variant, exposed as provider state, so one widget test can drive both the
// native and the web rendering, and every pending-capture surface (the store,
// the coordinator, the Summary's "Save" button, the card labels, the
// mobile-data toggle) gates on this one provider instead of scattered checks.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'offline_capture_capability_stub.dart'
    if (dart.library.io) 'offline_capture_capability_io.dart'
    if (dart.library.js_interop) 'offline_capture_capability_web.dart';

/// True when this build supports offline capture with deferred upload.
/// Overridden in tests to assert both renderings from one run.
final offlineCaptureCapabilityProvider =
    Provider<bool>((ref) => kCanCaptureOffline);
