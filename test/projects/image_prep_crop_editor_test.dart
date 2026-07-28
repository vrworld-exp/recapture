// test/projects/image_prep_crop_editor_test.dart
//
// Gesture coverage for PrepCropEditor — the interactive crop layer of the
// Prepare-Images screen. This widget previously had NO tests at all, which is
// how two "the tool does nothing" defects shipped and survived:
//
//   • a tap that drifted past kTouchSlop was claimed by the pan recognizer,
//     which then did nothing because no vertex was grabbed — so polygon points
//     simply never appeared for a real finger;
//   • a drag starting on empty canvas in rectangle mode was discarded, so the
//     box could only be nudged from its hardcoded starting position.
//
// Both are pinned below. The editor reports in NORMALIZED [0,1] coordinates,
// so assertions convert against the known 400×400 test surface.
//
// Every gesture stays in the TOP HALF: the editor's action chips are laid out
// at bottomCenter and their InkWells swallow touches, which is a property of
// the widget, not of the crop logic under test.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/image_edit.dart';
import 'package:recapture/presentation/screens/projects/image_prep_crop_editor.dart';

const Size _surface = Size(400, 400);

/// Mounts the editor at a known size and captures whatever it applies.
Future<({List<List<EditPoint>> polygons, List<RectCrop> rects})> _pump(
  WidgetTester tester, {
  required PrepCropMode mode,
  List<EditPoint>? initialPolygon,
  RectCrop? initialRect,
}) async {
  final polygons = <List<EditPoint>>[];
  final rects = <RectCrop>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: _surface.width,
            height: _surface.height,
            child: PrepCropEditor(
              mode: mode,
              initialPolygon: initialPolygon,
              initialRect: initialRect,
              onApplyPolygon: polygons.add,
              onApplyRect: rects.add,
              onCancel: () {},
            ),
          ),
        ),
      ),
    ),
  );
  return (polygons: polygons, rects: rects);
}

/// Editor-local coordinates → global, for gesture input.
Offset _at(WidgetTester tester, double dx, double dy) =>
    tester.getTopLeft(find.byType(PrepCropEditor)) + Offset(dx, dy);

