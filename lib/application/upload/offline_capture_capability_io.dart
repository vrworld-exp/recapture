// lib/application/upload/offline_capture_capability_io.dart
//
// Native (Android/iOS): TRUE. The capture pipeline writes its frames into
// app-scoped storage and the packed bundle lives under app documents, so a
// finished capture can wait on the phone and upload later.
const bool kCanCaptureOffline = true;
