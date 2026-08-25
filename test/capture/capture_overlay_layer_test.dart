// test/capture/capture_overlay_layer_test.dart
//
// Verifies the overlay composition architecture: the layer stacks overlays above
// the base preview and exposes PreviewGeometry to descendants via the scope.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/platform/camera/preview_geometry.dart';
import 'package:recapture/presentation/widgets/capture_overlay_layer.dart';

void main() {
  const geometry = PreviewGeometry(
    displayImageSize: Size(1080, 1920),
    screenSize: Size(400, 800),
  );

  testWidgets('stacks overlays above the base preview', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: CaptureOverlayLayer(
          geometry: geometry,
          cameraPreview: ColoredBox(color: Color(0xFF000000)),
          overlays: [
            Align(alignment: Alignment.topLeft, child: Text('overlay-a')),
            Align(alignment: Alignment.bottomRight, child: Text('overlay-b')),
          ],
        ),
      ),
    );

    expect(find.text('overlay-a'), findsOneWidget);
    expect(find.text('overlay-b'), findsOneWidget);
    expect(find.byType(Stack), findsOneWidget);
  });

  testWidgets('provides the geometry to descendant overlays via the scope',
      (tester) async {
    PreviewGeometry? seen;
    await tester.pumpWidget(
      MaterialApp(
        home: CaptureOverlayLayer(
          geometry: geometry,
          cameraPreview: const ColoredBox(color: Color(0xFF000000)),
          overlays: [
            Builder(builder: (context) {
              seen = PreviewGeometryScope.of(context);
              return const SizedBox.shrink();
            }),
          ],
        ),
      ),
    );

    expect(seen, geometry);
  });

  testWidgets('maybeOf returns null with no scope ancestor', (tester) async {
    PreviewGeometry? seen = geometry;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(builder: (context) {
          seen = PreviewGeometryScope.maybeOf(context);
          return const SizedBox.shrink();
        }),
      ),
    );
    expect(seen, isNull);
  });

  // Renders the reticle in a bare tree (no Material chrome that would add its
  // own CustomPaints) so CustomPaint presence reflects the reticle alone.
  Future<void> pumpReticle(WidgetTester tester, PreviewGeometry g) {
    return tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: PreviewGeometryScope(
          geometry: g,
          child: const CaptureDebugReticleOverlay(),
        ),
      ),
    );
  }

  testWidgets('debug reticle paints for valid geometry', (tester) async {
    await pumpReticle(tester, geometry);
    expect(find.byType(CustomPaint), findsOneWidget);
  });

  testWidgets('debug reticle renders nothing for invalid geometry',
      (tester) async {
    await pumpReticle(tester, PreviewGeometry.empty);
    expect(find.byType(CustomPaint), findsNothing);
  });
}
