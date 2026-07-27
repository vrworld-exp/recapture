// lib/presentation/screens/projects/model_render_view.dart
//
// The real 3D/AR renderer behind ModelViewerScreen's `defaultRenderBuilder`.
//
// model-viewer fetches the GLB with in-page JS, so the widget owns the load
// lifecycle the webview would otherwise swallow: a loading skin until the
// model's `load` event, mapped copy + retry on `error` (the URL and raw error
// NEVER reach the screen — same rule as the Preview gallery / 9F), and a
// "View in AR" CTA that is ALWAYS visible once the model is ready (product
// call 2026-07-18: an invisible AR entry point read as "there is no AR").
// What the element's own `canActivateAR` signal gates now is the BEHAVIOR,
// not the visibility: supported devices launch AR (the exact signal
// model-viewer's built-in AR button uses), unsupported ones (no USDZ on iOS,
// no ARCore, a desktop browser) get one line of mapped guidance instead of a
// silent dead tap.
//
// AR scope is Scene Viewer (Android intent) + Quick Look (iOS `iosSrc`), both
// driven entirely by model_viewer_plus — no native AR plugin.
//
// WEB CAVEAT: none of the CHANNEL plumbing can exist on web — the package
// injects its page via `innerHTML` (scripts never execute) and has no
// JS-channel/controller API there, so gating anything on the channel would
// wait forever. Instead, web gets its signals from a Dart-side DOM probe
// (model_viewer_load_probe.dart) that watches the element's own `loaded` and
// `canActivateAR` properties — which is what lets the loading skin AND the AR
// CTA work on web too (mobile browsers: Scene Viewer / Quick Look; desktop
// reports no AR and the CTA falls back to guidance). The error body remains
// mobile-only (no error signal on web), and a fallback timer guarantees the
// skin can never cover a working viewer forever.
//
// AR TIMING: `canActivateAR` is resolved on model-viewer's own schedule,
// independent of the model fetch — sampling it once at the `load` event can
// miss it. Both platforms therefore keep an AR watch alive after load (a
// polled `ar` message on mobile, the DOM probe on web) so a late flip still
// surfaces the CTA instead of silently losing the button.
import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../domain/entities/project_model.dart';
import '../../widgets/app_button.dart';
import 'model_viewer_load_probe.dart' as load_probe;

enum _RenderPhase { loading, ready, failed }

class ModelRenderView extends StatefulWidget {
  const ModelRenderView({
    super.key,
    required this.model,
    @visibleForTesting this.viewerOverride,
  });

  final ProjectModelView model;

  /// Test-only stand-in for the real [ModelViewer], which drives a WebView
  /// with no platform implementation in widget tests. The surrounding
  /// loading / error / AR chrome is what the tests exercise.
  final Widget? viewerOverride;

  /// AR modes for this model. `quick-look` is enabled ONLY when a USDZ
  /// exists: without one, model-viewer generates a USDZ on the fly and
  /// navigates to a blob: URL — a navigation the plugin's Quick Look
  /// intercept (an exact match on `iosSrc`) can never catch, which would
  /// break the page instead of opening AR.
  @visibleForTesting
  static List<String> arModesFor(String? usdzUrl) => [
        'scene-viewer',
        if (usdzUrl != null) 'quick-look',
        'webxr',
      ];

  @override
  State<ModelRenderView> createState() => ModelRenderViewState();
}

class ModelRenderViewState extends State<ModelRenderView> {
  static const _channelName = 'RecaptureModelViewer';

  /// Injected after the `<model-viewer>` element: reports the model's load
  /// lifecycle (and AR availability) back over the [_channelName] channel.
  /// The `loaded` re-check covers a load that finished before this script ran.
  /// `canActivateAR` is ALSO polled after the initial report — model-viewer
  /// resolves AR support asynchronously, so a one-shot sample at `load` can
  /// race it false and permanently hide a button the device supports.
  static const _lifecycleJs = '''
(function () {
  var viewer = document.querySelector('model-viewer');
  function post(msg) {
    if (window.$_channelName) { window.$_channelName.postMessage(msg); }
  }
  if (!viewer) { post('error'); return; }
  function watchAr() {
    if (viewer.canActivateAR) { post('ar'); return; }
    var tries = 0;
    var t = setInterval(function () {
      if (viewer.canActivateAR) { clearInterval(t); post('ar'); }
      else if (++tries >= 40) { clearInterval(t); }
    }, 500);
  }
  function report() {
    post(viewer.canActivateAR ? 'loaded:ar' : 'loaded');
    watchAr();
  }
  if (viewer.loaded) { report(); }
  else { viewer.addEventListener('load', report, { once: true }); }
  viewer.addEventListener('error', function () { post('error'); });
})();
''';

