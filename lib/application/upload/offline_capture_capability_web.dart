// lib/application/upload/offline_capture_capability_web.dart
//
// Browser: FALSE. Web capture is online-only, exactly as before this feature —
// there is no durable place to keep a capture's photos between visits, and no
// background upload. With this false the pending-capture store is never opened,
// the coordinator never runs, and no offline UI is shown.
const bool kCanCaptureOffline = false;
