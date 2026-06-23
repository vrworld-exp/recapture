// test/capture/direction_arrow_overlay_test.dart
//
// Tests the direction arrow overlay: hidden by default, debounced show/hide (no
// blink), a single glyph through CW↔CCW reversal (no both-arrows), capped
// urgency mapping (incl. NaN/extremes), reduce-motion static arrow, and clean
// disposal. The DirectionHint is supplied (the overlay renders, never computes).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/app/theme/app_colors.dart';
import 'package:recapture/domain/entities/direction_hint.dart';
import 'package:recapture/presentation/widgets/direction_arrow_overlay.dart';

const _arrowKey = ValueKey<String>('arrow');
final _glyph = find.byKey(const ValueKey<String>('direction_arrow_glyph'));

Future<void> _pump(
  WidgetTester tester,
  DirectionHint hint, {
  bool reduceMotion = false,
  Duration debounce = const Duration(milliseconds: 150),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(
          body: Stack(
            children: [
              DirectionArrowOverlay(
                key: _arrowKey, // stable → updates reuse State (didUpdateWidget)
                hint: hint,
                debounceWindow: debounce,
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

double _opacity(WidgetTester tester) =>
    tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;

void main() {
  group('DirectionHint', () {
    test('hidden is not visible; defaults are clockwise / 0.5', () {
      expect(DirectionHint.hidden.visible, isFalse);
      const h = DirectionHint(visible: true);
      expect(h.direction, RingDirection.clockwise);
      expect(h.urgency, 0.5);
    });

    test('value equality', () {
      expect(const DirectionHint(visible: true),
          const DirectionHint(visible: true));
      expect(
        const DirectionHint(visible: true) ==
            const DirectionHint(
                visible: true, direction: RingDirection.counterclockwise),
        isFalse,
      );
    });
  });

  group('urgency mapping (pure)', () {
    test('colour escalates to Mirage Red only at high urgency', () {
      expect(directionArrowColor(0.0), AppColors.royalGold);
      expect(directionArrowColor(0.5), AppColors.royalGold);
      expect(directionArrowColor(1.0), AppColors.mirageRed);
    });

    test('size bump is small and capped (1.0 .. 1.18)', () {
      expect(directionArrowScale(0.0), closeTo(1.0, 1e-9));
      expect(directionArrowScale(1.0), closeTo(1.18, 1e-9));
    });

    test('NaN → neutral, out-of-range clamps (no overflow)', () {
      expect(directionArrowColor(double.nan), AppColors.royalGold);
      expect(directionArrowScale(double.nan), closeTo(1.09, 1e-9));
      expect(directionArrowScale(5.0), closeTo(1.18, 1e-9)); // clamped to 1
      expect(directionArrowScale(-3.0), closeTo(1.0, 1e-9)); // clamped to 0
    });
  });

  testWidgets('hidden by default → faded out, no visible glyph', (tester) async {
    await _pump(tester, DirectionHint.hidden);
    expect(_opacity(tester), 0.0);
  });

  testWidgets('becomes visible after the debounce window', (tester) async {
    await _pump(tester, DirectionHint.hidden);
    expect(_opacity(tester), 0.0);

    await _pump(tester, const DirectionHint(visible: true));
    await tester.pump(const Duration(milliseconds: 50)); // < debounce
    expect(_opacity(tester), 0.0, reason: 'not shown until debounce elapses');

    await tester.pump(const Duration(milliseconds: 150)); // past debounce
    await tester.pump();
    expect(_opacity(tester), 1.0);
    expect(_glyph, findsOneWidget);
  });

  testWidgets('visibility flapping is debounced (no blink)', (tester) async {
    await _pump(tester, DirectionHint.hidden);

    await _pump(tester, const DirectionHint(visible: true));
    await tester.pump(const Duration(milliseconds: 50)); // < debounce
    expect(_opacity(tester), 0.0);

    await _pump(tester, DirectionHint.hidden); // flipped back before it showed
    await tester.pump(const Duration(milliseconds: 250));
    expect(_opacity(tester), 0.0, reason: 'never blinked on');
  });

  testWidgets('direction reversal keeps exactly one glyph (no both-arrows)',
      (tester) async {
    await _pump(tester, const DirectionHint(visible: true),
        debounce: Duration.zero);
    await tester.pump(); // apply debounce(0)
    expect(_glyph, findsOneWidget);

    await _pump(
        tester,
        const DirectionHint(
            visible: true, direction: RingDirection.counterclockwise),
        debounce: Duration.zero);
    await tester.pump(const Duration(milliseconds: 130)); // mid-flip
    expect(_glyph, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200)); // flip done
    expect(_glyph, findsOneWidget);
  });

  testWidgets('reduce-motion shows a static arrow (no perpetual animation)',
      (tester) async {
    await _pump(tester, const DirectionHint(visible: true),
        reduceMotion: true, debounce: Duration.zero);
    await tester.pump();
    // With no looping nudge, the tree settles.
    await tester.pumpAndSettle();
    expect(_opacity(tester), 1.0);
    expect(_glyph, findsOneWidget);
  });

  testWidgets('urgency extremes render without overflow', (tester) async {
    for (final u in [0.0, 1.0, double.nan]) {
      await _pump(tester, DirectionHint(visible: true, urgency: u),
          debounce: Duration.zero);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      expect(_glyph, findsOneWidget);
    }
  });

  testWidgets('disposed mid-animation does not throw', (tester) async {
    await _pump(tester, const DirectionHint(visible: true));
    await tester.pump(const Duration(milliseconds: 60)); // mid debounce
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });
}