  /// Uniform scale applied to the model. Meshy GLBs carry no calibrated
  /// real-world size and render ~2.5× too large in AR (Scene Viewer / Quick
  /// Look place the model at its baked bounds), so 1/2.5 = 0.4 brings it down
  /// to roughly the real object's size. The `scale` transform is baked into
  /// the scene model-viewer exports to AR, so this applies on both platforms;
  /// the inline preview re-frames via the `105%` cameraOrbit, so it is
  /// visually unaffected. Pinch-to-scale (arScale.auto) still lets the user
  /// fine-tune from this starting size.
  @visibleForTesting
  // static const modelScale = '0.4 0.4 0.4';
  static const modelScale = '0.2 0.2 0.2';

  /// How long the loading skin may wait for a load signal before uncovering
  /// the viewer anyway. A missed signal (broken channel, changed DOM layout)
  /// must degrade to model-viewer's own progress bar — never to a skin that
  /// covers a working viewer forever (the pre-07-17 web bug).
  @visibleForTesting
  static const loadingFallback = Duration(seconds: 15);

  _RenderPhase _phase = _RenderPhase.loading;
  bool _arAvailable = false;

  /// Bumped on retry so the [ValueKey] rebuilds the webview from scratch.
  int _attempt = 0;

  /// Runs JS inside the viewer's webview once it exists. Held as a closure
  /// over the controller so this file needs no direct webview_flutter import.
  void Function(String js)? _runJs;

  /// Cancels the web DOM probes, when running (always null on mobile). The AR
  /// probe outlives the load watch on purpose: AR readiness can flip after
  /// `loaded`, and a late flip must still surface the CTA.
  void Function()? _cancelProbe;
  void Function()? _cancelArProbe;
  Timer? _fallbackTimer;

  @override
  void initState() {
    super.initState();
    _beginLoadWatch();
  }

  @override
  void dispose() {
    _stopLoadWatch();
    _stopArWatch();
    super.dispose();
  }

  /// Arms the load signals for one webview attempt. On web the JS channel can
  /// never fire, so the signals come from the Dart-side DOM probe instead; the
  /// fallback timer backstops BOTH platforms.
  void _beginLoadWatch() {
    if (kIsWeb) {
      _cancelProbe =
          load_probe.watchModelViewerLoaded(() => handleEvent('loaded'));
      _cancelArProbe =
          load_probe.watchModelViewerArReady(() => handleEvent('ar'));
    }
    _fallbackTimer = Timer(loadingFallback, () {
      if (_phase == _RenderPhase.loading) handleEvent('loaded');
    });
  }

  void _stopLoadWatch() {
    _cancelProbe?.call();
    _cancelProbe = null;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
  }

  void _stopArWatch() {
    _cancelArProbe?.call();
    _cancelArProbe = null;
  }

  @visibleForTesting
  void handleEvent(String message) {
    if (!mounted) return;
    setState(() {
      switch (message) {
        // A standalone AR flip: does NOT touch the load wait — it can arrive
        // before, with, or long after `loaded`, and must never mask a `loaded`
        // that is still pending (nor reset the fallback timer).
        case 'ar':
          _arAvailable = true;
        case 'loaded:ar':
          _stopLoadWatch();
          _phase = _RenderPhase.ready;
          _arAvailable = true;
        // Deliberately leaves _arAvailable alone: an earlier `ar` signal must
        // survive the load report that follows it.
        case 'loaded':
          _stopLoadWatch();
          _phase = _RenderPhase.ready;
        case 'error':
          _stopLoadWatch();
          _stopArWatch();
          _phase = _RenderPhase.failed;
          _arAvailable = false;
      }
    });
  }

  void _retry() {
    _stopLoadWatch();
    _stopArWatch();
    setState(() {
      _attempt++;
      _phase = _RenderPhase.loading;
      _arAvailable = false;
      _runJs = null;
    });
    _beginLoadWatch();
  }

  void _activateAr() {
    if (kIsWeb) {
      // No controller exists on web — drive the element directly via the
      // same DOM seam that watched canActivateAR.
      load_probe.activateModelViewerAr();
      return;
    }
    _runJs?.call("document.querySelector('model-viewer').activateAR();");
  }

