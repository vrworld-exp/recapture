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

/// Trigger URL for `<model-viewer>`'s meshopt decoder. **Load-bearing — read
/// this before touching it.**
///
/// The backend's optimizer runs `meshopt()`, which writes
/// `EXT_meshopt_compression` into the GLB's **`extensionsRequired`**.
/// `<model-viewer>` ships DRACO and KTX2 decoder locations by DEFAULT but not a
/// meshopt one, so with no configuration `GLTFLoader` refuses the file and the
/// user gets the generic "we couldn't load this model" — for EVERY optimized
/// model, on every platform.
///
/// The decoder itself is already BUNDLED inside `model-viewer.min.js` (the WASM
/// is inlined). `setMeshoptDecoderLocation(url)` only appends a `<script
/// src=url>` and waits for it to load before using the bundled decoder — the
/// URL is a TRIGGER, not a download. A no-op `data:` script satisfies it with
/// no network request, which matters because the mobile viewer is served by the
/// plugin's local proxy: that proxy answers only `/`, `/model-viewer.min.js`
/// and `/model`, and REDIRECTS any other path to the GLB's CloudFront origin,
/// where a real decoder file would 404 — and a 404 rejects the decoder promise,
/// which fails the load exactly as if nothing had been configured.
///
/// Must be kept IDENTICAL to the value in `web/index.html`; the two are
/// separate pages (the plugin's WebView template inherits nothing from the web
/// build's HTML) and `test/projects/meshopt_decoder_test.dart` asserts they
/// still agree.
@visibleForTesting
const kMeshoptDecoderLocation = 'data:text/javascript,0';

class ModelRenderViewState extends State<ModelRenderView> {
  static const _channelName = 'RecaptureModelViewer';

  /// Injected after the `<model-viewer>` element: reports the model's load
  /// lifecycle (and AR availability) back over the [_channelName] channel.
  /// The `loaded` re-check covers a load that finished before this script ran.
  /// `canActivateAR` is ALSO polled after the initial report — model-viewer
  /// resolves AR support asynchronously, so a one-shot sample at `load` can
  /// race it false and permanently hide a button the device supports.
  static const _lifecycleJs = '''
// ── meshopt decoder (see kMeshoptDecoderLocation) ──────────────────────────
// model-viewer reads `self.ModelViewerElement` ONCE, when its module
// evaluates. This script is a CLASSIC inline <script> in the body, and the
// plugin's template loads model-viewer as `type="module"` — which is deferred
// until after parsing — so this always runs FIRST. Without it, every optimized
// GLB fails to load in the app's WebView.
window.ModelViewerElement = window.ModelViewerElement || {};
window.ModelViewerElement.meshoptDecoderLocation = '$kMeshoptDecoderLocation';

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
  // model-viewer raises exactly two error kinds, and only ONE of them is a
  // dead end: 'loadfailure' (the GLB could not be fetched or parsed) versus
  // 'webglcontextlost' (the WebView dropped the GL context — it restores
  // itself and re-renders). Reporting the kind is what lets the Dart side
  // stop killing a viewer that is about to recover on its own.
  viewer.addEventListener('error', function (e) {
    var kind = (e && e.detail && e.detail.type) || 'unknown';
    post('error:' + kind);
  });
})();
''';

  /// The injected page script, for the meshopt-decoder guardrail test — the
  /// one piece of this file whose absence is invisible until a real optimized
  /// model fails to load on a device. See [kMeshoptDecoderLocation].
  @visibleForTesting
  static String get lifecycleJsForTest => _lifecycleJs;

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

  /// Query parameter carrying [_cacheBustToken]. Namespaced so it can never
  /// collide with a parameter the URL already carries.
  static const _cacheBustParam = 'rcRetry';

  _RenderPhase _phase = _RenderPhase.loading;
  bool _arAvailable = false;

  /// Bumped on retry so the [ValueKey] rebuilds the webview from scratch.
  int _attempt = 0;

