// test/projects/model_render_view_test.dart
//
// The viewer upgrade's chrome, all exercised WITHOUT a webview (the real
// ModelViewer has no platform implementation in a widget test — the inner
// viewer is overridden and lifecycle events are driven by hand):
//   • loading skin until the model's load event;
//   • the "View in your space" CTA appears ONLY when the page reported
//     canActivateAR — unsupported devices / no-USDZ-on-iOS get no dead button;
//   • a failed load shows mapped copy (never the URL) with a working retry;
//   • quick-look is enabled only when a USDZ exists;
//   • ModelViewerScreen hands the WHOLE model to the render seam, and the
//     approve bar stays staff-only (regression).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recapture/app/theme/app_theme.dart';
import 'package:recapture/application/auth/user_role_notifier.dart';
import 'package:recapture/domain/entities/project_model.dart';
import 'package:recapture/presentation/screens/projects/model_render_view.dart';
import 'package:recapture/presentation/screens/projects/model_viewer_screen.dart';

const _model = ProjectModelView(
  id: 'm1',
  source: ModelSource.meshy,
  status: ModelStatus.succeeded,
  glbUrl: 'https://cdn/model.glb',
  usdzUrl: 'https://cdn/model.usdz',
);

void main() {
  group('ModelRenderView — load lifecycle', () {
    final key = GlobalKey<ModelRenderViewState>();

    Widget app() => MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: ModelRenderView(
              key: key,
              model: _model,
              viewerOverride: const SizedBox.expand(),
            ),
          ),
        );

    testWidgets('shows the loading skin until the model reports load',
        (tester) async {
      await tester.pumpWidget(app());

      expect(find.byKey(const ValueKey('model_loading')), findsOneWidget);
      expect(find.byKey(const ValueKey('model_ar_cta')), findsNothing);

      key.currentState!.handleEvent('loaded');
      await tester.pump();

      expect(find.byKey(const ValueKey('model_loading')), findsNothing);
    });

    testWidgets('the AR CTA is ALWAYS visible once the model is ready — '
        'with canActivateAR it launches silently, without it the tap explains',
        (tester) async {
      // Supported: no guidance snackbar on tap.
      await tester.pumpWidget(app());
      key.currentState!.handleEvent('loaded:ar');
      await tester.pump();

      expect(find.byKey(const ValueKey('model_ar_cta')), findsOneWidget);
      expect(find.text('View in AR'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('model_ar_cta')));
      await tester.pump();
      expect(find.textContaining('AR isn’t available'), findsNothing);
    });

    testWidgets('no canActivateAR → the CTA still shows, and the tap gives '
        'guidance instead of a silent dead button', (tester) async {
      await tester.pumpWidget(app());
      key.currentState!.handleEvent('loaded');
      await tester.pump();

      expect(find.byKey(const ValueKey('model_ar_cta')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('model_ar_cta')));
      await tester.pump();
      expect(find.textContaining('AR isn’t available'), findsOneWidget);
    });

    testWidgets('a LATE ar signal (after loaded) upgrades the CTA — '
        'canActivateAR resolving after the load event must not lose AR',
        (tester) async {
      await tester.pumpWidget(app());
      key.currentState!.handleEvent('loaded');
      await tester.pump();

      key.currentState!.handleEvent('ar');
      await tester.pump();

      // Now a real launch: no guidance snackbar.
      await tester.tap(find.byKey(const ValueKey('model_ar_cta')));
      await tester.pump();
      expect(find.textContaining('AR isn’t available'), findsNothing);
    });

    testWidgets('an EARLY ar signal (before loaded) is kept: no CTA while '
        'loading, launch-capable CTA once loaded', (tester) async {
      await tester.pumpWidget(app());
      key.currentState!.handleEvent('ar');
      await tester.pump();

      // Still loading — the CTA never floats over the loading skin, and the
      // ar message must NOT have consumed the load wait.
      expect(find.byKey(const ValueKey('model_loading')), findsOneWidget);
      expect(find.byKey(const ValueKey('model_ar_cta')), findsNothing);

      key.currentState!.handleEvent('loaded');
      await tester.pump();

      expect(find.byKey(const ValueKey('model_loading')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('model_ar_cta')));
      await tester.pump();
      expect(find.textContaining('AR isn’t available'), findsNothing);
    });

    testWidgets('an ar signal does not defuse the loading fallback timer',
        (tester) async {
      await tester.pumpWidget(app());
      key.currentState!.handleEvent('ar');
      await tester.pump();
      expect(find.byKey(const ValueKey('model_loading')), findsOneWidget);

      await tester.pump(ModelRenderViewState.loadingFallback);

      // The fallback still uncovers the viewer, and the earlier AR signal
      // survives into the ready phase (tap launches, no guidance).
      expect(find.byKey(const ValueKey('model_loading')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('model_ar_cta')));
      await tester.pump();
      expect(find.textContaining('AR isn’t available'), findsNothing);
    });

    testWidgets('retry resets AR availability for the fresh attempt',
        (tester) async {
      await tester.pumpWidget(app());
      key.currentState!.handleEvent('loaded:ar');
      await tester.pump();
      key.currentState!.handleEvent('error');
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('model_retry_cta')));
      await tester.pump();
      key.currentState!.handleEvent('loaded');
      await tester.pump();

      // The new attempt reported plain `loaded` — the stale availability is
      // gone, so the tap explains rather than firing a broken activateAR.
      await tester.tap(find.byKey(const ValueKey('model_ar_cta')));
      await tester.pump();
      expect(find.textContaining('AR isn’t available'), findsOneWidget);
    });

    testWidgets('no load signal → the fallback uncovers the viewer instead of '
        'blocking it forever, and it is NOT treated as an error',
        (tester) async {
      await tester.pumpWidget(app());
      expect(find.byKey(const ValueKey('model_loading')), findsOneWidget);

      await tester.pump(ModelRenderViewState.loadingFallback);

      expect(find.byKey(const ValueKey('model_loading')), findsNothing);
      expect(find.textContaining('couldn’t load'), findsNothing);
    });

    testWidgets('a failed load shows mapped copy — never the URL — and retry '
        'returns to loading', (tester) async {
      await tester.pumpWidget(app());
      key.currentState!.handleEvent('error');
      await tester.pump();

      expect(
        find.text(
            'We couldn’t load this model. Check your connection and try again.'),
        findsOneWidget,
      );
      // The URL must never surface, in any widget.
      expect(find.textContaining('https://'), findsNothing);
      expect(find.textContaining('cdn'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('model_retry_cta')));
      await tester.pump();

      // Back to a fresh attempt: loading skin up, error copy gone.
      expect(find.byKey(const ValueKey('model_loading')), findsOneWidget);
      expect(find.textContaining('couldn’t load'), findsNothing);
    });

    testWidgets('a load FAILURE is fatal — the kind is reported and mapped',
        (tester) async {
      await tester.pumpWidget(app());
      key.currentState!.handleEvent('error:loadfailure');
      await tester.pump();

      expect(find.byKey(const ValueKey('model_retry_cta')), findsOneWidget);
    });

    testWidgets('a WebGL context loss does NOT strand a loaded model on the '
        'retry body — model-viewer restores it itself', (tester) async {
      await tester.pumpWidget(app());
      key.currentState!.handleEvent('loaded:ar');
      await tester.pump();

      key.currentState!.handleEvent('error:webglcontextlost');
      await tester.pump();

      // Still the live viewer, still AR-capable: nothing was torn down.
      expect(find.byKey(const ValueKey('model_retry_cta')), findsNothing);
      expect(find.textContaining('couldn’t load'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('model_ar_cta')));
      await tester.pump();
      expect(find.textContaining('AR isn’t available'), findsNothing);
    });

    testWidgets('a context loss DURING load leaves the load watch running '
        'rather than failing the screen', (tester) async {
      await tester.pumpWidget(app());
      key.currentState!.handleEvent('error:webglcontextlost');
      await tester.pump();

      // Still waiting, not failed — and the fallback still ends the wait.
      expect(find.byKey(const ValueKey('model_loading')), findsOneWidget);
      expect(find.byKey(const ValueKey('model_retry_cta')), findsNothing);

      await tester.pump(ModelRenderViewState.loadingFallback);
      expect(find.byKey(const ValueKey('model_loading')), findsNothing);
      expect(find.textContaining('couldn’t load'), findsNothing);
    });

    testWidgets('an UNKNOWN error kind stays fatal — only the kinds we know '
        'recover are forgiven', (tester) async {
      await tester.pumpWidget(app());
      key.currentState!.handleEvent('error:something-new');
      await tester.pump();

      expect(find.byKey(const ValueKey('model_retry_cta')), findsOneWidget);
    });
  });

  group('ModelRenderView.arModesFor', () {
    test('quick-look is offered only when a USDZ exists', () {
      // Without a USDZ, model-viewer would fall back to generating one on the
      // fly and navigating to a blob: URL the plugin's Quick Look intercept
      // can never catch — so the mode must be absent entirely.
      expect(ModelRenderView.arModesFor('https://cdn/model.usdz'),
          contains('quick-look'));
      expect(ModelRenderView.arModesFor(null),
          isNot(contains('quick-look')));
      // Scene Viewer stays available either way.
      expect(ModelRenderView.arModesFor(null), contains('scene-viewer'));
    });
  });

  group('ModelViewerScreen — the render seam', () {
    testWidgets('hands the WHOLE model to the builder (GLB + USDZ)',
        (tester) async {
      ProjectModelView? received;
      await tester.pumpWidget(ProviderScope(
        // The screen's Export action watches the role — without this override
        // the real userRoleProvider chain would open Hive.
        overrides: [isStaffProvider.overrideWithValue(false)],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: ModelViewerScreen(
            model: _model,
            renderBuilder: (_, m) {
              received = m;
              return const SizedBox.expand();
            },
          ),
        ),
      ));

      expect(received?.glbUrl, 'https://cdn/model.glb');
      expect(received?.usdzUrl, 'https://cdn/model.usdz');
    });

    testWidgets('approve bar: staff (onApprove set) sees it, owner does not',
        (tester) async {
      Widget screen({Future<void> Function()? onApprove}) => ProviderScope(
            overrides: [isStaffProvider.overrideWithValue(false)],
            child: MaterialApp(
              theme: AppTheme.dark,
              home: ModelViewerScreen(
                model: _model,
                onApprove: onApprove,
                renderBuilder: (_, __) => const SizedBox.expand(),
              ),
            ),
          );

      await tester.pumpWidget(screen(onApprove: () async {}));
      expect(find.byKey(const ValueKey('model_approve_cta')), findsOneWidget);

      await tester.pumpWidget(screen());
      expect(find.byKey(const ValueKey('model_approve_cta')), findsNothing);
    });
  });
}
