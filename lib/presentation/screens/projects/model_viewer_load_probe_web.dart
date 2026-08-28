// lib/presentation/screens/projects/model_viewer_load_probe_web.dart
//
// Web variant of the model-viewer load probe. Never imported directly —
// always via model_viewer_load_probe.dart.
//
// Polls the injected `<model-viewer>` element's own `loaded` property (the
// same signal its `load` event keys on, and the one the 07-17 live web
// verification read). Polling — not addEventListener — because the element is
// (re)created by a platform-view factory at a time this widget can't observe,
// and a poll also catches a model that finished loading before the first tick.
//
// The element may sit behind Flutter's platform-view embedding, which on some
// renderer/version combinations hosts content inside an open shadow root that
// `document.querySelector` does not pierce — so the search recurses through
// open shadow roots. Every tick is exception-guarded: a DOM/interop surprise
// must degrade to "no signal" (ModelRenderView's fallback timer then uncovers
// the viewer), never crash the app.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

const _pollInterval = Duration(milliseconds: 300);

/// How long the AR probe keeps polling before giving up. model-viewer
/// resolves `canActivateAR` from a user-agent sniff within its first update
/// cycles, so on any AR-capable browser it flips well inside this window;
/// on a desktop browser it simply never flips and the poll must not run for
/// the lifetime of the screen.
const _arProbeTicks = 66; // ~20s at 300ms

/// Calls [onLoaded] once, when the page's `<model-viewer>` reports `loaded`.
/// Returns a cancel function; cancel is implicit after [onLoaded] fires.
void Function() watchModelViewerLoaded(void Function() onLoaded) {
  final timer = Timer.periodic(_pollInterval, (timer) {
    if (_viewerFlagIsTrue('loaded')) {
      timer.cancel();
      onLoaded();
    }
  });
  return timer.cancel;
}

/// Calls [onArReady] once, when the page's `<model-viewer>` reports
/// `canActivateAR` — the exact gate its own built-in AR button uses. Polled
/// separately from `loaded` because AR support is resolved on model-viewer's
/// own schedule, independent of the model fetch. Gives up quietly on
/// browsers that never support AR (desktop), so the CTA stays hidden there.
/// Returns a cancel function; cancel is implicit after [onArReady] fires.
void Function() watchModelViewerArReady(void Function() onArReady) {
  var ticks = 0;
  final timer = Timer.periodic(_pollInterval, (timer) {
    if (_viewerFlagIsTrue('canActivateAR')) {
      timer.cancel();
      onArReady();
    } else if (++ticks >= _arProbeTicks) {
      timer.cancel();
    }
  });
  return timer.cancel;
}

/// Asks the page's `<model-viewer>` to enter AR (Scene Viewer on Android
/// browsers, Quick Look on iOS Safari). Exception-guarded like every other
/// DOM touch in this file: a failure degrades to "nothing happens", never a
/// crash — and the caller only ever invokes this after `canActivateAR`.
void activateModelViewerAr() {
  try {
    _findViewer(web.document)?.callMethod<JSAny?>('activateAR'.toJS);
  } catch (_) {
    // Swallowed by design; see doc comment.
  }
}

bool _viewerFlagIsTrue(String property) {
  try {
    final viewer = _findViewer(web.document);
    if (viewer == null) return false;
    final value = viewer.getProperty<JSAny?>(property.toJS);
    return value.isA<JSBoolean>() && (value! as JSBoolean).toDart;
  } catch (_) {
    return false;
  }
}

/// Depth-first search for `model-viewer` through [scope] (a Document or
/// ShadowRoot — both expose querySelector/querySelectorAll) and every open
/// shadow root under it.
JSObject? _findViewer(JSObject scope) {
  final direct = scope.callMethod<JSAny?>('querySelector'.toJS, 'model-viewer'.toJS);
  if (direct.isA<JSObject>()) return direct! as JSObject;

  final descendants =
      scope.callMethod<web.NodeList>('querySelectorAll'.toJS, '*'.toJS);
  for (var i = 0; i < descendants.length; i++) {
    // querySelectorAll('*') only ever yields Elements.
    final shadow = (descendants.item(i)! as web.Element).shadowRoot;
    if (shadow != null) {
      final found = _findViewer(shadow);
      if (found != null) return found;
    }
  }
  return null;
}
