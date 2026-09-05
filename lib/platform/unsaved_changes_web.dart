// lib/platform/unsaved_changes_web.dart
//
// The browser's own "Leave site? Changes you made may not be saved." prompt.
//
// This is the one exit the app cannot intercept itself. `PopScope` covers the
// in-app back button and go_router's `onExit` covers the browser's back button,
// but CLOSING THE TAB never reaches Dart at all — the only hook is
// `beforeunload`, and the only thing a page may do from it is ask the browser to
// show its own fixed prompt. The wording is the browser's; we cannot supply it.
//
// Written against package:web (dart:html is deprecated in this SDK), and only
// ever compiled for the web target — selected by the conditional import in
// unsaved_changes.dart.
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// The live listener, or null when nothing is unsaved.
///
/// Removed rather than left attached-and-inert: a `beforeunload` listener that
/// exists at all disqualifies the page from the browser's back/forward cache in
/// several engines, which would make every ordinary navigation slower for a
/// warning that is not currently wanted.
web.EventListener? _listener;

void setUnsavedChangesWarning(bool unsaved) {
  if (unsaved) {
    if (_listener != null) return;
    _listener = ((web.Event event) {
      // Both halves are required, and which one works depends on the engine:
      // preventDefault() is the modern spec, returnValue is what older WebKit
      // and Firefox still read.
      event.preventDefault();
      (event as web.BeforeUnloadEvent).returnValue = '';
    }).toJS;
    web.window.addEventListener('beforeunload', _listener);
    return;
  }

  if (_listener == null) return;
  web.window.removeEventListener('beforeunload', _listener);
  _listener = null;
}
