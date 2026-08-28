// lib/presentation/screens/projects/model_viewer_load_probe.dart
//
// WEB-ONLY seam for ModelRenderView's loading skin.
//
// On mobile the `<model-viewer>` page reports its load lifecycle over a
// JavascriptChannel. On web that whole mechanism is structurally impossible:
// model_viewer_plus injects its page via `innerHTML` (scripts never execute)
// and exposes no channel/controller API there. But the Flutter web app and the
// injected `<model-viewer>` element share ONE browser document — so the app can
// simply watch the element's own `loaded` property from Dart.
//
// This file is the conditional-import switch; the real DOM code lives in the
// `_web` variant and never reaches a mobile build.
export 'model_viewer_load_probe_stub.dart'
    if (dart.library.js_interop) 'model_viewer_load_probe_web.dart';
