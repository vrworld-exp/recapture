// test/projects/meshopt_decoder_test.dart
//
// Guards the ONE configuration that decides whether an optimized model renders
// at all.
//
// The backend optimizer runs `meshopt()`, which writes
// `EXT_meshopt_compression` into the GLB's `extensionsRequired`.
// `<model-viewer>` ships DRACO and KTX2 decoder locations by DEFAULT but not a
// meshopt one — so unless `meshoptDecoderLocation` is set, GLTFLoader refuses
// the file and the user sees the generic "we couldn't load this model" for
// EVERY optimized model.
//
// It has to be set in TWO places, because there are two pages:
//   • `web/index.html`, for the web build;
//   • `_lifecycleJs` in model_render_view.dart, which is the mobile WebView's
//     own HTML template and inherits nothing from the web build's HTML.
//
// Fixing one and forgetting the other ships the feature broken on the other
// platform — a failure mode no unit test would otherwise catch, because both
// halves compile and analyze perfectly. Hence this file.
//
// THE THIRD WAY TO BREAK IT is to render a model through some OTHER viewer.
// Both configured pages belong to [ModelRenderView]; a bare `ModelViewer`
// dropped into a new surface builds its own page with neither of them. The
// catalog preview is the first surface outside `projects/` to show a model, so
// the last group here pins its 3D path to [ModelRenderView] — every optimized
// GLB in the preview depends on it, and nothing else in the build would say so.
//
// NOTE: passing here is NOT proof the models render. That acceptance is visual
// and belongs on a real device and a real web build.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/catalog_product.dart';
import 'package:recapture/presentation/screens/projects/model_render_view.dart';
import 'package:recapture/presentation/widgets/catalog/preview_product_card.dart';

void main() {
  group('meshopt decoder location', () {
    test('web/index.html configures it BEFORE the model-viewer module', () {
      final html = File('web/index.html').readAsStringSync();

      expect(
        html.contains('meshoptDecoderLocation'),
        isTrue,
        reason: 'Without this, every optimized model fails to load on web.',
      );

      // Order is load-bearing: model-viewer reads `self.ModelViewerElement`
      // exactly once, when its module evaluates. A value set afterwards is
      // simply ignored — and the page LOOKS correct while doing nothing.
      final configAt = html.indexOf('meshoptDecoderLocation');
      final moduleAt = html.indexOf('model-viewer.min.js');
      expect(
        configAt,
        lessThan(moduleAt),
        reason: 'The config must precede the module script that reads it.',
      );
    });

    test('the mobile WebView template configures it too', () {
      // relatedJs is a CLASSIC inline script; the plugin's template loads
      // model-viewer as type="module" (deferred), so this always runs first.
      expect(
        ModelRenderViewState.lifecycleJsForTest
            .contains('meshoptDecoderLocation'),
        isTrue,
        reason: 'Without this, optimized models fail to load in the app.',
      );
    });

    test('the two pages use the SAME value', () {
      final html = File('web/index.html').readAsStringSync();
      expect(
        html.contains("'$kMeshoptDecoderLocation'"),
        isTrue,
        reason:
            'web/index.html and kMeshoptDecoderLocation have drifted apart; '
            'one platform is now configured differently from the other.',
      );
      expect(
        ModelRenderViewState.lifecycleJsForTest
            .contains(kMeshoptDecoderLocation),
        isTrue,
      );
    });

    test('the catalog preview renders 3D through the SAME viewer', () {
      // Structural, not textual: the card is asked what it would build, and the
      // answer has to be the widget that carries both decoder configurations.
      // It cannot be checked by pumping the card — the real viewer drives a
      // WebView with no platform implementation in a widget test.
      final card = PreviewProductCard(
        product: _previewProduct,
        height: 300,
        isThreeDActive: true,
      );

      final media = card.debugMedia();
      expect(
        media,
        isA<ModelRenderView>(),
        reason: 'Without this the preview would fail EVERY optimized model.',
      );
      expect((media as ModelRenderView).glbUrl, _previewProduct.glbUrl);
      expect(media.usdzUrl, _previewProduct.usdzUrl);
    });

    test('the value is a self-contained trigger, not a fetched file', () {
      // The decoder is BUNDLED inside model-viewer.min.js; the URL only has to
      // load successfully. A relative path would be fatal on mobile: the
      // plugin's local proxy serves exactly `/`, `/model-viewer.min.js` and
      // `/model`, and REDIRECTS anything else to the GLB's CloudFront origin —
      // where it 404s, rejecting the decoder promise and failing the load just
      // as surely as no configuration at all.
      expect(kMeshoptDecoderLocation, startsWith('data:'));
    });
  });
}

/// A 3D catalog product, as the preview would hand one to the card.
final _previewProduct = CatalogProduct.fromMap(const {
  'id': 'p1',
  'type': 'THREE_D',
  'name': 'Walnut Chair',
  'glbUrl': 'https://cdn.example.com/optimized.glb',
  'usdzUrl': 'https://cdn.example.com/model.usdz',
  'thumbnailUrl': 'https://cdn.example.com/preview.jpg',
});
