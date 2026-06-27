// test/capture/instruction_banner_single_test.dart
//
// QA INVARIANT (single-cue): the Level A instruction banner shows AT MOST ONE
// pill at a time — a changed instruction REPLACES the previous (crossfade in the
// same slot), rapid changes coalesce to the latest, identical re-emits don't
// re-animate, and null hides the pill. Proven by COUNTING pill widgets (not just
// text), so two persistent/stacked pills would fail.
//
// Complements instruction_banner_test.dart (which asserts via displayed text):
// this file adds a deterministic `pillCount` helper + the count invariant across
// every settled frame, the mid-crossfade replacement case, and element-identity
// proof that a same-id re-emit reuses the pill (no re-animation).
//
// TEST SEAM (flagged): the pill widget `_Pill` is private, so a non-visual
// test-only `Key('instruction_pill')` was added to its container in
// instruction_banner.dart purely so the test can count pills. It does not affect
// the live AnimatedSwitcher key (the _Pill's own ValueKey(id) drives the crossfade).
//
// Hermetic + deterministic: the banner is driven directly with CaptureInstruction
// values and pumped against small fixed crossfade/coalesce durations. No engine,
// providers, camera, sensors, or real timers.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/capture_instruction.dart';
import 'package:recapture/presentation/widgets/instruction_banner.dart';

// Stable banner key → re-pumps reuse the same State (so a change goes through
// didUpdateWidget, exercising the real coalesce/crossfade path).
const _bannerKey = ValueKey<String>('banner');
const _coalesce = Duration(milliseconds: 40);
const _crossfade = Duration(milliseconds: 100);
const _pillKey = Key('instruction_pill');

CaptureInstruction _i(
  String id,
  String message, {
  InstructionSeverity severity = InstructionSeverity.info,
}) =>
    CaptureInstruction(id: id, message: message, severity: severity);

/// Deterministic count of pill widgets currently in the tree. Settled: 1 (shown)
/// or 0 (hidden). During the single legitimate crossfade the AnimatedSwitcher
/// briefly holds the outgoing + incoming pill (≤ 2) — that is one transition, not
/// stacking.
int pillCount(WidgetTester t) => find.byKey(_pillKey).evaluate().length;

