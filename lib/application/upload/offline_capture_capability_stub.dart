// lib/application/upload/offline_capture_capability_stub.dart
//
// Compile-time fallback for the offline-capture capability. The real variant is
// chosen by conditional import in `offline_capture_capability.dart`.
//
// FALSE HERE: a target nobody has named yet gets today's online-only capture,
// which works everywhere. Guessing generously would hand that target a queue of
// captures it has no file system to keep.
const bool kCanCaptureOffline = false;
