// lib/platform/unsaved_changes.dart
//
// "This form has unsaved changes" — told to the PLATFORM, so the exits the app
// does not own can warn too.
//
// A genuine capability difference, not a layout one, so this is a conditional
// import rather than a width check: a browser tab can be closed out from under a
// half-filled form and a phone screen cannot. Native compiles to a no-op; the
// in-app `PopScope` guard is the whole story there.
//
// One seam, two implementations — never a `kIsWeb` branch inside the editor,
// which would put a web-only API in a file the APK also compiles.
export 'unsaved_changes_stub.dart'
    if (dart.library.io) 'unsaved_changes_io.dart'
    if (dart.library.js_interop) 'unsaved_changes_web.dart';
