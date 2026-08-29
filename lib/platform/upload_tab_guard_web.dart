// lib/platform/upload_tab_guard_web.dart
//
// WEB half of the "don't close the tab mid-upload" guard.
//
// Background upload does not exist in a browser: upload_background_session.dart
// and upload_foreground_service.dart both report unsupported for `kIsWeb`, which
// is correct, and there is nothing to replace them with — a Service Worker
// cannot resume a presigned multipart upload the page started. So the honest
// contract on web is "the tab must stay open", and the resume path is
// "re-open and retry", not "it continued in the background".
//
// This registers the browser's own last line of defence for that: a
// `beforeunload` handler that makes the browser show its native "Leave site?"
// confirmation while parts are still in flight. The message text is fixed by
// the browser (no site-supplied copy is honoured any more) — the human-readable
// explanation lives in the uploading screen's hint beside it.
import 'dart:js_interop';

import 'package:web/web.dart' as web;

JSFunction? _listener;

void setUploadInFlight(bool inFlight) {
  if (inFlight) {
    if (_listener != null) return;
    _listener = ((web.BeforeUnloadEvent event) {
      // Both are required across browsers: `preventDefault` is the modern
      // signal, a non-empty `returnValue` the legacy one.
      event.preventDefault();
      event.returnValue = 'An upload is still in progress.';
    }).toJS;
    web.window.addEventListener('beforeunload', _listener);
    return;
  }
  final listener = _listener;
  if (listener == null) return;
  web.window.removeEventListener('beforeunload', listener);
  _listener = null;
}
