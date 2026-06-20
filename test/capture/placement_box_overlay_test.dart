// test/capture/placement_box_overlay_test.dart
//
// Widget tests for the render-only placement guide: nothing when geometry is
// invalid, scrim/brackets + status-driven copy when valid, hit-test
// transparency, helper-text override, and reduce-motion (no pulse → settles).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/placement_box.dart';
import 'package:recapture/platform/camera/preview_geometry.dart';
import 'package:recapture/presentation/widgets/placement_box_overlay.dart';

void main() {
  const validGeometry = PreviewGeometry(
    displayImageSize: Size(1080, 1920),
    screenSize: Size(400, 800),
  );

  Future<void> pump(
    WidgetTester tester, {
    required PreviewGeometry geometry,
    PlacementStatus status = PlacementStatus.idle,
    String? helperText,
    bool reduceMotion = false,
  }) {
    Widget child = PlacementBoxOverlay(
      geometry: geometry,
      status: status,
      helperText: helperText,
    );
    if (reduceMotion) {
      child = MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: child,
      );
    }
    return tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  }

  Finder overlayPaint = find.descendant(
    of: find.byType(PlacementBoxOverlay),
    matching: find.byType(CustomPaint),
  );

  testWidgets('renders nothing when geometry is invalid', (tester) async {
    await pump(tester, geometry: PreviewGeometry.empty);
    expect(overlayPaint, findsNothing);
    expect(find.text('Place the object inside the box'), findsNothing);
  });

  testWidgets('renders scrim/brackets + idle copy for valid geometry',
      (tester) async {
    await pump(tester, geometry: validGeometry);
    expect(overlayPaint, findsOneWidget);
    expect(find.text('Place the object inside the box'), findsOneWidget);
  });

  testWidgets('status drives helper copy', (tester) async {
    const expected = {
      PlacementStatus.good: 'Looks good — hold steady',
      PlacementStatus.tooClose: 'Move back',
      PlacementStatus.tooFar: 'Move closer',
      PlacementStatus.offCenter: 'Center the object',
    };
    for (final entry in expected.entries) {
      await pump(tester, geometry: validGeometry, status: entry.key);
      await tester.pump();
      expect(find.text(entry.value), findsOneWidget,
          reason: 'copy for ${entry.key}');
    }
  });

  testWidgets('helperText override wins over status copy', (tester) async {
    await pump(tester, geometry: validGeometry, helperText: 'Custom hint');
    expect(find.text('Custom hint'), findsOneWidget);
    expect(find.text('Place the object inside the box'), findsNothing);
  });

  testWidgets('is hit-test transparent (IgnorePointer)', (tester) async {
    await pump(tester, geometry: validGeometry);
    final ignore = tester.widget<IgnorePointer>(
      find.descendant(
        of: find.byType(PlacementBoxOverlay),
        matching: find.byType(IgnorePointer),
      ),
    );
    expect(ignore.ignoring, isTrue);
  });

  testWidgets('reduce-motion: good state has no pulse (animation settles)',
      (tester) async {
    await pump(
      tester,
      geometry: validGeometry,
      status: PlacementStatus.good,
      reduceMotion: true,
    );
    // Would time out if a pulse were repeating.
    await tester.pumpAndSettle();
    expect(find.text('Looks good — hold steady'), findsOneWidget);
  });
}