Future<void> _set(
  WidgetTester tester,
  CaptureInstruction? instruction, {
  bool reduceMotion = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (ctx) => MediaQuery(
          // Keep the real test surface size; only override reduce-motion.
          data: MediaQuery.of(ctx).copyWith(disableAnimations: reduceMotion),
          child: Scaffold(
            body: Stack(
              children: [
                InstructionBanner(
                  key: _bannerKey,
                  instruction: instruction,
                  coalesceWindow: _coalesce,
                  crossfade: _crossfade,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Applies a debounced (different-id) change and lets the crossfade finish.
Future<void> _applyAndSettle(WidgetTester tester) async {
  await tester.pump(_coalesce); // debounce fires → _displayed updates
  await tester.pumpAndSettle(); // crossfade completes
}

void main() {
  group('count invariant: at most one settled pill', () {
    testWidgets('initial null → zero pills', (tester) async {
      await _set(tester, null);
      expect(pillCount(tester), 0);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('null → A → null round-trip: 0 → 1 → 0', (tester) async {
      await _set(tester, null);
      expect(pillCount(tester), 0);

      await _set(tester, _i('a', 'Hold steady'));
      await _applyAndSettle(tester);
      expect(pillCount(tester), 1);
      expect(find.text('Hold steady'), findsOneWidget);

      await _set(tester, null);
      await _applyAndSettle(tester);
      expect(pillCount(tester), 0);
    });

    testWidgets('A → B settles to exactly ONE pill (B); A gone, never stacked',
        (tester) async {
      await _set(tester, _i('a', 'First')); // first mount shows immediately
      expect(pillCount(tester), 1);

      await _set(tester, _i('b', 'Second'));
      await tester.pump(_coalesce); // debounce fires → crossfade begins
      // Mid-crossfade: the one legitimate transition may hold both briefly...
      await tester.pump(const Duration(milliseconds: 50));
      expect(pillCount(tester), lessThanOrEqualTo(2));
      expect(pillCount(tester), greaterThanOrEqualTo(1));

      await tester.pumpAndSettle();
      expect(pillCount(tester), 1, reason: 'no two persistent pills');
      expect(find.text('Second'), findsOneWidget);
      expect(find.text('First'), findsNothing);
    });
  });

  group('coalesce: rapid changes leave one pill (latest)', () {
    testWidgets('A→B→C within the coalesce window → one pill C; A/B never persist',
        (tester) async {
      await _set(tester, _i('a', 'A'));
      expect(pillCount(tester), 1);

      // Fire B then C faster than the coalesce window — neither is applied yet.
      await _set(tester, _i('b', 'B'));
      await tester.pump(const Duration(milliseconds: 15));
      expect(pillCount(tester), 1, reason: 'still showing A; B not yet a pill');
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsNothing);

      await _set(tester, _i('c', 'C'));
      await tester.pump(const Duration(milliseconds: 15));
      expect(find.text('B'), findsNothing);
      expect(find.text('C'), findsNothing, reason: 'C not applied yet either');

      // Let the debounce fire for the latest (C) and the crossfade complete.
      await _applyAndSettle(tester);
      expect(pillCount(tester), 1);
      expect(find.text('C'), findsOneWidget);
      expect(find.text('A'), findsNothing);
      expect(find.text('B'), findsNothing);
    });
  });

  group('identical re-emit: no re-animation, same pill element', () {
    testWidgets('same id + equal content → the SAME pill element persists',
        (tester) async {
      await _set(tester, _i('a', 'Hold steady'));
      expect(pillCount(tester), 1);
      final before = tester.element(find.byKey(_pillKey));

      await _set(tester, _i('a', 'Hold steady')); // identical re-emit
      await tester.pump(); // a single frame — no coalesce/crossfade should run
      expect(pillCount(tester), 1);
      final after = tester.element(find.byKey(_pillKey));
      expect(identical(before, after), isTrue,
          reason: 'same-id re-emit reuses the pill (no teardown/re-animation)');
      // pumpAndSettle returns immediately because nothing is animating.
      await tester.pumpAndSettle();
      expect(pillCount(tester), 1);
    });

    testWidgets('same id, changed message → instant restyle, one pill, same slot',
        (tester) async {
      await _set(tester, _i('x', 'Message one'));
      final before = tester.element(find.byKey(_pillKey));

      await _set(tester, _i('x', 'Message two')); // same id → instant, no debounce
      await tester.pump();
      expect(pillCount(tester), 1);
      expect(find.text('Message two'), findsOneWidget);
      expect(find.text('Message one'), findsNothing);
      final after = tester.element(find.byKey(_pillKey));
      expect(identical(before, after), isTrue, reason: 'same slot, no crossfade');
    });

    testWidgets('severity-only change (same id) → one pill, instant',
        (tester) async {
      await _set(tester, _i('s', 'Too dark'));
      final before = tester.element(find.byKey(_pillKey));

      await _set(tester, _i('s', 'Too dark', severity: InstructionSeverity.warning));
      await tester.pump();
      expect(pillCount(tester), 1);
      // Warning treatment is a bordered pill.
      expect(
        find.byWidgetPredicate((w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).border != null),
        findsOneWidget,
      );
      final after = tester.element(find.byKey(_pillKey));
      expect(identical(before, after), isTrue);
    });
  });

  group('mid-crossfade replacement', () {
    testWidgets('setting C while A→B is crossfading settles to one pill (C)',
        (tester) async {
      await _set(tester, _i('a', 'A'));
      expect(pillCount(tester), 1);

      // Begin A→B and advance partway INTO the crossfade.
      await _set(tester, _i('b', 'B'));
      await tester.pump(_coalesce);
      await tester.pump(const Duration(milliseconds: 40)); // mid A→B crossfade
      expect(pillCount(tester), lessThanOrEqualTo(2));

      // Replace with C mid-transition.
      await _set(tester, _i('c', 'C'));
      await _applyAndSettle(tester);

      expect(pillCount(tester), 1, reason: 'no lingering A/B pill');
      expect(find.text('C'), findsOneWidget);
      expect(find.text('A'), findsNothing);
      expect(find.text('B'), findsNothing);
    });
  });

  group('reduce-motion', () {
    testWidgets('instant swap A→B: one pill, no stacking', (tester) async {
      await _set(tester, _i('a', 'A'), reduceMotion: true);
      expect(pillCount(tester), 1);

      await _set(tester, _i('b', 'B'), reduceMotion: true);
      await tester.pump(_coalesce); // coalesce still applies; crossfade is instant
      await tester.pump();
      expect(pillCount(tester), 1);
      expect(find.text('B'), findsOneWidget);
      expect(find.text('A'), findsNothing);
    });
  });

  group('robustness', () {
    testWidgets('long message renders exactly one pill', (tester) async {
      const long =
          'Walk slowly left around the object while keeping it centered and held '
          'perfectly steady so the frame stays sharp and well exposed';
      await _set(tester, _i('long', long));
      expect(pillCount(tester), 1);
    });

    testWidgets('disposed mid-crossfade → no pills, no error', (tester) async {
      await _set(tester, _i('a', 'A'));
      await _set(tester, _i('b', 'B'));
      await tester.pump(_coalesce);
      await tester.pump(const Duration(milliseconds: 40)); // mid crossfade
      await tester.pumpWidget(const SizedBox()); // dispose the banner
      await tester.pump(const Duration(milliseconds: 300));
      expect(pillCount(tester), 0);
      expect(tester.takeException(), isNull);
    });
  });
}