  /// Cache-buster mixed into the GLB URL for every attempt AFTER the first.
  ///
  /// On mobile the plugin does NOT stream the model itself: its local proxy
  /// answers `/model` with a 302 to our CloudFront URL, so the WEBVIEW fetches
  /// the GLB and the WebView's own HTTP cache decides what those bytes are. A
  /// fetch cut short mid-download (backgrounded app, dropped Wi-Fi) can leave a
  /// truncated entry behind that keeps being served from cache — a model that
  /// rendered yesterday then fails to parse forever, surviving app restarts.
  /// Rebuilding the webview cannot shake that off: same URL, same cache key,
  /// same corrupt bytes, so "Try again" was unable to fix the one failure it
  /// most needed to. A per-attempt token changes the cache key and forces a
  /// real network fetch. It stays null on the first attempt so the normal path
  /// keeps hitting the cache (and CloudFront's edge) as before.
  ///
  /// S3 ignores unknown query parameters and CloudFront serves the object
  /// either way, so the retry URL resolves to exactly the same bytes.
  String? _cacheBustToken;

  /// Whether the silent one-shot retry has been spent for the current user
  /// session with this model. A single `loadfailure` is far more often a
  /// transient fetch (or the stale-cache case above) than a genuinely broken
  /// model, and recovering silently beats handing the user a retry button that
  /// re-runs what already failed.
  bool _autoRetried = false;

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

  /// model-viewer error kinds that must NOT strand the user on the retry body.
  ///
  /// `webglcontextlost` is the WebView reclaiming the GL context — under memory
  /// pressure, on a heavy model, or simply because the app was backgrounded.
  /// model-viewer restores the context and re-renders by itself, so failing the
  /// whole screen replaces a viewer that recovers in a second with a dead end
  /// whose only escape (Try again) rebuilds the webview and re-downloads the
  /// GLB — strictly worse than doing nothing.
  static const _recoverableErrorKinds = {'webglcontextlost'};

  @visibleForTesting
  void handleEvent(String message) {
    if (!mounted) return;
    // `error:<kind>` from the injected lifecycle script. A bare `error` (an
    // older page, or the "no <model-viewer> in the DOM" report) has no kind and
    // stays fatal.
    if (message.startsWith('error:')) {
      final kind = message.substring('error:'.length);
      if (_recoverableErrorKinds.contains(kind)) return;
      message = 'error';
    }
    // Spend the silent retry before the failure is ever rendered: the second
    // attempt re-fetches on a fresh cache key (see [_cacheBustToken]), which is
    // the difference between recovering from a truncated cached GLB and being
    // stuck on it permanently.
    if (message == 'error' && !_autoRetried) {
      _autoRetried = true;
      _restart();
      return;
    }
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

  /// The user tapped "Try again". Re-arms the silent retry too: a transient
  /// failure that happens again later deserves the same self-healing attempt
  /// rather than going straight back to the dead end.
  void _retry() {
    _autoRetried = false;
    _restart();
  }

  /// Rebuilds the webview from scratch on a NEW cache key. Shared by the user's
  /// retry and the silent one — both must re-fetch rather than replay whatever
  /// the WebView already has for this URL.
  void _restart() {
    _stopLoadWatch();
    _stopArWatch();
    setState(() {
      _attempt++;
      _cacheBustToken = DateTime.now().microsecondsSinceEpoch.toString();
      _phase = _RenderPhase.loading;
      _arAvailable = false;
      _runJs = null;
    });
    _beginLoadWatch();
  }

  /// The GLB URL for the current attempt — untouched on the first, cache-busted
  /// on every retry. See [_cacheBustToken] for why.
  @visibleForTesting
  String srcFor(String glbUrl) {
    final token = _cacheBustToken;
    if (token == null) return glbUrl;
    final uri = Uri.parse(glbUrl);
    return uri.replace(
      queryParameters: {...uri.queryParameters, _cacheBustParam: token},
    ).toString();
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
      src: srcFor(glbUrl),
      // Deliberately NOT cache-busted: the plugin's Quick Look intercept
      // matches this string EXACTLY against the navigation it sees, so a URL
      // that changes per attempt would break AR instead of fixing a load.
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
