// lib/presentation/screens/projects/model_render_view.dart
//
// The real 3D/AR renderer behind ModelViewerScreen's `defaultRenderBuilder`.
//
// model-viewer fetches the GLB with in-page JS, so the widget owns the load
// lifecycle the webview would otherwise swallow: a loading skin until the
// model's `load` event, mapped copy + retry on `error` (the URL and raw error
// NEVER reach the screen — same rule as the Preview gallery / 9F), and a
// "View in your space" CTA gated on the element's own `canActivateAR` signal
// (the exact signal model-viewer uses for its built-in AR button, so the CTA
// can never be a dead button — no USDZ on iOS, an unsupported device, or web
// all report false and the orbit viewer stays as the graceful floor).
//
// AR scope is Scene Viewer (Android intent) + Quick Look (iOS `iosSrc`), both
// driven entirely by model_viewer_plus — no native AR plugin.
//
// WEB CAVEAT: none of the lifecycle plumbing can exist on web — the package
// injects its page via `innerHTML` (scripts never execute) and has no
// JS-channel/controller API there. So on web the viewer shows immediately
// (model-viewer's own progress bar is the loading affordance) and the AR CTA
// never appears; gating either on the channel would wait forever.
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../domain/entities/project_model.dart';
import '../../widgets/app_button.dart';

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
  static const _lifecycleJs = '''
(function () {
  var viewer = document.querySelector('model-viewer');
  function post(msg) {
    if (window.$_channelName) { window.$_channelName.postMessage(msg); }
  }
  if (!viewer) { post('error'); return; }
  function report() { post(viewer.canActivateAR ? 'loaded:ar' : 'loaded'); }
  if (viewer.loaded) { report(); }
  else { viewer.addEventListener('load', report, { once: true }); }
  viewer.addEventListener('error', function () { post('error'); });
})();
''';

  // Web starts (and stays) ready: no channel will ever report load/error
  // there, so the overlay would otherwise cover a working viewer forever.
  _RenderPhase _phase = kIsWeb ? _RenderPhase.ready : _RenderPhase.loading;
  bool _arAvailable = false;

  /// Bumped on retry so the [ValueKey] rebuilds the webview from scratch.
  int _attempt = 0;

  /// Runs JS inside the viewer's webview once it exists. Held as a closure
  /// over the controller so this file needs no direct webview_flutter import.
  void Function(String js)? _runJs;

  @visibleForTesting
  void handleEvent(String message) {
    if (!mounted) return;
    setState(() {
      switch (message) {
        case 'loaded:ar':
          _phase = _RenderPhase.ready;
          _arAvailable = true;
        case 'loaded':
          _phase = _RenderPhase.ready;
          _arAvailable = false;
        case 'error':
          _phase = _RenderPhase.failed;
          _arAvailable = false;
      }
    });
  }

  void _retry() {
    setState(() {
      _attempt++;
      _phase = _RenderPhase.loading;
      _arAvailable = false;
      _runJs = null;
    });
  }

  void _activateAr() {
    _runJs?.call("document.querySelector('model-viewer').activateAR();");
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
        // Covers the webview until the model's own load event — model-viewer
        // fetches the GLB over the network and would otherwise sit blank.
        if (_phase == _RenderPhase.loading)
          const ColoredBox(
            key: ValueKey('model_loading'),
            color: AppColors.bgPrimary,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: AppColors.mirageRed),
                  SizedBox(height: AppSpacing.lg),
                  Text(
                    'Loading 3D model…',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
          ),
        if (_phase == _RenderPhase.ready && _arAvailable)
          Positioned(
            left: 0,
            right: 0,
            bottom: AppSpacing.xl,
            child: Center(child: _ArCta(onPressed: _activateAr)),
          ),
      ],
    );
  }
}

/// The "View in your space" affordance. Only ever built when the page
/// reported `canActivateAR`, so it cannot render as a dead button.
class _ArCta extends StatelessWidget {
  const _ArCta({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('model_ar_cta'),
      color: AppColors.surface2.withValues(alpha: 0.92),
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
              const Icon(Icons.view_in_ar,
                  size: 18, color: AppColors.textPrimary),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'View in your space',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: AppColors.textPrimary),
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
