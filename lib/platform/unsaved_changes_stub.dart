// lib/platform/unsaved_changes_stub.dart
//
// Compile-time fallback for the browser's own "leave site?" prompt. Native
// builds get this: there is no tab to close, and the in-app back guard is the
// whole story there.
void setUnsavedChangesWarning(bool unsaved) {}