  /// Tap on the AR CTA while the page reports no AR support: one line of
  /// guidance instead of a silent nothing. Mapped copy only — the reason
  /// (no ARCore, no USDZ, desktop) is never surfaced raw.
  void _explainArUnavailable() {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(kIsWeb
          ? 'AR isn’t available in this browser — open this model on your '
              'phone to see it in your space.'
          : 'AR isn’t available on this device.'),
    ));
  }

  Widget _viewer(String glbUrl) {
    if (widget.viewerOverride case final override?) return override;
    final usdzUrl = widget.model.usdzUrl;
    return ModelViewer(
      key: ValueKey('model_viewer_$_attempt'),
      src: glbUrl,
      iosSrc: usdzUrl,
      alt: 'A 3D model of the captured object',
      ar: true,
      arModes: ModelRenderView.arModesFor(usdzUrl),
      // Shrink the model to roughly the real object's size — Meshy GLBs come
      // in ~2.5× too large in AR (see [modelScale]).
      scale: modelScale,
      // A captured physical object sits on a surface. Meshy GLBs carry no
      // calibrated real-world size, so pinch-to-scale stays enabled rather
      // than pinning a possibly-wrong "100%".
      arScale: ArScale.auto,
      arPlacement: ArPlacement.floor,
      cameraControls: true,
      disableZoom: false,
      // Resume the idle spin well after the user stops orbiting instead of
      // fighting their gesture.
      autoRotate: true,
      autoRotateDelay: 5000,
      cameraOrbit: '0deg 75deg 105%',
      fieldOfView: '30deg',
      // Neutral env + a touch of extra exposure so a textured GLB reads on
      // the near-black background; a soft shadow grounds the object.
      environmentImage: 'neutral',
      exposure: 1.1,
      shadowIntensity: 0.8,
      shadowSoftness: 0.7,
      backgroundColor: AppColors.bgPrimary,
      // The in-page AR button is replaced by our own CTA (same canActivateAR
      // gate), so it must never show.
      relatedCss: 'model-viewer::part(default-ar-button) { display: none; }',
      relatedJs: _lifecycleJs,
      javascriptChannels: {
        JavascriptChannel(
          _channelName,
          onMessageReceived: (m) => handleEvent(m.message),
        ),
      },
      onWebViewCreated: (controller) => _runJs = controller.runJavaScript,
      debugLogging: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final glbUrl = widget.model.glbUrl;
    // Defensive: every caller gates on isViewable before rendering.
    if (glbUrl == null) return const SizedBox.shrink();
    if (_phase == _RenderPhase.failed) {
      return _LoadFailedBody(onRetry: _retry);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        _viewer(glbUrl),
        // Covers the webview until the model reports loaded (channel on
        // mobile, DOM probe on web) — model-viewer fetches the GLB over the
        // network and would otherwise sit blank.
        if (_phase == _RenderPhase.loading)
          const ColoredBox(
            key: ValueKey('model_loading'),
            color: AppColors.bgPrimary,
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(AppSpacing.xxl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: AppColors.mirageRed),
                    SizedBox(height: AppSpacing.xl),
                    Icon(Icons.view_in_ar_outlined,
                        color: AppColors.textMuted, size: 40),
                    SizedBox(height: AppSpacing.xl),
                    Text(
                      'Preparing your model…',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                    SizedBox(height: AppSpacing.sm),
                    Text(
                      'Hang tight — the 3D model is on its way.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (_phase == _RenderPhase.ready)
          Positioned(
            left: 0,
            right: 0,
            bottom: AppSpacing.xl,
            child: Center(
              child: _ArCta(
                available: _arAvailable,
                onPressed:
                    _arAvailable ? _activateAr : _explainArUnavailable,
              ),
            ),
          ),
      ],
    );
  }
}

/// The "View in AR" affordance — always shown once the model is ready so the
/// AR entry point is discoverable everywhere. [available] mirrors the page's
/// `canActivateAR`: true renders the full-strength CTA and launches AR;
/// false renders it muted and the tap explains instead of doing nothing.
class _ArCta extends StatelessWidget {
  const _ArCta({required this.available, required this.onPressed});

  final bool available;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    // AR-ready gets the app's primary-CTA treatment (mirage red) so the
    // button reads over the near-black viewer; unavailable stays a muted
    // surface pill — present and explaining, but not shouting.
    final foreground =
        available ? AppColors.textPrimary : AppColors.textMuted;
    return Material(
      key: const ValueKey('model_ar_cta'),
      color: available
          ? AppColors.mirageRed
          : AppColors.surface2.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl,
            vertical: AppSpacing.md,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.view_in_ar, size: 18, color: foreground),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'View in AR',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A failed GLB load. Mapped copy only — never the URL or the raw error —
/// with a retry that rebuilds the webview from scratch.
class _LoadFailedBody extends StatelessWidget {
  const _LoadFailedBody({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.view_in_ar_outlined,
                color: AppColors.textMuted, size: 40),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'We couldn’t load this model. Check your connection and try again.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.xl),
            AppButton(
              key: const ValueKey('model_retry_cta'),
              label: 'Try again',
              icon: Icons.refresh,
              isFullWidth: false,
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}