/// A deliberate drag from [from] to [to].
///
/// The nudge first: a pan is not recognized until the touch clears kTouchSlop
/// (~18px), and a single moveBy that merely crosses it can be fully consumed
/// by recognition, leaving no update to act on. Nudging past the slop and THEN
/// moving to the real target makes the resulting delta exact — the widget uses
/// DragStartBehavior.down, so it measures from the touch-down point regardless
/// of how the pointer got there.
Future<void> _drag(WidgetTester tester, Offset from, Offset to) async {
  final gesture = await tester.startGesture(from);
  await gesture.moveBy(const Offset(30, 0));
  await tester.pump();
  await gesture.moveTo(to);
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

/// A tap the way a thumb actually delivers one: with enough drift to lose the
/// gesture arena to the pan recognizer.
Future<void> _driftTap(WidgetTester tester, Offset at) async {
  final gesture = await tester.startGesture(at);
  await gesture.moveBy(const Offset(25, 0));
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

void main() {
  group('polygon mode', () {
    testWidgets('a clean tap drops a vertex', (tester) async {
      final applied = await _pump(tester, mode: PrepCropMode.polygon);

      await tester.tapAt(_at(tester, 80, 40));
      await tester.tapAt(_at(tester, 320, 40));
      await tester.tapAt(_at(tester, 200, 160));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('prep_poly_close')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('prep_poly_apply')));
      await tester.pump();

      final points = applied.polygons.single;
      expect(points, hasLength(3));
      expect(points[0].x, closeTo(0.2, 0.01));
      expect(points[0].y, closeTo(0.1, 0.01));
    });

    testWidgets(
        'REGRESSION: a tap that drifts past kTouchSlop still drops a vertex '
        '— the pan recognizer used to swallow it', (tester) async {
      final applied = await _pump(tester, mode: PrepCropMode.polygon);

      for (final origin in const [
        Offset(80, 40),
        Offset(320, 40),
        Offset(200, 160),
      ]) {
        await _driftTap(tester, _at(tester, origin.dx, origin.dy));
      }

      // All three drifted taps registered, so the polygon can close and apply.
      await tester.tap(find.byKey(const ValueKey('prep_poly_close')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('prep_poly_apply')));
      await tester.pump();

      final points = applied.polygons.single;
      expect(points, hasLength(3));
      // Recorded at the touch-DOWN point, not where the finger drifted to.
      expect(points[0].x, closeTo(0.2, 0.01));
      expect(points[0].y, closeTo(0.1, 0.01));
    });

    testWidgets('a real drag on a vertex moves that vertex only',
        (tester) async {
      final applied = await _pump(
        tester,
        mode: PrepCropMode.polygon,
        initialPolygon: const [
          EditPoint(0.2, 0.1),
          EditPoint(0.8, 0.1),
          EditPoint(0.5, 0.4),
        ],
      );

      // Grab the first vertex (80,40) and drag it to (120,80) = 30%,20%.
      await _drag(tester, _at(tester, 80, 40), _at(tester, 120, 80));

      await tester.tap(find.byKey(const ValueKey('prep_poly_apply')));
      await tester.pump();

      final points = applied.polygons.single;
      expect(points, hasLength(3), reason: 'a drag must not ADD a point');
      expect(points[0].x, closeTo(0.3, 0.01));
      expect(points[0].y, closeTo(0.2, 0.01));
      // The untouched vertices stay exactly where they were.
      expect(points[1].x, closeTo(0.8, 0.001));
      expect(points[2].y, closeTo(0.4, 0.001));
    });
  });

  group('rectangle mode', () {
    testWidgets(
        'REGRESSION: dragging on empty canvas DRAWS a box — it used to be '
        'discarded, leaving the rect stuck at its hardcoded default',
        (tester) async {
      final applied = await _pump(
        tester,
        mode: PrepCropMode.rectangle,
        // Parked well away so the drag below starts nowhere near a corner
        // handle (grab radius 24px) and genuinely exercises drawing.
        initialRect:
            const RectCrop(left: 0.7, top: 0.55, width: 0.25, height: 0.25),
      );

      await _drag(tester, _at(tester, 20, 20), _at(tester, 220, 180));

      await tester.tap(find.byKey(const ValueKey('prep_rect_apply')));
      await tester.pump();

      final rect = applied.rects.single;
      expect(rect.left, closeTo(0.05, 0.01));
      expect(rect.top, closeTo(0.05, 0.01));
      expect(rect.width, closeTo(0.5, 0.01));
      expect(rect.height, closeTo(0.4, 0.01));
    });

    testWidgets('drawing UP-LEFT from the anchor works too', (tester) async {
      final applied = await _pump(
        tester,
        mode: PrepCropMode.rectangle,
        initialRect:
            const RectCrop(left: 0.75, top: 0.75, width: 0.2, height: 0.2),
      );

      // Anchor down-right of the target: corner math pinned to a fixed handle
      // would have collapsed this to a degenerate box.
      await _drag(tester, _at(tester, 240, 180), _at(tester, 40, 20));

      await tester.tap(find.byKey(const ValueKey('prep_rect_apply')));
      await tester.pump();

      final rect = applied.rects.single;
      expect(rect.left, closeTo(0.1, 0.01));
      expect(rect.top, closeTo(0.05, 0.01));
      expect(rect.width, closeTo(0.5, 0.01));
      expect(rect.height, closeTo(0.4, 0.01));
    });

    testWidgets('a stray tap on empty canvas leaves the existing box intact',
        (tester) async {
      const seeded = RectCrop(left: 0.25, top: 0.25, width: 0.5, height: 0.5);
      final applied = await _pump(
        tester,
        mode: PrepCropMode.rectangle,
        initialRect: seeded,
      );

      // Outside the seeded box and barely any travel: a degenerate draw must
      // be discarded rather than collapsing the crop to nothing.
      final gesture = await tester.startGesture(_at(tester, 20, 20));
      await gesture.moveBy(const Offset(2, 2));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('prep_rect_apply')));
      await tester.pump();

      final rect = applied.rects.single;
      expect(rect.left, closeTo(seeded.left, 0.001));
      expect(rect.top, closeTo(seeded.top, 0.001));
      expect(rect.width, closeTo(seeded.width, 0.001));
      expect(rect.height, closeTo(seeded.height, 0.001));
    });

    testWidgets('dragging the body moves the box without resizing it',
        (tester) async {
      final applied = await _pump(
        tester,
        mode: PrepCropMode.rectangle,
        initialRect:
            const RectCrop(left: 0.25, top: 0.05, width: 0.5, height: 0.4),
      );

      // Grab the centre (200,100) — inside the box, away from every corner.
      await _drag(tester, _at(tester, 200, 100), _at(tester, 240, 120));

      await tester.tap(find.byKey(const ValueKey('prep_rect_apply')));
      await tester.pump();

      final rect = applied.rects.single;
      expect(rect.left, closeTo(0.35, 0.01));
      expect(rect.top, closeTo(0.10, 0.01));
      expect(rect.width, closeTo(0.5, 0.001), reason: 'body drag must not resize');
      expect(rect.height, closeTo(0.4, 0.001));
    });
  });
}
