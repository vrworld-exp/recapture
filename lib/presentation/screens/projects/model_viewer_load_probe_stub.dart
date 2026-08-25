// lib/presentation/screens/projects/model_viewer_load_probe_stub.dart
//
// Non-web variant of the model-viewer load probe: the JavascriptChannel owns
// the load/AR lifecycle on mobile, so there is nothing to poll. Never imported
// directly — always via model_viewer_load_probe.dart.

/// No-op on mobile. Returns a cancel function for signature parity with the
/// web variant; [onLoaded] is never called.
void Function() watchModelViewerLoaded(void Function() onLoaded) => () {};

/// No-op on mobile ([onArReady] is never called) — the JS channel reports AR
/// availability there.
void Function() watchModelViewerArReady(void Function() onArReady) => () {};

/// No-op on mobile — AR is activated over the webview controller there.
void activateModelViewerAr() {}
