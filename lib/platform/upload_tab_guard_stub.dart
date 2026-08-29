// lib/platform/upload_tab_guard_stub.dart
//
// Non-web half of the "don't close the tab mid-upload" guard. There is no tab to
// close on Android or iOS, and both have real background-upload paths
// (upload_background_session.dart / upload_foreground_service.dart), so this is
// a genuine no-op rather than a missing feature.
void setUploadInFlight(bool inFlight) {}
